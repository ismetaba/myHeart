import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @EnvironmentObject private var overviewVM: HealthOverviewViewModel
    @EnvironmentObject private var profile: UserProfile

    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("Health", systemImage: "heart.text.square.fill") }

            DashboardView()
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
            isPresented: .constant(viewModel.authorizationError != nil),
            actions: {
                Button("OK") { viewModel.authorizationError = nil }
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

import UserNotifications

#Preview {
    ContentView()
        .environmentObject(HeartRateViewModel.preview)
        .environmentObject(HealthOverviewViewModel.preview)
        .environmentObject(UserProfile.shared)
        .environmentObject(LiveSharingService.shared)
}
