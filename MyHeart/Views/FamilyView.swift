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

    @State private var showStopConfirm = false
    @State private var infoExpanded = false
    @State private var copiedLink = false
    @State private var pastedLink: String = ""
    @State private var showPasteField: Bool = false
    @State private var isAcceptingLink = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    accountBanner
                    if isProvisioningError {
                        setupGuideCard
                    } else {
                        sharingSection
                        followingSection
                    }
                    privacySection
                    Spacer(minLength: 24)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
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
            .refreshable { await refreshAll() }
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
                Task { try? await sharing.stopSharing() }  // errors surface via sharing.lastError
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone you invited will immediately lose access to your live heart data.")
        }
    }

    private func refreshAll() async {
        await sharing.refreshAccountStatus()
        guard sharing.accountStatus == .available else { return }
        await sharing.loadSharingState()
        await sharing.refreshFollowed()
    }

    // MARK: Provisioning detection

    private var isProvisioningError: Bool {
        sharing.lastError == .containerNotConfigured || sharing.followError == .containerNotConfigured
    }

    private var setupGuideCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
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

            HStack {
                Button {
                    sharing.lastError = nil
                    sharing.followError = nil
                    Task { await sharing.bootstrap() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.pink.opacity(0.18)))
                        .foregroundStyle(.pink)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
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
            .frame(width: 20, height: 20)
            Text(text)
                .font(.caption)
        }
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
            banner(icon: "wifi.slash", tint: .gray,
                   title: "Checking iCloud…",
                   message: "We're still confirming your iCloud account status.")
        case .temporarilyUnavailable:
            banner(icon: "clock", tint: .orange,
                   title: "iCloud is temporarily unavailable",
                   message: "Try again in a minute.")
        @unknown default:
            EmptyView()
        }
    }

    private func banner(icon: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(tint.opacity(0.12)))
    }

    // MARK: Sharing section

    private var sharingSection: some View {
        SectionCard(title: "Sharing My Heart", icon: "antenna.radiowaves.left.and.right") {
            if isQuotaError {
                quotaErrorCard
            } else if sharing.sharingEnabled {
                activeSharingView
            } else {
                inactiveSharingView
            }
            if !isQuotaError, let error = sharing.lastError {
                errorBanner(error.friendlyMessage) { sharing.lastError = nil }
            }
        }
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
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange))
                        .foregroundStyle(.white)
                }

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
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
    }

    @ViewBuilder
    private func stepRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.22))
                Text(number)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 18, height: 18)
            Text(text)
                .font(.caption)
        }
    }

    private func errorBanner(_ error: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
            Button("Dismiss", action: dismiss)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    private var inactiveSharingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Share your live heart rate with family and trusted friends. Updates go through your iCloud account — only people with your invite link can see them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task { await enableSharing() }
            } label: {
                HStack {
                    Image(systemName: "heart.fill")
                    Text("Start Live Sharing")
                        .fontWeight(.semibold)
                    Spacer()
                    if sharing.isWorking { ProgressView().tint(.white) }
                }
                .foregroundStyle(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.pink))
            }
            .disabled(sharing.accountStatus != .available || sharing.isWorking)
        }
    }

    private var activeSharingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(.green)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.green.opacity(0.35), lineWidth: 4).scaleEffect(1.6))
                Text(liveStatusText)
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            if let status = sharing.lastPublishedStatus, hasHeartRateData {
                livePreview(status: status)
            } else {
                Text("No heart-rate reading has been sent yet. Wear your Apple Watch — new readings are shared automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                Label("Stop Sharing", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.15)))
                    .foregroundStyle(.primary)
            }
        }
    }

    private var liveStatusText: String {
        if sharing.participantCount == 0 {
            return "Live — share the link below to invite"
        }
        return "Live — \(sharing.participantCount) \(sharing.participantCount == 1 ? "person is" : "people are") following"
    }

    private var hasHeartRateData: Bool {
        sharing.lastPublishedStatus.map { $0.currentBPM > 0 } ?? false
    }

    private func livePreview(status: LiveHeartStatus) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(status.currentBPM)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.pink)
                    .monospacedDigit()
                Text("BPM")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                zoneChip(status.zone)
            }
            HStack {
                Text("Measured \(status.updatedAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if status.isStale {
                    Label("Stale", systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemGroupedBackground)))
    }

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
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                }
                .foregroundStyle(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.pink))
            }

            Button {
                UIPasteboard.general.string = url.absoluteString
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                copiedLink = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedLink = false }
            } label: {
                HStack {
                    Image(systemName: copiedLink ? "checkmark.circle.fill" : "link")
                    Text(copiedLink ? "Copied!" : "Copy Link")
                        .fontWeight(.medium)
                    Spacer()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.pink.opacity(0.15)))
                .foregroundStyle(copiedLink ? Color.green : Color.pink)
            }

            Text(url.absoluteString)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 2)
        }
    }

    private func zoneChip(_ zone: HeartRateZone) -> some View {
        HStack(spacing: 5) {
            Image(systemName: zone.systemImage).font(.caption2.weight(.semibold))
            Text(zone.label).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(zone.color.opacity(0.18)))
        .foregroundStyle(zone.color)
    }

    // MARK: Following section

    private var followingSection: some View {
        SectionCard(title: "Following", icon: "person.2.fill") {
            if sharing.followed.isEmpty {
                Text("When someone shares their heart with you, tap their invite link — they'll show up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(sharing.followed) { person in
                        NavigationLink {
                            FollowDetailView(person: person)
                        } label: {
                            FollowedRow(person: person)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let error = sharing.followError, error != .containerNotConfigured {
                errorBanner(error.friendlyMessage) { sharing.followError = nil }
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
                    .font(.caption.weight(.medium))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.pink.opacity(0.15)))
                    .foregroundStyle(.pink)
            }
            .disabled(sharing.accountStatus != .available)
        } else {
            VStack(spacing: 8) {
                HStack {
                    TextField("https://www.icloud.com/share/…", text: $pastedLink)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    Button("Paste") {
                        pastedLink = UIPasteboard.general.string ?? pastedLink
                    }
                    .font(.caption)
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
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.15)))
                            .foregroundStyle(.primary)
                    }
                    Button {
                        guard let url = Self.inviteURL(from: pastedLink) else { return }
                        isAcceptingLink = true
                        Task {
                            let accepted = await sharing.acceptByURL(url)
                            isAcceptingLink = false
                            if accepted {
                                pastedLink = ""
                                showPasteField = false
                            }
                        }
                    } label: {
                        HStack {
                            if isAcceptingLink { ProgressView().tint(.white) }
                            Text("Follow").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.pink))
                        .foregroundStyle(.white)
                    }
                    .disabled(Self.inviteURL(from: pastedLink) == nil || isAcceptingLink)
                }
                if !pastedLink.isEmpty && Self.inviteURL(from: pastedLink) == nil {
                    Text("That doesn't look like an iCloud invite link (https://www.icloud.com/share/…).")
                        .font(.caption2)
                        .foregroundStyle(.orange)
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
                    Text("How live sharing works")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: infoExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)

            if infoExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Data is stored in your iCloud account and transmitted through Apple's servers. It never touches any MyHeart backend — there isn't one.")
                    bullet("The invite link itself is the access key — anyone who receives it can view your live heart rate (like a Google Docs \"anyone with the link\" share). Don't post it publicly. Share it only with people you trust.")
                    bullet("Tapping Stop Sharing revokes the link immediately; everyone loses access.")
                    bullet("New readings are sent as your Apple Watch syncs them to this iPhone — at most one update every 30 seconds; emergencies bypass the limit. If your iPhone is off or offline, followers see when the last reading was taken.")
                    bullet("Your emergency contact from Settings is included so followers can call it.")
                    bullet("Revoking iCloud access for MyHeart in iOS Settings also stops the feature.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text)
        }
    }

    // MARK: Actions

    private func enableSharing() async {
        do {
            try await sharing.startSharing(with: placeholderStatus())
            // Replace the placeholder with a real reading right away.
            await LiveStatusPublisher.shared.publishLatest(immediate: true)
        } catch {
            // Surfaces via sharing.lastError; the inline banner shows it.
        }
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

private struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.pink)
                Text(title).font(.headline)
                Spacer()
            }
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}

private struct FollowedRow: View {
    let person: FollowedPerson

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill((person.status.isEmergency ? Color.red : person.status.zone.color).opacity(0.18))
                Image(systemName: person.status.isEmergency ? "exclamationmark.triangle.fill" : "person.fill")
                    .foregroundStyle(person.status.isEmergency ? Color.red : person.status.zone.color)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(person.status.displayName)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Text(person.status.zone.label)
                        .foregroundStyle(person.status.zone.color)
                    Text("•")
                    Text("\(person.status.updatedAt, style: .relative) ago")
                        .foregroundStyle(.secondary)
                    if person.status.isStale {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
            }

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(person.status.currentBPM)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(person.status.isStale ? Color.secondary : (person.status.isElevated ? Color.red : Color.pink))
                Text("bpm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemGroupedBackground)))
    }
}

#Preview {
    FamilyView()
        .environmentObject(LiveSharingService.shared)
        .environmentObject(UserProfile.shared)
}
