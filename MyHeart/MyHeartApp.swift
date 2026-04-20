import SwiftUI

@main
struct MyHeartApp: App {
    @StateObject private var viewModel = HeartRateViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .task { await viewModel.bootstrap() }
        }
    }
}
