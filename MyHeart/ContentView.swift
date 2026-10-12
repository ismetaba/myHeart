import SwiftUI
import Combine
import HealthKit

struct ContentView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @EnvironmentObject private var overviewVM: HealthOverviewViewModel
    @EnvironmentObject private var profile: UserProfile
    @EnvironmentObject private var sharing: LiveSharingService
    @EnvironmentObject private var router: AppRouter

    @AppStorage("onboarding.done") private var didOnboard = false
    @State private var showOnboarding = false
    @State private var didStartHealth = false

    var body: some View {
        TabView(selection: $router.selectedTab) {
            OverviewView()
                .tabItem { Label("Health", systemImage: "heart.text.square.fill") }
                .tag(AppTab.health)

            // DashboardView is also pushed from the Health tab, so it doesn't
            // own a NavigationStack itself (nested stacks break navigation).
            NavigationStack { DashboardView() }
                .tabItem { Label("Heart", systemImage: "heart.fill") }
                .tag(AppTab.heart)

            FamilyView()
                .tabItem { Label("Family", systemImage: "person.2.fill") }
                .tag(AppTab.family)
                // Someone you follow is in an emergency right now.
                .badge(currentEmergencyCount)

            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
                .tag(AppTab.history)

            SettingsView(profile: profile)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
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
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(healthAvailable: HKHealthStore.isHealthDataAvailable()) {
                await finishOnboarding()
            }
        }
        .task { await startHealthIfReady() }
        // Ask for notification permission when it starts to matter — once
        // you follow someone — instead of on first launch with no context.
        .onReceive(sharing.$followed.map { !$0.isEmpty }.removeDuplicates()) { _ in
            requestNotificationsIfReady()
        }
    }

    /// Not over the welcome screen: the followed list can load from iCloud
    /// before onboarding is finished.
    private func requestNotificationsIfReady() {
        guard didOnboard, !showOnboarding, !sharing.followed.isEmpty else { return }
        Task { await NotificationPermission.shared.requestIfNeeded() }
    }

    private var currentEmergencyCount: Int {
        sharing.followed.filter { $0.status.hasCurrentEmergency }.count
    }

    /// Existing users (who already answered the Health permission sheet) go
    /// straight in; new users first see the welcome screen.
    private func startHealthIfReady() async {
        guard !didStartHealth else { return }
        if !didOnboard, await HealthKitManager.shared.hasRequestedAuthorization() {
            didOnboard = true
        }
        if didOnboard {
            didStartHealth = true
            requestNotificationsIfReady()
            await loadHealthData(authorized: await viewModel.authorize())
        } else {
            showOnboarding = true
        }
    }

    private func finishOnboarding() async {
        didStartHealth = true
        // Presents the Health permission sheet over the welcome screen.
        let authorized = await viewModel.authorize()
        didOnboard = true
        showOnboarding = false
        requestNotificationsIfReady()
        await loadHealthData(authorized: authorized)
    }

    /// Loads the Heart and Health tabs side by side, so the Health tab (the
    /// first one users see) doesn't wait for a long heart-rate range.
    /// The overview always bootstraps — its screen relies on `hasLoaded`.
    private func loadHealthData(authorized: Bool) async {
        let heart = Task { @MainActor in
            if authorized { await viewModel.refresh() }
        }
        await overviewVM.bootstrap()
        await heart.value
    }
}

// MARK: - Onboarding

/// One welcome screen shown before the Health permission sheet, so the
/// system prompt doesn't appear out of nowhere on first launch.
struct OnboardingView: View {
    let healthAvailable: Bool
    let onContinue: () async -> Void
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.pink)
                    .padding(.top, 48)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Welcome to MyHeart")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Your heart rate, made clear — and shared with the people who care.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 20) {
                    feature("waveform.path.ecg", "Understand your heart",
                            "Heart rate, zones, trends and PDF reports from Apple Watch and Apple Health.")
                    feature("person.2.fill", "Share with family",
                            "Let people you trust follow your live heart rate — or follow theirs.")
                    feature("bell.badge.fill", "Get alerted",
                            "Optional alerts when someone you follow has a high or critical heart rate.")
                    feature("lock.shield.fill", "Private by design",
                            "Your data stays in Apple Health and your own iCloud. There is no MyHeart server.")
                }

                Text(healthAvailable
                     ? "Next, iOS asks which Health data MyHeart may read. MyHeart never writes to Apple Health."
                     : "Apple Health isn't available on this device, but you can still follow family members.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .readableContentWidth(560)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                guard !isWorking else { return }
                isWorking = true
                Task {
                    await onContinue()
                    isWorking = false
                }
            } label: {
                HStack {
                    if isWorking { ProgressView().tint(.white) }
                    Text(healthAvailable ? "Continue" : "Get Started")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .readableContentWidth(560)
            .background(.bar)
        }
        .interactiveDismissDisabled()
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.pink)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ContentView()
        .environmentObject(HeartRateViewModel.preview)
        .environmentObject(HealthOverviewViewModel.preview)
        .environmentObject(UserProfile.shared)
        .environmentObject(LiveSharingService.shared)
        .environmentObject(AppRouter.shared)
        .environmentObject(NotificationPermission.shared)
}
