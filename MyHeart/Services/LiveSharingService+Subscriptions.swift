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
        let sharedDB = CKContainer(identifier: CloudKitConfig.containerIdentifier).sharedCloudDatabase

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
            // Subscriptions aren't critical — we fall back to foreground polling.
            lastPublishError = SharingError.wrap(error).friendlyMessage
        }
    }

    /// Called by the `AppDelegate` when a silent push arrives. Does an
    /// incremental refresh of followed records and evaluates local alerts.
    /// `completion` is optional because silent pushes come through different
    /// entry points (foreground + background).
    func handleSubscriptionPush() async {
        await refreshFollowed()
        await evaluateAlerts()
    }

    /// Evaluates each followed person against the user's per-person alert
    /// threshold (stored in UserDefaults by `FollowDetailView`). Fires a
    /// time-sensitive local notification if crossed, rate-limited to one
    /// alert per 10 minutes per person.
    func evaluateAlerts() async {
        let defaults = UserDefaults.standard
        let now = Date()
        for person in followed {
            let thresholdKey = "follow.alert.\(person.id)"
            let lastKey      = "lastAlert.\(person.id)"
            let threshold = defaults.integer(forKey: thresholdKey)

            let shouldFireThreshold = threshold > 0 && person.status.currentBPM >= threshold
            let shouldFireEmergency = person.status.isEmergency

            guard shouldFireThreshold || shouldFireEmergency else { continue }

            let last = defaults.double(forKey: lastKey)
            let cooldown: TimeInterval = shouldFireEmergency ? 120 : 600  // emergencies re-fire faster
            if now.timeIntervalSince1970 - last < cooldown { continue }
            defaults.set(now.timeIntervalSince1970, forKey: lastKey)

            fireLocalNotification(for: person, isEmergency: shouldFireEmergency, threshold: threshold)
        }
    }

    private func fireLocalNotification(for person: FollowedPerson, isEmergency: Bool, threshold: Int) {
        let content = UNMutableNotificationContent()
        if isEmergency {
            content.title = "🚨 \(person.status.displayName) — emergency"
            if let kind = person.status.emergencyKind {
                content.body = "\(kind.label). Now \(person.status.currentBPM) BPM."
            } else {
                content.body = "Heart rate is at a critical level — \(person.status.currentBPM) BPM."
            }
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .timeSensitive
                content.relevanceScore = 1.0
            }
            content.sound = .defaultCritical
        } else {
            content.title = "\(person.status.displayName) — elevated heart rate"
            content.body = "Currently \(person.status.currentBPM) BPM (threshold \(threshold))."
            if #available(iOS 15.0, *) { content.interruptionLevel = .active }
            content.sound = .default
        }

        let req = UNNotificationRequest(
            identifier: "followed.\(person.id).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}
