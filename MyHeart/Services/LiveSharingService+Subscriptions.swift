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
    /// re-alert on every refresh. Repeats for the same person are rate-limited
    /// (10 min for high-HR alerts, 2 min for emergencies).
    func evaluateAlerts() async {
        let defaults = UserDefaults.standard
        let now = Date()
        for person in followed {
            let status = person.status
            guard !status.isStale else { continue }

            let thresholdEnabled = FollowAlertSettings.isEnabled(for: person.id, defaults: defaults)
            let threshold = FollowAlertSettings.threshold(for: person.id, defaults: defaults)
            let shouldFireThreshold = thresholdEnabled && status.currentBPM >= threshold
            let shouldFireEmergency = status.isEmergency

            guard shouldFireThreshold || shouldFireEmergency else { continue }

            let lastReadingKey = "lastAlertReading.\(person.id)"
            let lastAlertKey = "lastAlert.\(person.id)"

            let readingStamp = status.updatedAt.timeIntervalSince1970
            if defaults.double(forKey: lastReadingKey) >= readingStamp { continue }

            let cooldown: TimeInterval = shouldFireEmergency ? 120 : 600
            if now.timeIntervalSince1970 - defaults.double(forKey: lastAlertKey) < cooldown { continue }

            defaults.set(readingStamp, forKey: lastReadingKey)
            defaults.set(now.timeIntervalSince1970, forKey: lastAlertKey)

            await fireLocalNotification(for: person, isEmergency: shouldFireEmergency, threshold: threshold)
        }
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
