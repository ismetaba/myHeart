import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @EnvironmentObject private var profile: UserProfile

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "heart.fill") }

            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }

            SettingsView(profile: profile)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(.pink)
        .alert(
            "Health Access Needed",
            isPresented: .constant(viewModel.authorizationError != nil),
            actions: {
                Button("OK") { viewModel.authorizationError = nil }
            },
            message: { Text(viewModel.authorizationError ?? "") }
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(HeartRateViewModel.preview)
        .environmentObject(UserProfile.shared)
}
