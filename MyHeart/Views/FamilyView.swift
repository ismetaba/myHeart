import SwiftUI
import CloudKit
import UIKit

/// The "Family" tab. Houses both perspectives of live sharing:
/// 1) "Sharing My Heart" — manage my outbound share (enable, invite, stop).
/// 2) "Following" — live status of people who shared with me.
///
/// Uses SwiftUI's native `ShareLink` against the CloudKit share URL, instead of
/// wrapping `UICloudSharingController`. The controller doesn't always render
/// correctly inside a SwiftUI sheet (appears blank), and we only need to hand
/// off a short iCloud invite URL — which the standard share sheet handles
/// perfectly via iMessage / Mail / AirDrop / Copy.
struct FamilyView: View {
    @EnvironmentObject private var sharing: LiveSharingService
    @EnvironmentObject private var profile: UserProfile
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var notifications: NotificationPermission

    /// Followed person IDs (zone owner names), not `FollowedPerson` values:
    /// those are Hashable over their whole status, so a pushed value would
    /// stop matching after every refresh.
    @State private var path: [String] = []
    @State private var showStopConfirm = false
    @State private var showContactSheet = false
    @State private var infoExpanded = false
    @State private var copiedLink = false
    @State private var pastedLink: String = ""
    @State private var showPasteField: Bool = false
    @State private var isAcceptingLink = false
    @State private var isRetryingICloud = false

    @ScaledMetric(relativeTo: .caption2) private var setupStepSize: CGFloat = 20
    @ScaledMetric(relativeTo: .caption2) private var quotaStepSize: CGFloat = 18
    @ScaledMetric(relativeTo: .largeTitle) private var previewBPMSize: CGFloat = 42

    private static let followingAnchor = "following"

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        emergencySummary(proxy: proxy)
                        accountBanner
                        if isProvisioningError {
                            setupGuideCard
                        } else {
                            sharingSection
                            followingSection
                                .id(Self.followingAnchor)
                        }
                        privacySection
                        Spacer(minLength: 24)
                    }
                    .padding()
                    .readableContentWidth()
                }
                // The inline name field must not trap the keyboard.
                .scrollDismissesKeyboard(.interactively)
                .background(Color(.systemGroupedBackground))
                .refreshable { await refreshAll() }
                .navigationDestination(for: String.self) { personID in
                    FollowDetailDestination(personID: personID)
                }
            }
            .navigationTitle("Family")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        if sharing.isWorking || sharing.isRefreshingFollowed {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(sharing.isWorking || sharing.isRefreshingFollowed)
                    .accessibilityLabel("Refresh")
                }
            }
            // Keep the followed list reasonably live while this tab is open.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    await sharing.refreshFollowed()
                    await sharing.evaluateAlerts()
                }
            }
        }
        .confirmationDialog(
            "Stop sharing your heart rate?",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop Sharing", role: .destructive) {
                Task {
                    do {
                        try await sharing.stopSharing()
                        Haptics.success()
                    } catch {
                        Haptics.error()  // the message surfaces via sharing.lastError
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(stopSharingMessage)
        }
        .sheet(isPresented: $showContactSheet, onDismiss: { publishProfileChanges() }) {
            EmergencyContactSheet(profile: profile)
        }
        // Notification taps and accepted invites ask for a person; the route
        // waits until that person is in the list (on a cold launch they
        // aren't yet).
        .onAppear { consumePendingRoute() }
        .onChange(of: router.pendingFollowedID) { _ in consumePendingRoute() }
        .onChange(of: sharing.followed.map(\.id)) { _ in consumePendingRoute() }
        .onChange(of: sharing.isRefreshingFollowed) { _ in consumePendingRoute() }
        .onChange(of: sharing.hasBootstrapped) { _ in consumePendingRoute() }
        .onChange(of: sharing.justFollowedID) { id in
            if id != nil { Haptics.success() }
        }
        .onChange(of: router.selectedTab) { tab in
            if tab != .family { sharing.justFollowedID = nil }
        }
    }

    private func refreshAll() async {
        await sharing.refreshAccountStatus()
        guard sharing.accountStatus == .available else { return }
        await sharing.loadSharingState()
        await sharing.refreshFollowed()
    }

    // MARK: Routing

    private func consumePendingRoute() {
        guard let id = router.pendingFollowedID else { return }
        if sharing.followed.contains(where: { $0.id == id }) {
            // Replace, don't append: a tap on Mom's alert while Dad's detail
            // is open should show Mom, with Back going to the list.
            path = [id]
            router.pendingFollowedID = nil
        } else if sharing.hasBootstrapped && !sharing.isRefreshingFollowed {
            // Loaded and they're not there (e.g. no longer shared with us):
            // the list is the best we can show.
            router.pendingFollowedID = nil
        }
    }

    // MARK: Emergency summary

    /// Put anyone in a current emergency above everything else, so it's
    /// seen even when the list is long or scrolled away.
    @ViewBuilder
    private func emergencySummary(proxy: ScrollViewProxy) -> some View {
        let urgent = sortedFollowed.filter { $0.status.hasCurrentEmergency }
        if let first = urgent.first {
            Button {
                if urgent.count == 1 {
                    path = [first.id]
                } else {
                    withAnimation { proxy.scrollTo(Self.followingAnchor, anchor: .top) }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: first.status.emergencyKind?.systemImage ?? "exclamationmark.triangle.fill")
                        .font(.title2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(urgent.count == 1
                             ? "\(first.status.displayName) needs attention"
                             : "\(urgent.count) people need attention")
                            .font(.headline)
                        Text(urgent.count == 1
                             ? (first.status.emergencyKind?.label ?? "Emergency")
                             : ListFormatter.localizedString(byJoining: urgent.map(\.status.displayName)))
                            .font(.subheadline)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.white)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FamilyStyle.emergencyFill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(urgent.count == 1
                                ? "Emergency. \(first.status.displayName) needs attention: \(first.status.emergencyKind?.label ?? "emergency")"
                                : "Emergency. \(urgent.count) people need attention")
        }
    }

    // MARK: Provisioning detection

    private var isProvisioningError: Bool {
        sharing.lastError == .containerNotConfigured || sharing.followError == .containerNotConfigured
    }

    private var setupGuideCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Only developers can fix provisioning; release users just get
            // a plain "not available" with a retry.
            #if DEBUG
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("One-time Xcode setup required")
                    .font(.headline)
                Spacer()
            }

            Text("MyHeart's live-sharing uses iCloud CloudKit. Your Apple Developer team hasn't provisioned the container on Apple's servers yet — this is a one-time step.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                setupStep(1, "Open the project in Xcode.")
                setupStep(2, "Select the MyHeart target → Signing & Capabilities.")
                setupStep(3, "Pick your Apple ID under Team. (Add one via Settings → Accounts if needed.)")
                setupStep(4, "Make sure iCloud capability is added and CloudKit is ticked.")
                setupStep(5, "Select or create the container: iCloud.com.myheart.MyHeart.")
                setupStep(6, "Run the app again — this card will go away.")
            }
            #else
            HStack(spacing: 10) {
                Image(systemName: "icloud.slash")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Live sharing isn't available right now")
                    .font(.headline)
                Spacer()
            }
            Text("Please try again later.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            #endif

            Button {
                sharing.lastError = nil
                sharing.followError = nil
                Task { await sharing.bootstrap() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    @ViewBuilder
    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ZStack {
                Circle().fill(Color.pink.opacity(0.18))
                Text("\(number)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.pink)
            }
            .frame(width: setupStepSize, height: setupStepSize)
            .accessibilityHidden(true)
            Text(text)
                .font(.caption)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Account banner

    @ViewBuilder
    private var accountBanner: some View {
        switch sharing.accountStatus {
        case .available:
            EmptyView()
        case .noAccount:
            banner(icon: "icloud.slash", tint: .orange,
                   title: "Sign in to iCloud",
                   message: "Family sharing uses iCloud to deliver live heart data. Open Settings → Apple ID to sign in.")
        case .restricted:
            banner(icon: "icloud.slash", tint: .orange,
                   title: "iCloud is restricted",
                   message: "iCloud is disabled on this device by restrictions. Family sharing is unavailable.")
        case .couldNotDetermine:
            if sharing.hasCheckedAccount {
                banner(icon: "icloud.slash", tint: .orange,
                       title: "Couldn't reach iCloud",
                       message: "Check your internet connection, then try again.",
                       retry: true)
            } else {
                // Every launch starts here; it's a check, not a problem.
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking iCloud…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
            }
        case .temporarilyUnavailable:
            banner(icon: "clock", tint: .orange,
                   title: "iCloud is temporarily unavailable",
                   message: "Try again in a minute.",
                   retry: true)
        @unknown default:
            EmptyView()
        }
    }

    private func banner(icon: String, tint: Color, title: String, message: String, retry: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.footnote).foregroundStyle(.secondary)
                if retry {
                    Button {
                        isRetryingICloud = true
                        // A full bootstrap, so the zone and subscription get
                        // set up too if the first attempt never got that far.
                        Task {
                            await sharing.bootstrap()
                            isRetryingICloud = false
                        }
                    } label: {
                        if isRetryingICloud {
                            ProgressView()
                        } else {
                            Text("Retry")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRetryingICloud)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(0.12)))
    }

    // MARK: Sharing section

    private var sharingSection: some View {
        FamilySectionCard(title: "Sharing My Heart", icon: "antenna.radiowaves.left.and.right") {
            if isQuotaError {
                quotaErrorCard
            } else if isSharingStatePending {
                // Someone who already shares must not briefly see "Start".
                loadingRow("Checking your sharing status…")
            } else if sharing.sharingEnabled {
                activeSharingView
            } else {
                inactiveSharingView
            }
            if !isQuotaError, let error = sharing.lastError {
                errorBanner(error, retry: {
                    sharing.lastError = nil
                    Task {
                        await refreshAll()
                        if sharing.sharingEnabled {
                            await LiveStatusPublisher.shared.publishLatest(immediate: true)
                        }
                    }
                }, dismiss: { sharing.lastError = nil })
            }
        }
    }

    /// Starting up or reading the share. Once that's over without a result
    /// (no iCloud, or an error with its own banner) the normal view shows.
    private var isSharingStatePending: Bool {
        guard !sharing.didLoadSharingState else { return false }
        return !sharing.hasBootstrapped || sharing.isLoadingSharingState
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var isQuotaError: Bool {
        sharing.lastError == .quotaExceeded
    }

    private var quotaErrorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "icloud.slash.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Storage is Full")
                        .font(.headline)
                    Text("Can't publish your heart rate until you free up space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("MyHeart uses only a few kilobytes for live sharing — your iCloud account itself is out of space, usually from Photos or device Backups.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                stepRow("1", "Open Settings on your iPhone.")
                stepRow("2", "Tap your name at the top → iCloud.")
                stepRow("3", "Tap Manage Account Storage and delete what you don't need, or upgrade your plan.")
                stepRow("4", "Come back here and tap Retry.")
            }

            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    sharing.lastError = nil
                    Task {
                        if sharing.sharingEnabled {
                            await LiveStatusPublisher.shared.publishLatest(immediate: true)
                        } else {
                            await enableSharing()
                        }
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    @ViewBuilder
    private func stepRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.22))
                Text(number)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FamilyStyle.warningText)
            }
            .frame(width: quotaStepSize, height: quotaStepSize)
            .accessibilityHidden(true)
            Text(text)
                .font(.caption)
        }
        .accessibilityElement(children: .combine)
    }

    private func errorBanner(_ error: SharingError, retry: @escaping () -> Void, dismiss: @escaping () -> Void) -> some View {
        InlineBanner(
            message: error.friendlyMessage,
            actionTitle: error.isTransient ? "Retry" : nil,
            action: error.isTransient ? retry : nil,
            onDismiss: dismiss
        )
    }

    // MARK: Not sharing yet

    /// Says exactly what followers will see, and as whom, before a link
    /// anyone can open is created.
    private var inactiveSharingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share your live heart rate with family and trusted friends. Updates go through your iCloud account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Family will see you as")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Your name", text: $profile.displayName)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.name)
                    .submitLabel(.done)
                if needsName {
                    Label("Add your name so family can recognize you.", systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(FamilyStyle.warningText)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("They'll see")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                consentRow("heart.fill", "Live heart rate and zone")
                consentRow("chart.xyaxis.line", "Resting rate, HRV and 24-hour trend")
                emergencyContactRow(inConsent: true)
            }

            Label {
                Text("Anyone with your link can see this. Send it only to people you trust. You can stop at any time.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield.fill").foregroundStyle(.pink)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button {
                Task { await enableSharing() }
            } label: {
                HStack(spacing: 8) {
                    if sharing.isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "heart.fill")
                    }
                    Text("Start Live Sharing")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(sharing.accountStatus != .available || sharing.isWorking)
        }
    }

    /// Since iOS 16 the device name is just "iPhone", which tells family nothing.
    private var needsName: Bool {
        let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            || name.caseInsensitiveCompare(UIDevice.current.name) == .orderedSame
            || name.caseInsensitiveCompare(UIDevice.current.model) == .orderedSame
    }

    private func consentRow(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(.pink)
        }
        .font(.subheadline)
    }

    private var contactSummary: String {
        let name = profile.emergencyContactName.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = profile.emergencyContact.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? phone : "\(name) · \(phone)"
    }

    /// Followers can only call someone if the sharer set a contact, so show
    /// it (or its absence) where sharing is managed, not just in Settings.
    @ViewBuilder
    private func emergencyContactRow(inConsent: Bool) -> some View {
        if profile.hasEmergencyContact {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if inConsent {
                    consentRow("phone.fill", "Emergency contact: \(contactSummary)")
                } else {
                    Label {
                        Text("\(contactSummary). Family can call them in one tap from MyHeart.")
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "phone.fill").foregroundStyle(.pink)
                    }
                    .font(.footnote)
                }
                Spacer(minLength: 8)
                Button("Edit") { showContactSheet = true }
                    .font(.footnote.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Edit emergency contact")
            }
        } else {
            Button {
                showContactSheet = true
            } label: {
                Label("No emergency contact. Add one", systemImage: "phone.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(FamilyStyle.warningText)
        }
    }

    // MARK: Sharing

    private var activeSharingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Staleness depends on the clock, so re-check it while the
            // screen sits open.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                sharerStatusRow(sharerState(now: context.date))
            }

            Label {
                Text(followersText)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "person.2.fill").foregroundStyle(.pink)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let status = sharing.lastPublishedStatus, hasHeartRateData {
                livePreview(status: status)
            } else {
                Text("No heart-rate reading has been sent yet. Wear your Apple Watch — new readings are shared automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            emergencyContactRow(inConsent: false)

            if let url = sharing.currentShareURL {
                shareLinkBlock(url: url)
            } else {
                Text("Preparing invite link…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                showStopConfirm = true
            } label: {
                HStack(spacing: 8) {
                    if sharing.isWorking {
                        ProgressView()
                    } else {
                        Image(systemName: "xmark.circle.fill")
                    }
                    Text("Stop Sharing")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(sharing.isWorking)
        }
    }

    /// What followers are actually getting right now — a green "Live" only
    /// when that's true.
    private enum SharerState: Equatable {
        case live
        case waiting(lastReading: Date?)
        case failing
    }

    private func sharerState(now: Date) -> SharerState {
        if sharing.lastError != nil { return .failing }
        guard let status = sharing.lastPublishedStatus, status.hasReading else {
            return .waiting(lastReading: nil)
        }
        if now.timeIntervalSince(status.updatedAt) > LiveHeartStatus.staleAfter {
            return .waiting(lastReading: status.updatedAt)
        }
        return .live
    }

    private func sharerStatusRow(_ state: SharerState) -> some View {
        let color: Color
        let text: String
        switch state {
        case .live:
            color = .green
            text = "Live — family sees your latest reading"
        case .waiting(let lastReading?):
            color = .orange
            text = "Sharing is on, but there's no new reading since \(lastReading.formatted(date: .omitted, time: .shortened)). Is your Apple Watch on?"
        case .waiting(.none):
            color = .orange
            text = "Sharing is on. Waiting for your first reading — is your Apple Watch on?"
        case .failing:
            color = .red
            text = "Not updating. See the message below."
        }
        return HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 4).scaleEffect(1.6))
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var followersText: String {
        let count = sharing.participantCount
        if count == 0 {
            return "No one has joined yet. Send your link below."
        }
        // iCloud doesn't always reveal who joined through a public link.
        let names = sharing.participantNames
        if names.count >= count {
            return "Following you: \(ListFormatter.localizedString(byJoining: names))"
        }
        return count == 1 ? "1 person follows you" : "\(count) people follow you"
    }

    private var stopSharingMessage: String {
        switch sharing.participantCount {
        case 0:
            return "Your invite link will stop working. If you start again, you'll get a new link."
        case 1:
            return "1 person following you will lose access right away. You can't remove just one person. If you start again, you'll need to send everyone a new link."
        case let count:
            return "\(count) people following you will lose access right away. You can't remove just one person. If you start again, you'll need to send everyone a new link."
        }
    }

    private var hasHeartRateData: Bool {
        sharing.lastPublishedStatus.map { $0.currentBPM > 0 } ?? false
    }

    private func livePreview(status: LiveHeartStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(status.currentBPM)")
                    .font(.system(size: min(previewBPMSize, 42 * 1.6), weight: .bold, design: .rounded))
                    .foregroundStyle(.pink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("BPM")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                ZoneChip(zone: status.zone)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Last shared reading: \(status.currentBPM) beats per minute, \(status.zone.label) zone")
            ReadingTimeText(date: status.updatedAt, prefix: "Measured")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
    }

    /// No raw URL on screen: it means nothing to most people, and a
    /// screenshot of it is effectively the access key.
    @ViewBuilder
    private func shareLinkBlock(url: URL) -> some View {
        VStack(spacing: 8) {
            ShareLink(
                item: url,
                subject: Text("\(profile.effectiveDisplayName)'s Heart Rate"),
                message: Text("Follow \(profile.effectiveDisplayName)'s live heart rate in MyHeart")
            ) {
                HStack {
                    Image(systemName: "person.crop.circle.badge.plus")
                    Text("Invite via Messages, Mail, AirDrop…")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                UIPasteboard.general.string = url.absoluteString
                Haptics.success()
                copiedLink = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedLink = false }
            } label: {
                HStack {
                    Image(systemName: copiedLink ? "checkmark.circle.fill" : "link")
                    Text(copiedLink ? "Copied!" : "Copy Link")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(copiedLink ? Color.green : Color.pink)
        }
    }

    // MARK: Following section

    /// Emergencies first, then fresh elevated readings, then everyone else
    /// by name. Sorted here so `sharing.followed` keeps a stable order for
    /// other consumers.
    private var sortedFollowed: [FollowedPerson] {
        sharing.followed.sorted { a, b in
            let rankA = Self.triageRank(a.status)
            let rankB = Self.triageRank(b.status)
            if rankA != rankB { return rankA < rankB }
            return a.status.displayName.localizedCaseInsensitiveCompare(b.status.displayName) == .orderedAscending
        }
    }

    private static func triageRank(_ status: LiveHeartStatus) -> Int {
        if status.hasCurrentEmergency { return 0 }
        if status.isEmergency { return 1 }  // possibly outdated, still worth a look
        if status.isElevated && !status.isStale { return 2 }
        return 3
    }

    private var followingSection: some View {
        FamilySectionCard(title: "Following", icon: "person.2.fill") {
            if let id = sharing.justFollowedID,
               let person = sharing.followed.first(where: { $0.id == id }) {
                InlineBanner(
                    message: notifications.isDenied
                        ? "You're now following \(person.status.displayName). Turn on notifications to be alerted if their heart rate is very high or low."
                        : "You're now following \(person.status.displayName). You'll get an alert if their heart rate is very high or low.",
                    systemImage: "checkmark.circle.fill",
                    tint: .green,
                    onDismiss: { sharing.justFollowedID = nil }
                )
            }

            if !sharing.followed.isEmpty && notifications.isDenied {
                InlineBanner(
                    message: "Notifications are off for MyHeart, so you won't be alerted about the people you follow, even in an emergency.",
                    systemImage: "bell.slash.fill",
                    actionTitle: "Turn On in Settings",
                    action: { notifications.openSystemSettings() }
                )
            }

            if sharing.followed.isEmpty {
                if sharing.hasBootstrapped {
                    Text("When someone shares their heart with you, tap their invite link — they'll show up here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    loadingRow("Loading the people you follow…")
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(sortedFollowed) { person in
                        NavigationLink(value: person.id) {
                            FollowedRow(person: person)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .animation(.default, value: sortedFollowed.map(\.id))
            }

            if let error = sharing.followError, error != .containerNotConfigured {
                errorBanner(error, retry: {
                    sharing.followError = nil
                    Task { await refreshAll() }
                }, dismiss: { sharing.followError = nil })
            }

            pasteLinkControls
        }
    }

    /// Fallback for when tapping the iCloud link didn't open MyHeart (e.g. it
    /// was opened in Safari). Always available, so you can follow more than
    /// one person.
    @ViewBuilder
    private var pasteLinkControls: some View {
        if !showPasteField {
            Button {
                withAnimation { showPasteField = true }
                if let pasted = UIPasteboard.general.string,
                   Self.inviteURL(from: pasted) != nil {
                    pastedLink = pasted
                }
            } label: {
                Label("Paste Invite Link", systemImage: "link")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(sharing.accountStatus != .available)
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    TextField("https://www.icloud.com/share/…", text: $pastedLink)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    Button {
                        pastedLink = UIPasteboard.general.string ?? pastedLink
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Paste")
                }
                HStack(spacing: 8) {
                    Button {
                        withAnimation {
                            showPasteField = false
                            pastedLink = ""
                        }
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)

                    Button {
                        guard let url = Self.inviteURL(from: pastedLink) else { return }
                        isAcceptingLink = true
                        Task {
                            let accepted = await sharing.acceptByURL(url)
                            isAcceptingLink = false
                            if accepted {
                                // The success haptic plays with the confirmation.
                                pastedLink = ""
                                showPasteField = false
                            } else {
                                Haptics.error()
                            }
                        }
                    } label: {
                        HStack {
                            if isAcceptingLink { ProgressView().tint(.white) }
                            Text("Follow").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(Self.inviteURL(from: pastedLink) == nil || isAcceptingLink)
                }
                .controlSize(.large)
                if !pastedLink.isEmpty && Self.inviteURL(from: pastedLink) == nil {
                    Text("That doesn't look like an iCloud invite link (https://www.icloud.com/share/…).")
                        .font(.footnote)
                        .foregroundStyle(FamilyStyle.warningText)
                }
            }
        }
    }

    /// Extracts an iCloud share URL from pasted text (which may include the
    /// invite message around the link).
    static func inviteURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [trimmed] + trimmed.components(separatedBy: .whitespacesAndNewlines)
        for candidate in candidates {
            guard let url = URL(string: candidate),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  host == "icloud.com" || host.hasSuffix(".icloud.com"),
                  url.path.lowercased().hasPrefix("/share") else { continue }
            return url
        }
        return nil
    }

    // MARK: Privacy section

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation { infoExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.pink)
                        .accessibilityHidden(true)
                    Text("How live sharing works")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: infoExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .accessibilityValue(infoExpanded ? "Expanded" : "Collapsed")

            if infoExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Data is stored in your iCloud account and transmitted through Apple's servers. It never touches any MyHeart backend — there isn't one.")
                    bullet("The invite link itself is the access key — anyone who receives it can view your live heart rate (like a Google Docs \"anyone with the link\" share). Don't post it publicly. Share it only with people you trust.")
                    bullet("Tapping Stop Sharing revokes the link immediately; everyone loses access. Starting again creates a new link.")
                    bullet("New readings are sent as your Apple Watch syncs them to this iPhone — at most one update every 30 seconds; emergencies bypass the limit. If your iPhone is off or offline, followers see when the last reading was taken.")
                    bullet("Your emergency contact is included so followers can call it.")
                    bullet("Revoking iCloud access for MyHeart in iOS Settings also stops the feature.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").accessibilityHidden(true)
            Text(text)
        }
    }

    // MARK: Actions

    private func enableSharing() async {
        do {
            try await sharing.startSharing(with: placeholderStatus())
            Haptics.success()
            // Replace the placeholder with a real reading right away.
            await LiveStatusPublisher.shared.publishLatest(immediate: true)
        } catch {
            // Surfaces via sharing.lastError; the inline banner shows it.
            Haptics.error()
        }
    }

    /// A new contact (or name) should reach followers now, not with the
    /// next heart-rate sample.
    private func publishProfileChanges() {
        guard sharing.sharingEnabled else { return }
        Task { await LiveStatusPublisher.shared.publishLatest(immediate: true) }
    }

    /// Minimal record content for creating the share; the live publisher
    /// overwrites it with the newest HealthKit reading immediately after.
    private func placeholderStatus() -> LiveHeartStatus {
        let previous = sharing.lastPublishedStatus
        return LiveHeartStatus(
            id: CloudKitConfig.liveStatusRecordName,
            ownerID: nil,
            currentBPM: previous?.currentBPM ?? 0,
            zoneRaw: previous?.zoneRaw ?? HeartRateZone.resting.rawValue,
            restingBPM: previous?.restingBPM,
            hrvMs: previous?.hrvMs,
            updatedAt: previous?.updatedAt ?? Date(),
            isElevated: false,
            elevatedThreshold: profile.elevatedThreshold,
            displayName: profile.effectiveDisplayName,
            deviceName: previous?.deviceName,
            maxHR: Int(profile.maxHR.rounded()),
            note: nil
        )
    }
}

// MARK: - Pieces

/// Card with the standard Family header (pink icon, headline title) and an
/// optional trailing accessory, e.g. an "Updated …" label. Shared with
/// `FollowDetailView` so every card header on these screens matches.
struct FamilySectionCard<Content: View, Trailing: View>: View {
    let title: String
    let icon: String
    private let trailing: () -> Trailing
    private let content: () -> Content

    init(
        title: String,
        icon: String,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.pink)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing()
            }
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

extension FamilySectionCard where Trailing == EmptyView {
    init(title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, icon: icon, trailing: { EmptyView() }, content: content)
    }
}

/// Resolves a pushed person ID to the live `followed` entry. Keeps the last
/// known copy if they drop out of the list (unfollowed, or the sharer
/// stopped), so the detail doesn't flip to a blank state mid-pop; the detail
/// explains a stopped share itself.
private struct FollowDetailDestination: View {
    @EnvironmentObject private var sharing: LiveSharingService
    let personID: String
    @State private var lastKnown: FollowedPerson?

    var body: some View {
        if let person = sharing.followed.first(where: { $0.id == personID }) ?? lastKnown {
            FollowDetailView(person: person)
                .onAppear { if lastKnown == nil { lastKnown = person } }
        } else if sharing.hasBootstrapped && !sharing.isRefreshingFollowed {
            ScrollView {
                EmptyStateView(
                    systemImage: "person.crop.circle.badge.questionmark",
                    title: "Not available",
                    message: "This person is no longer shared with you."
                )
                .padding(.top, 40)
            }
            .background(Color(.systemGroupedBackground))
        } else {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
        }
    }
}

/// Lets the sharer add or fix the emergency contact without leaving the
/// Family tab. A sheet with its own stack, because pushing SettingsView
/// (which owns a NavigationStack) would nest stacks.
private struct EmergencyContactSheet: View {
    @ObservedObject var profile: UserProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Contact Name")
                        Spacer()
                        TextField("Optional", text: $profile.emergencyContactName)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.name)
                    }
                    HStack {
                        Text("Phone")
                        Spacer()
                        TextField("+1 555 555 5555", text: $profile.emergencyContact)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.telephoneNumber)
                            .keyboardType(.phonePad)
                    }
                } footer: {
                    Text("Shared with the people who follow you, so they can call this person in one tap if your heart rate is very high or low. You can also change it in Settings.")
                }
            }
            .navigationTitle("Emergency Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct FollowedRow: View {
    let person: FollowedPerson
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var status: LiveHeartStatus { person.status }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Stacked so the name, state and number aren't truncated.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        avatar
                        nameText
                    }
                    subline
                    bpm
                }
            } else {
                HStack(spacing: 12) {
                    avatar
                    VStack(alignment: .leading, spacing: 2) {
                        nameText
                        subline
                    }
                    Spacer(minLength: 8)
                    bpm
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var avatar: some View {
        ZStack {
            Circle().fill((status.isEmergency ? Color.red : status.zone.color).opacity(0.18))
            Image(systemName: status.isEmergency ? "exclamationmark.triangle.fill" : "person.fill")
                .foregroundStyle(status.isEmergency ? FamilyStyle.emergencyText : status.zone.textColor)
        }
        .frame(width: 40, height: 40)
    }

    private var nameText: some View {
        Text(status.displayName)
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Emergencies are spelled out, not just tinted; stale data says so.
    @ViewBuilder
    private var subline: some View {
        Group {
            if status.isEmergency {
                Text((status.emergencyKind?.label ?? "Emergency") + (status.isStale ? " · may be outdated" : ""))
                    .fontWeight(.bold)
                    .foregroundStyle(FamilyStyle.emergencyText)
            } else if status.hasReading && status.isStale {
                HStack(spacing: 4) {
                    Text("No recent reading ·")
                    ReadingTimeText(date: status.updatedAt, showsClockTime: false)
                }
                .foregroundStyle(FamilyStyle.warningText)
            } else if status.hasReading {
                HStack(spacing: 6) {
                    Text(status.zone.label)
                        .foregroundStyle(status.zone.textColor)
                    Text("•")
                        .foregroundStyle(.secondary)
                    ReadingTimeText(date: status.updatedAt, showsClockTime: false)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No reading yet")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var bpm: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            // Elevated gets a symbol too, not only a color change.
            if status.isElevated && !status.isStale && !status.isEmergency {
                Image(systemName: "arrow.up.heart.fill")
                    .font(.caption)
                    .foregroundStyle(FamilyStyle.warningText)
            }
            Text(status.hasReading ? "\(status.currentBPM)" : "—")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(bpmColor)
            Text("bpm")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var bpmColor: Color {
        if status.isStale { return .secondary }
        if status.isEmergency { return FamilyStyle.emergencyText }
        if status.isElevated { return FamilyStyle.warningText }
        return .pink
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if status.isEmergency {
            shape
                .fill(Color.red.opacity(0.12))
                .overlay(shape.strokeBorder(Color.red.opacity(0.6), lineWidth: 1))
        } else {
            shape.fill(Color(.tertiarySystemGroupedBackground))
        }
    }

    private var accessibilityText: String {
        var parts = [status.displayName]
        if status.isEmergency {
            parts.append("Emergency: \(status.emergencyKind?.label ?? "emergency")")
        }
        if status.hasReading {
            let when = ReadingTimeText.spokenRelative(status.updatedAt)
            if status.isStale {
                parts.append("\(status.currentBPM) beats per minute, last reading \(when), may be outdated")
            } else {
                let elevated = status.isElevated && !status.isEmergency ? ", above usual limit" : ""
                parts.append("\(status.currentBPM) beats per minute, \(status.zone.label) zone\(elevated), \(when)")
            }
        } else {
            parts.append("No reading yet")
        }
        return parts.joined(separator: ". ") + "."
    }
}

#Preview {
    FamilyView()
        .environmentObject(LiveSharingService.shared)
        .environmentObject(UserProfile.shared)
        .environmentObject(AppRouter.shared)
        .environmentObject(NotificationPermission.shared)
}
