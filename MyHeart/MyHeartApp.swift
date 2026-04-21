import SwiftUI

@main
struct MyHeartApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
                .task {
                    await viewModel.bootstrap()
                    await overviewVM.bootstrap()
                    await sharing.bootstrap()
                }
        }
    }
}
