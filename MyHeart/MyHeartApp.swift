import SwiftUI

@main
struct MyHeartApp: App {
    @StateObject private var viewModel = HeartRateViewModel()
    @StateObject private var profile = UserProfile.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(profile)
                .tint(.pink)
                .task { await viewModel.bootstrap() }
        }
    }
}
