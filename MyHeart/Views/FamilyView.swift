import SwiftUI
import CloudKit

/// The "Family" tab. Houses both perspectives of live sharing:
/// 1) "Sharing My Heart" — manage my outbound share (enable, invite, stop).
/// 2) "Following" — live status of people who shared with me.
struct FamilyView: View {
    @EnvironmentObject private var sharing: LiveSharingService
    @EnvironmentObject private var heartVM: HeartRateViewModel
    @EnvironmentObject private var profile: UserProfile

    @State private var shareSheet: ShareSheetState?
    @State private var showStopConfirm = false
    @State private var infoExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    accountBanner
                    sharingSection
                    followingSection
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
                        Task { await sharing.refreshFollowed() }
                    } label: {
                        if sharing.isWorking {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .refreshable {
                await sharing.refreshAccountStatus()
                await sharing.refreshFollowed()
            }
        }
        .sheet(item: $shareSheet) { state in
            CloudSharingSheet(
                share: state.share,
                container: state.container,
                onEnd: { shareSheet = nil }
            )
        }
        .confirmationDialog(
            "Stop sharing your heart rate?",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop Sharing", role: .destructive) {
                Task {
                    try? await sharing.stopSharing()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone you invited will immediately lose access to your live heart data.")
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
            if sharing.sharingEnabled {
                activeSharingView
            } else {
                inactiveSharingView
            }
            if let error = sharing.lastPublishError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
    }

    private var inactiveSharingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Share your live heart rate with family and trusted friends. Updates are pushed over iCloud — only people you invite can see them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task { await beginSharing() }
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
                Text("Live — \(sharing.participantCount) \(sharing.participantCount == 1 ? "person" : "people") can see your heart")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            if let status = sharing.lastPublishedStatus {
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(status.currentBPM)")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(.pink)
                            .monospacedDigit()
                        Text("BPM")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        zoneChip(status.zone)
                    }
                    HStack {
                        Text("Last sent \(status.updatedAt, style: .relative) ago")
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

            HStack(spacing: 10) {
                Button {
                    Task { await presentShareSheet() }
                } label: {
                    Label("Invite", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.pink.opacity(0.18)))
                        .foregroundStyle(.pink)
                }

                Button {
                    showStopConfirm = true
                } label: {
                    Label("Stop", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.18)))
                        .foregroundStyle(.primary)
                }
            }
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
                Text("When someone shares their heart with you, they'll appear here.")
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
        }
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
                    bullet("Only people you invite via the share sheet can see your live data.")
                    bullet("Updates are throttled to one every 30 seconds to save battery and iCloud quota.")
                    bullet("You can stop sharing anytime — watchers lose access immediately.")
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

    private func beginSharing() async {
        let status = currentStatusOrPlaceholder()
        do {
            let (_, share) = try await sharing.prepareShare(from: status)
            shareSheet = ShareSheetState(
                share: share,
                container: CKContainer(identifier: CloudKitConfig.containerIdentifier)
            )
        } catch {
            // Error is surfaced via sharing.lastPublishError
        }
    }

    private func presentShareSheet() async {
        let status = sharing.lastPublishedStatus ?? currentStatusOrPlaceholder()
        do {
            let (_, share) = try await sharing.prepareShare(from: status)
            shareSheet = ShareSheetState(
                share: share,
                container: CKContainer(identifier: CloudKitConfig.containerIdentifier)
            )
        } catch {
            // surfaced via error banner
        }
    }

    private func currentStatusOrPlaceholder() -> LiveHeartStatus {
        let latest = heartVM.summary.latest
        let maxHR = profile.maxHR
        let bpm = latest.map { Int($0.bpm.rounded()) } ?? 0
        let zone = latest.map { HeartRateZone(bpm: $0.bpm, maxHR: maxHR) } ?? .resting

        return LiveHeartStatus(
            id: CloudKitConfig.liveStatusRecordName,
            ownerID: nil,
            currentBPM: bpm,
            zoneRaw: zone.rawValue,
            restingBPM: heartVM.summary.restingBPM.map { Int($0.rounded()) },
            hrvMs: heartVM.summary.hrvSDNN,
            updatedAt: latest?.date ?? Date(),
            isElevated: bpm >= profile.elevatedThreshold,
            elevatedThreshold: profile.elevatedThreshold,
            displayName: profile.displayName,
            deviceName: latest?.source,
            maxHR: Int(maxHR.rounded()),
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
                Circle().fill(person.status.zone.color.opacity(0.18))
                Image(systemName: "person.fill")
                    .foregroundStyle(person.status.zone.color)
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
                    .foregroundStyle(person.status.isElevated ? .red : .pink)
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

private struct ShareSheetState: Identifiable {
    let id = UUID()
    let share: CKShare
    let container: CKContainer
}

#Preview {
    FamilyView()
        .environmentObject(LiveSharingService.shared)
        .environmentObject(HeartRateViewModel.preview)
        .environmentObject(UserProfile.shared)
}
