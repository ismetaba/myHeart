import SwiftUI

/// Detail for one followed person. Auto-refreshes while visible so the live
/// BPM stays current. Throttles to 30s refreshes to align with the writer
/// side's publish cadence.
struct FollowDetailView: View {
    @EnvironmentObject private var sharing: LiveSharingService
    @State private var current: FollowedPerson
    @State private var refreshTimer: Timer?
    @State private var showUnfollowConfirm = false
    @AppStorage private var alertThreshold: Int

    init(person: FollowedPerson) {
        self._current = State(initialValue: person)
        self._alertThreshold = AppStorage(wrappedValue: 130, "follow.alert.\(person.id)")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard
                statsRow
                alertsCard
                metaCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(current.status.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showUnfollowConfirm = true
                    } label: {
                        Label("Stop Following", systemImage: "person.crop.circle.badge.minus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Stop following \(current.status.displayName)?",
            isPresented: $showUnfollowConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop Following", role: .destructive) {
                Task { await sharing.unfollow(current) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { startAutoRefresh() }
        .onDisappear { stopAutoRefresh() }
        .refreshable { await refreshNow() }
    }

    // MARK: Hero

    private var heroCard: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(.green)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.green.opacity(0.35), lineWidth: 4).scaleEffect(1.6))
                Text("Live")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                Spacer()
                Text("Updated \(current.status.updatedAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(current.status.currentBPM)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(current.status.isElevated ? .red : .pink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("BPM")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            zoneRow

            if current.status.isStale {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Last update over 5 minutes ago")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var zoneRow: some View {
        HStack(spacing: 6) {
            Image(systemName: current.status.zone.systemImage)
                .font(.caption.weight(.semibold))
            Text(current.status.zone.label)
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(current.status.zone.color.opacity(0.18)))
        .foregroundStyle(current.status.zone.color)
    }

    // MARK: Stats

    private var statsRow: some View {
        HStack(spacing: 10) {
            statTile(title: "Resting", value: current.status.restingBPM.map { "\($0)" } ?? "—", unit: "bpm", icon: "bed.double.fill")
            statTile(title: "HRV", value: current.status.hrvMs.map { String(format: "%.0f", $0) } ?? "—", unit: "ms", icon: "waveform.path.ecg")
            statTile(title: "Max HR", value: "\(current.status.maxHR)", unit: "bpm", icon: "bolt.heart.fill")
        }
    }

    private func statTile(title: String, value: String, unit: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.pink)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: Alerts

    private var alertsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Alerts", systemImage: "bell.badge.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
            }

            Stepper(value: $alertThreshold, in: 60...200, step: 5) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notify me if BPM ≥ \(alertThreshold)")
                        .font(.subheadline.weight(.medium))
                    Text("Alerts only fire while MyHeart is running. Apple Watch wearers get push notifications.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: Meta

    private var metaCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            metaRow("Source", value: current.status.deviceName ?? "Unknown device")
            metaRow("Zone range", value: zoneRangeText)
            metaRow("Elevated above", value: "\(current.status.elevatedThreshold) bpm")
            metaRow("Record ID", value: current.status.id)
        }
        .font(.caption)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var zoneRangeText: String {
        let range = current.status.zone.range(maxHR: Double(current.status.maxHR))
        if current.status.zone == .peak { return "\(range.lowerBound)+ bpm" }
        return "\(range.lowerBound) – \(range.upperBound) bpm"
    }

    @ViewBuilder
    private func metaRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary).lineLimit(1)
        }
    }

    // MARK: Refresh

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { await refreshNow() }
        }
        // Immediate refresh
        Task { await refreshNow() }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshNow() async {
        if let updated = await sharing.refreshFollowed(person: current) {
            withAnimation { current = updated }
            maybeTriggerAlert(for: updated)
        }
    }

    private func maybeTriggerAlert(for person: FollowedPerson) {
        guard person.status.currentBPM >= alertThreshold else { return }
        let key = "lastAlert.\(person.id)"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        if now - last < 600 { return }  // rate-limit local alerts to 10 minutes
        UserDefaults.standard.set(now, forKey: key)
        fireLocalNotification(for: person)
    }

    private func fireLocalNotification(for person: FollowedPerson) {
        let content = UNMutableNotificationContent()
        content.title = "\(person.status.displayName) — elevated heart rate"
        content.body = "Currently \(person.status.currentBPM) BPM (threshold \(alertThreshold))"
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "followed.\(person.id).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Notifications import

import UserNotifications
