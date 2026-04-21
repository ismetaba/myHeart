import SwiftUI

@main
struct MyHeartApp: App {
    @StateObject private var viewModel = HeartRateViewModel()
    @StateObject private var overviewVM = HealthOverviewViewModel()
    @StateObject private var profile = UserProfile.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(overviewVM)
                .environmentObject(profile)
                .tint(.pink)
                .task {
                    await viewModel.bootstrap()
                    await overviewVM.bootstrap()
                }
        }
    }
}
