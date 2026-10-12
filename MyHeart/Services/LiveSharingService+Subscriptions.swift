import Foundation
import CloudKit
import UserNotifications
import UIKit

// MARK: - Silent-push subscription management

extension LiveSharingService {
    /// Creates (idempotently) a `CKDatabaseSubscription` on the watcher's
    /// shared database. When any record we have access to changes, CloudKit
    /// sends a silent APNs push → `AppDelegate` forwards it to
    /// `handleSubscriptionPush()` which refreshes + evaluates alerts.
    func ensureSharedDBSubscription() async {
        guard accountStatus == .available else { return }

        // Does the subscription already exist?
        if let existing = try? await sharedDB.allSubscriptions(),
           existing.contains(where: { $0.subscriptionID == CloudKitConfig.SubscriptionID.sharedDBChanges }) {
            return
        }

        let subscription = CKDatabaseSubscription(subscriptionID: CloudKitConfig.SubscriptionID.sharedDBChanges)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent push, no banner
        subscription.notificationInfo = info

        do {
            _ = try await sharedDB.save(subscription)
        } catch {
            // Not critical — we fall back to foreground / background-refresh
            // polling, so don't bother the user with it.
            LiveSharingService.log("shared DB subscription failed: \(error.localizedDescription)")
        }
    }

    /// Called by the `AppDelegate` when a silent push or background refresh
    /// arrives. The app may have been launched in the background for this,
    /// before any SwiftUI view ran `bootstrap()`, so make sure the account
    /// status is known first.
    func handleSubscriptionPush() async {
        if accountStatus != .available {
            await refreshAccountStatus()
        }
        await refreshFollowed()
        await evaluateAlerts()
    }

    /// Evaluates each followed person against the user's per-person alert
    /// threshold and fires a time-sensitive local notification when crossed.
    ///
    /// An alert only fires for a *new* reading (one we haven't alerted on
    /// before) that is still fresh, so a stale 130 BPM from hours ago doesn't
    /// re-alert on every refresh. Emergency and high-HR alerts are tracked
    /// separately, so a recent high-HR alert never holds back an emergency.
    /// Repeats are rate-limited per kind (2 min for emergencies, 10 min for
    /// high-HR alerts).
    func evaluateAlerts() async {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        for person in followed {
            let status = person.status
            guard status.hasReading, !status.isStale else { continue }

            let readingStamp = status.updatedAt.timeIntervalSince1970
            let threshold = FollowAlertSettings.threshold(for: person.id, defaults: defaults)

            func isDue(_ kind: AlertKind) -> Bool {
                defaults.double(forKey: kind.readingKey(person.id)) < readingStamp
                    && now - defaults.double(forKey: kind.timeKey(person.id)) >= kind.cooldown
            }
            func markHandled(_ kind: AlertKind) {
                defaults.set(readingStamp, forKey: kind.readingKey(person.id))
                defaults.set(now, forKey: kind.timeKey(person.id))
            }

            if status.isEmergency {
                guard isDue(.emergency) else { continue }
                markHandled(.emergency)
                // The emergency alert already says how high it is.
                markHandled(.highHeartRate)
                await fireLocalNotification(for: person, isEmergency: true, threshold: threshold)
            } else if FollowAlertSettings.isEnabled(for: person.id, defaults: defaults),
                      status.currentBPM >= threshold,
                      isDue(.highHeartRate) {
                markHandled(.highHeartRate)
                await fireLocalNotification(for: person, isEmergency: false, threshold: threshold)
            }
        }
    }

    /// Alert bookkeeping per kind, stored in UserDefaults per followed person.
    enum AlertKind: String, CaseIterable {
        case emergency
        case highHeartRate = "high"

        var cooldown: TimeInterval {
            switch self {
            case .emergency:     return 120
            case .highHeartRate: return 600
            }
        }

        func readingKey(_ personID: String) -> String { "lastAlertReading.\(rawValue).\(personID)" }
        func timeKey(_ personID: String) -> String { "lastAlert.\(rawValue).\(personID)" }
    }

    private func fireLocalNotification(for person: FollowedPerson, isEmergency: Bool, threshold: Int) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral else { return }

        let status = person.status
        let content = UNMutableNotificationContent()
        if isEmergency {
            content.title = "🚨 \(status.displayName) — emergency"
            if let kind = status.emergencyKind {
                content.body = "\(kind.label). Now \(status.currentBPM) BPM."
            } else {
                content.body = "Heart rate is at a critical level — \(status.currentBPM) BPM."
            }
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
            content.sound = .defaultCritical
        } else {
            content.title = "\(status.displayName) — elevated heart rate"
            content.body = "Currently \(status.currentBPM) BPM (your alert is set at \(threshold))."
            content.interruptionLevel = .active
            content.sound = .default
        }
        content.threadIdentifier = "followed.\(person.id)"
        content.userInfo = ["followedPersonID": person.id]

        let request = UNNotificationRequest(
            identifier: "followed.\(person.id).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
