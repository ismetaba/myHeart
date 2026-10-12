import Foundation
import HealthKit
import UIKit

extension Notification.Name {
    /// Posted on the main thread whenever HealthKit reports new heart-rate samples.
    static let heartRateDataDidChange = Notification.Name("MyHeart.heartRateDataDidChange")
}

/// Turns the newest HealthKit heart-rate state into a `LiveHeartStatus` and
/// hands it to `LiveSharingService`.
///
/// It owns the HealthKit observer query, so updates keep flowing while the app
/// is in the background (HealthKit background delivery wakes the app) and it
/// doesn't depend on any SwiftUI view being alive. Everything is cheap to call
/// repeatedly: the sharing service drops unchanged statuses and throttles writes.
@MainActor
final class LiveStatusPublisher {
    static let shared = LiveStatusPublisher()

    private let health: HealthKitManager
    private var observer: HKObserverQuery?

    /// Last-24h hourly trend, refreshed at most every `trendRefreshInterval`.
    private var trend: [Int] = []
    private var trendFetchedAt: Date?
    private let trendRefreshInterval: TimeInterval = 15 * 60

    /// A sample older than this isn't evaluated for emergencies — an old
    /// workout spike must not raise an alarm hours later.
    private let freshSampleWindow: TimeInterval = 15 * 60

    private var runningPublish: Task<Void, Never>?
    private var rerunRequested = false
    private var rerunImmediate = false

    private init(health: HealthKitManager = .shared) {
        self.health = health
    }

    // MARK: - Observer

    /// Registers the HealthKit observer + background delivery. Safe to call
    /// repeatedly; it's a no-op until the user has seen the Health permission
    /// sheet, so call it again after `requestAuthorization()`.
    func start() async {
        guard observer == nil, HKHealthStore.isHealthDataAvailable() else { return }
        guard await health.hasRequestedAuthorization() else { return }
        guard observer == nil else { return }  // another caller won the race during the await

        observer = health.startHeartRateObserver(
            onChange: { completion in
                Task { @MainActor in
                    NotificationCenter.default.post(name: .heartRateDataDidChange, object: nil)
                    await LiveStatusPublisher.shared.publishLatest()
                    completion()
                }
            },
            onError: { error in
                Task { @MainActor in
                    LiveStatusPublisher.shared.observerDidFail(error)
                }
            }
        )
        health.enableHeartRateBackgroundDelivery()
    }

    private func observerDidFail(_ error: Error) {
        print("[LivePublisher] heart-rate observer stopped: \(error.localizedDescription)")
        if let observer { health.stopObserver(observer) }
        observer = nil
    }

    // MARK: - Publishing

    /// Builds a status from the newest HealthKit data and publishes it if
    /// live sharing is on. `immediate` bypasses the write throttle — used for
    /// background wakes, where a delayed flush might never run.
    ///
    /// Runs are serialized: a call made while one is in flight schedules one
    /// more pass and waits for it. Otherwise a slow run holding an older
    /// sample could finish last and overwrite a newer (e.g. emergency) status.
    func publishLatest(immediate: Bool? = nil) async {
        if let running = runningPublish {
            rerunRequested = true
            if immediate == true { rerunImmediate = true }
            await running.value
            return
        }
        let task = Task { @MainActor in
            var nextImmediate = immediate
            repeat {
                self.rerunRequested = false
                await self.performPublish(immediate: nextImmediate)
                nextImmediate = self.rerunImmediate ? true : nil
                self.rerunImmediate = false
            } while self.rerunRequested
            self.runningPublish = nil
        }
        runningPublish = task
        await task.value
    }

    private func performPublish(immediate: Bool?) async {
        let sharing = LiveSharingService.shared
        await sharing.prepareForPublishing()
        guard sharing.sharingEnabled else { return }

        let latestSample: HeartRateSample?
        do {
            latestSample = try await health.fetchLatestHeartRateSample()
        } catch {
            // Most commonly "protected data unavailable" while the phone is locked.
            return
        }
        guard let latest = latestSample else { return }

        let profile = UserProfile.shared
        let bpm = Int(latest.bpm.rounded())
        let maxHR = profile.maxHR
        let zone = HeartRateZone(bpm: latest.bpm, maxHR: maxHR)

        let resting = try? await health.fetchLatestRestingHeartRate()
        let hrv = try? await health.fetchLatestHRV()

        var emergencyKind: EmergencyKind?
        var emergencySince: Date?
        if Date().timeIntervalSince(latest.date) <= freshSampleWindow {
            // History is the 15 minutes leading up to the newest sample, and
            // durations are measured to that sample's time — see the evaluator.
            let recent = (try? await health.fetchHeartRateSamples(
                start: latest.date.addingTimeInterval(-15 * 60),
                end: latest.date.addingTimeInterval(1),
                limit: HealthKitManager.noSampleLimit
            )) ?? [latest]
            let thresholds = EmergencyEvaluator.Thresholds(
                criticalHighBPM: profile.criticalHighBPM,
                criticalLowBPM: profile.criticalLowBPM,
                sustainedHighBPM: max(profile.elevatedThreshold, 120),
                sustainedMinutes: 10
            )
            let result = EmergencyEvaluator.evaluate(
                currentBPM: bpm,
                recent: recent,
                thresholds: thresholds,
                now: latest.date
            )
            emergencyKind = result.kind
            emergencySince = result.since
        }

        let trendIsStale = trendFetchedAt.map { Date().timeIntervalSince($0) > trendRefreshInterval } ?? true
        if trendIsStale, let fresh = try? await health.fetchLast24hHourlyHeartRate() {
            trend = fresh
            trendFetchedAt = Date()
        }

        let contactPhone = profile.emergencyContact.trimmingCharacters(in: .whitespacesAndNewlines)
        let contactName = profile.emergencyContactName.trimmingCharacters(in: .whitespacesAndNewlines)

        let status = LiveHeartStatus(
            id: CloudKitConfig.liveStatusRecordName,
            ownerID: nil,
            currentBPM: bpm,
            zoneRaw: zone.rawValue,
            restingBPM: resting.map { Int($0.rounded()) },
            hrvMs: hrv.map { $0.rounded() },
            updatedAt: latest.date,
            isElevated: bpm >= profile.elevatedThreshold,
            elevatedThreshold: profile.elevatedThreshold,
            displayName: profile.effectiveDisplayName,
            deviceName: latest.source,
            maxHR: Int(maxHR.rounded()),
            note: nil,
            trendHourlyBPM: trend,
            trendUpdatedAt: trend.isEmpty ? nil : trendFetchedAt,
            isEmergency: emergencyKind != nil,
            emergencyKind: emergencyKind,
            emergencySince: emergencySince,
            emergencyContactName: contactName.isEmpty ? nil : contactName,
            emergencyContactPhone: contactPhone.isEmpty ? nil : contactPhone
        )

        let isBackground = UIApplication.shared.applicationState != .active
        await sharing.publish(status, immediate: immediate ?? isBackground)
    }
}
