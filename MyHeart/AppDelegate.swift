import UIKit
import CloudKit
import BackgroundTasks
import UserNotifications

/// Bridges a handful of iOS-level callbacks that SwiftUI doesn't expose:
///   - CloudKit share acceptance (both AppDelegate and UIScene paths)
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

    // MARK: - CloudKit share acceptance (AppDelegate path)

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        print("[Sharing][AppDelegate] userDidAcceptCloudKitShareWith fired, owner=\(cloudKitShareMetadata.ownerIdentity.userRecordID?.recordName ?? "?") root=\(cloudKitShareMetadata.hierarchicalRootRecordID?.recordName ?? "?")")
        Task { @MainActor in
            await LiveSharingService.shared.accept(shareMetadata: cloudKitShareMetadata)
        }
    }

    // MARK: - UIScene bridging
    //
    // On iOS 13+ the share-accept callback is usually delivered to the *scene
    // delegate* when the app is launched or brought to the foreground via a
    // share URL. SwiftUI doesn't let us register one directly, so we wire it up
    // via UIApplicationDelegate's configurationForConnecting.

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = ShareAcceptingSceneDelegate.self
        return config
    }

    // MARK: - Remote notifications (silent CloudKit push)

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        print("[Sharing][AppDelegate] remote notifications registered")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[Sharing][AppDelegate] remote notifications unavailable: \(error.localizedDescription)")
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
        scheduleNextBackgroundRefresh()
        let work = Task { @MainActor in
            await LiveSharingService.shared.refreshFollowed()
            await LiveSharingService.shared.evaluateAlerts()
        }
        task.expirationHandler = { work.cancel() }
        Task {
            _ = await work.value
            task.setTaskCompleted(success: true)
        }
    }

    static func scheduleNextBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: CloudKitConfig.BackgroundTask.familyRefresh)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

// MARK: - Scene delegate for share acceptance

/// Minimal scene delegate whose only job is forwarding CKShare accepts into
/// `LiveSharingService`. SwiftUI still drives the visual lifecycle.
final class ShareAcceptingSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            print("[Sharing][Scene] willConnectTo delivered share metadata")
            Task { @MainActor in
                await LiveSharingService.shared.accept(shareMetadata: metadata)
            }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        print("[Sharing][Scene] userDidAcceptCloudKitShareWith fired")
        Task { @MainActor in
            await LiveSharingService.shared.accept(shareMetadata: metadata)
        }
    }
}
