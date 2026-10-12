import SwiftUI
import UserNotifications

struct ContentView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @EnvironmentObject private var overviewVM: HealthOverviewViewModel
    @EnvironmentObject private var profile: UserProfile

    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("Health", systemImage: "heart.text.square.fill") }

            // DashboardView is also pushed from the Health tab, so it doesn't
            // own a NavigationStack itself (nested stacks break navigation).
            NavigationStack { DashboardView() }
                .tabItem { Label("Heart", systemImage: "heart.fill") }

            FamilyView()
                .tabItem { Label("Family", systemImage: "person.2.fill") }

            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }

            SettingsView(profile: profile)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(.pink)
        .alert(
            "Health Access Needed",
            isPresented: Binding(
                get: { viewModel.authorizationError != nil },
                set: { if !$0 { viewModel.authorizationError = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) {}
            },
            message: { Text(viewModel.authorizationError ?? "") }
        )
        .task { await requestNotificationsIfNeeded() }
    }

    private func requestNotificationsIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
}

#Preview {
    ContentView()
        .environmentObject(HeartRateViewModel.preview)
        .environmentObject(HealthOverviewViewModel.preview)
        .environmentObject(UserProfile.shared)
        .environmentObject(LiveSharingService.shared)
}
