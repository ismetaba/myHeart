import UIKit
import CloudKit
import BackgroundTasks
import UserNotifications

/// Bridges a handful of iOS-level callbacks that SwiftUI doesn't expose:
///   - CloudKit share acceptance
///   - APNs registration + silent remote-notification delivery (for CKDatabaseSubscription)
///   - Background task registration + execution
final class AppDelegate: NSObject, UIApplicationDelegate {

    // MARK: Launch

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        // Register BG tasks before the app finishes launching (Apple requirement).
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: CloudKitConfig.BackgroundTask.familyRefresh,
            using: nil
        ) { task in
            Self.handleBackgroundRefresh(task as! BGAppRefreshTask)
        }

        // Schedule the first refresh. Subsequent ones are scheduled from the
        // task handler itself.
        Self.scheduleNextBackgroundRefresh()

        // Ask iOS to deliver silent pushes (CloudKit subscriptions use APNs
        // under the hood). The user isn't prompted for this — only user-facing
        // notifications require the explicit permission prompt.
        application.registerForRemoteNotifications()

        return true
    }

    // MARK: - CloudKit share acceptance

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task { @MainActor in
            await LiveSharingService.shared.accept(shareMetadata: cloudKitShareMetadata)
        }
    }

    // MARK: - Remote notifications (silent CloudKit push)

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Nothing to do — CloudKit subscriptions don't need the device token.
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Silent pushes unavailable on this device (e.g. Simulator). Polling
        // fallback still works.
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable : Any],
        fetchCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completion(.noData)
            return
        }
        Task { @MainActor in
            await LiveSharingService.shared.handleSubscriptionPush()
            completion(.newData)
        }
    }

    // MARK: - Background refresh

    private static func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        // Always schedule the next run first — even if we fail, we want another chance.
        scheduleNextBackgroundRefresh()

        let work = Task { @MainActor in
            await LiveSharingService.shared.refreshFollowed()
            await LiveSharingService.shared.evaluateAlerts()
        }

        task.expirationHandler = {
            work.cancel()
        }

        Task {
            _ = await work.value
            task.setTaskCompleted(success: true)
        }
    }

    static func scheduleNextBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: CloudKitConfig.BackgroundTask.familyRefresh)
        // iOS chooses when to actually run this (usually during good-network /
        // charging moments). 15 min is a practical lower bound it respects.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
