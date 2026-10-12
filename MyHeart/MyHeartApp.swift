import SwiftUI

@main
struct MyHeartApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var viewModel = HeartRateViewModel()
    @StateObject private var overviewVM = HealthOverviewViewModel()
    @StateObject private var profile = UserProfile.shared
    @StateObject private var sharing = LiveSharingService.shared
    @StateObject private var router = AppRouter.shared
    @StateObject private var notifications = NotificationPermission.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(overviewVM)
                .environmentObject(profile)
                .environmentObject(sharing)
                .environmentObject(router)
                .environmentObject(notifications)
                // iCloud starts right away; HealthKit starts from ContentView
                // (after the welcome screen on first launch), so a slow iCloud
                // response never delays the dashboard and vice versa.
                .task { await sharing.bootstrap() }
                .task { await notifications.refresh() }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task {
                // Users may have changed notification access in Settings.
                await notifications.refresh()
                await viewModel.refreshIfStale()
                await overviewVM.refreshIfStale()
                await sharing.refreshOnForeground()
                await LiveStatusPublisher.shared.publishLatest()
            }
        }
    }
}
