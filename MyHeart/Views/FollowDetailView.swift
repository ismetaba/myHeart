import SwiftUI
import Charts
import UserNotifications

/// Detail for one followed person. Auto-refreshes while visible so the live
/// BPM stays current. Throttles to 30s refreshes to align with the writer
/// side's publish cadence.
struct FollowDetailView: View {
    @EnvironmentObject private var sharing: LiveSharingService
    @EnvironmentObject private var profile: UserProfile
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
                if current.status.isEmergency { emergencyBanner }
                heroCard
                statsRow
                if !current.status.trendHourlyBPM.isEmpty { trendCard }
                alertsCard
                emergencyContactCard
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

    // MARK: Emergency banner

    private var emergencyBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: current.status.emergencyKind?.systemImage ?? "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.status.emergencyKind?.label ?? "Emergency")
                        .font(.subheadline.weight(.semibold))
                    if let since = current.status.emergencySince {
                        Text("Since \(since, style: .time) (\(since, style: .relative) ago)")
                            .font(.caption2)
                            .opacity(0.9)
                    }
                }
                Spacer()
            }
            if profile.hasEmergencyContact {
                Button {
                    callEmergencyContact()
                } label: {
                    HStack {
                        Image(systemName: "phone.fill")
                        Text("Call \(profile.emergencyContactName.isEmpty ? profile.emergencyContact : profile.emergencyContactName)")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.2))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.red))
        .foregroundStyle(.white)
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
                    .foregroundStyle(current.status.isEmergency ? .red : (current.status.isElevated ? .orange : .pink))
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

    // MARK: Trend

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Last 24 hours", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                if let d = current.status.trendUpdatedAt {
                    Text("Updated \(d, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            trendChart
                .frame(height: 150)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var trendChart: some View {
        let trend = current.status.trendHourlyBPM
        let baseHour = Calendar.current.date(byAdding: .hour, value: -(trend.count - 1), to: Date()) ?? Date()
        let points: [(Date, Int)] = trend.enumerated().map { idx, v in
            (Calendar.current.date(byAdding: .hour, value: idx, to: baseHour) ?? baseHour, v)
        }
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, pair in
                if pair.1 > 0 {
                    LineMark(
                        x: .value("Hour", pair.0),
                        y: .value("BPM", pair.1)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.pink)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))

                    AreaMark(
                        x: .value("Hour", pair.0),
                        y: .value("BPM", pair.1)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(
                        colors: [.pink.opacity(0.35), .pink.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    ))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(.gray.opacity(0.3))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d, format: .dateTime.hour())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
                    Text("Alerts fire even when MyHeart is closed, via silent CloudKit push and a background refresh every ~15 min.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: Emergency contact

    @ViewBuilder
    private var emergencyContactCard: some View {
        if profile.hasEmergencyContact {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Emergency Contact", systemImage: "phone.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Spacer()
                }
                Button {
                    callEmergencyContact()
                } label: {
                    HStack {
                        Image(systemName: "phone.fill")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(profile.emergencyContactName.isEmpty ? "Call Emergency Contact" : profile.emergencyContactName)
                                .fontWeight(.semibold)
                            Text(profile.emergencyContact)
                                .font(.caption2)
                                .opacity(0.9)
                        }
                        Spacer()
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.red))
                    .foregroundStyle(.white)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        }
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

    // MARK: Actions

    private func callEmergencyContact() {
        let digits = profile.emergencyContact.filter { "+0123456789".contains($0) }
        guard !digits.isEmpty,
              let url = URL(string: "tel://\(digits)"),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Refresh

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { await refreshNow() }
        }
        Task { await refreshNow() }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshNow() async {
        if let updated = await sharing.refreshFollowed(person: current) {
            withAnimation { current = updated }
        }
    }
}
