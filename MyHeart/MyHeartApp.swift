import SwiftUI

@main
struct MyHeartApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var viewModel = HeartRateViewModel()
    @StateObject private var overviewVM = HealthOverviewViewModel()
    @StateObject private var profile = UserProfile.shared
    @StateObject private var sharing = LiveSharingService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(overviewVM)
                .environmentObject(profile)
                .environmentObject(sharing)
                .tint(.pink)
                // iCloud and HealthKit start independently so a slow iCloud
                // response never delays the dashboard (and vice versa).
                .task { await sharing.bootstrap() }
                .task {
                    // Health permission first, then everything that reads Health.
                    await viewModel.bootstrap()
                    await overviewVM.bootstrap()
                }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task {
                await viewModel.refreshIfStale()
                await overviewVM.refreshIfStale()
                await sharing.refreshOnForeground()
                await LiveStatusPublisher.shared.publishLatest()
            }
        }
    }
}
