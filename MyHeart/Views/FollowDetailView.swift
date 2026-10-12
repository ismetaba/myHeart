import SwiftUI
import Charts
import UserNotifications

/// Detail for one followed person. Auto-refreshes while visible so the live
/// BPM stays current, aligned with the sharer's 30s publish cadence.
struct FollowDetailView: View {
    @EnvironmentObject private var sharing: LiveSharingService
    @Environment(\.dismiss) private var dismiss
    @State private var current: FollowedPerson
    @State private var showUnfollowConfirm = false
    @AppStorage private var alertThreshold: Int
    @AppStorage private var alertsEnabled: Bool

    init(person: FollowedPerson) {
        self._current = State(initialValue: person)
        self._alertThreshold = AppStorage(
            wrappedValue: FollowAlertSettings.defaultThreshold,
            FollowAlertSettings.thresholdKey(person.id)
        )
        self._alertsEnabled = AppStorage(
            wrappedValue: true,
            FollowAlertSettings.enabledKey(person.id)
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if current.status.isEmergency { emergencyBanner }
                heroCard
                statsRow
                if current.status.trendHourlyBPM.contains(where: { $0 > 0 }) { trendCard }
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
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog(
            "Stop following \(current.status.displayName)?",
            isPresented: $showUnfollowConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop Following", role: .destructive) {
                Task {
                    if await sharing.unfollow(current) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        // Polls while visible; SwiftUI cancels the task when the view goes away.
        .task {
            while !Task.isCancelled {
                await refreshNow()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
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
                    if current.status.isStale {
                        Text("No new readings for \(current.status.updatedAt, style: .relative) — this may be outdated.")
                            .font(.caption2)
                            .opacity(0.9)
                    }
                }
                Spacer()
            }
            if current.status.hasEmergencyContact {
                Button {
                    callEmergencyContact()
                } label: {
                    HStack {
                        Image(systemName: "phone.fill")
                        Text("Call \(contactDisplayName)")
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
        .background(RoundedRectangle(cornerRadius: 16).fill(current.status.isStale ? Color.red.opacity(0.7) : Color.red))
        .foregroundStyle(.white)
    }

    private var contactDisplayName: String {
        let name = current.status.emergencyContactName ?? ""
        return name.isEmpty ? (current.status.emergencyContactPhone ?? "") : name
    }

    // MARK: Hero

    private var heroCard: some View {
        VStack(spacing: 12) {
            HStack {
                let liveColor: Color = current.status.isStale ? .orange : .green
                Circle()
                    .fill(liveColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(liveColor.opacity(0.35), lineWidth: 4).scaleEffect(1.6))
                Text(current.status.isStale ? "Not live" : "Live")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(liveColor)
                Spacer()
                if current.status.hasReading {
                    Text("Measured \(current.status.updatedAt, style: .relative) ago")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(current.status.hasReading ? "\(current.status.currentBPM)" : "—")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(current.status.isEmergency ? Color.red : (current.status.isElevated ? Color.orange : Color.pink))
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
                    Text(current.status.hasReading
                         ? "No new reading for over \(Int(LiveHeartStatus.staleAfter / 60)) minutes"
                         : "No heart-rate reading shared yet")
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

    /// Hourly averages, oldest → newest. The last value is the hour the
    /// sharer's phone computed the trend in (`trendUpdatedAt`), not "now" —
    /// otherwise an old trend would be drawn against the wrong hours.
    private var trendPoints: [(date: Date, bpm: Double)] {
        let trend = current.status.trendHourlyBPM
        let cal = Calendar.current
        let reference = current.status.trendUpdatedAt ?? current.status.updatedAt
        let lastHour = cal.dateInterval(of: .hour, for: reference)?.start ?? reference
        let firstHour = cal.date(byAdding: .hour, value: -(trend.count - 1), to: lastHour) ?? lastHour
        return trend.enumerated().compactMap { idx, value in
            guard value > 0, let date = cal.date(byAdding: .hour, value: idx, to: firstHour) else { return nil }
            // Plot in the middle of the hour the average belongs to.
            return (date: date.addingTimeInterval(30 * 60), bpm: Double(value))
        }
    }

    private var trendChart: some View {
        let points = trendPoints
        let values = points.map { $0.bpm }
        let lo = (values.min() ?? 50) - 8
        let hi = (values.max() ?? 120) + 8
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                AreaMark(
                    x: .value("Hour", point.date),
                    yStart: .value("Base", lo),
                    yEnd: .value("BPM", point.bpm)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(
                    colors: [.pink.opacity(0.35), .pink.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                ))

                LineMark(
                    x: .value("Hour", point.date),
                    y: .value("BPM", point.bpm)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.pink)
                .lineStyle(StrokeStyle(lineWidth: 1.8))

                if points.count < 3 {
                    PointMark(
                        x: .value("Hour", point.date),
                        y: .value("BPM", point.bpm)
                    )
                    .foregroundStyle(.pink)
                }
            }
        }
        .chartYScale(domain: max(0, lo)...max(lo + 10, hi))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(.gray.opacity(0.3))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))").font(.caption2).foregroundStyle(.secondary)
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

            Toggle(isOn: $alertsEnabled) {
                Text("High heart-rate alerts")
                    .font(.subheadline.weight(.medium))
            }
            if alertsEnabled {
                Stepper(value: $alertThreshold, in: 60...200, step: 5) {
                    Text("Notify me if BPM ≥ \(alertThreshold)")
                        .font(.subheadline)
                }
            }
            Text("Emergency alerts are always on. Alerts also arrive when MyHeart is closed (via iCloud push and background refresh), though iOS may delay them.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: Emergency contact

    @ViewBuilder
    private var emergencyContactCard: some View {
        if current.status.hasEmergencyContact {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("\(current.status.displayName)'s Emergency Contact", systemImage: "phone.fill")
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
                            Text(contactDisplayName)
                                .fontWeight(.semibold)
                            if let name = current.status.emergencyContactName, !name.isEmpty {
                                Text(current.status.emergencyContactPhone ?? "")
                                    .font(.caption2)
                                    .opacity(0.9)
                            }
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
            metaRow("Checked", value: current.lastFetchedAt.formatted(date: .omitted, time: .shortened))
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
        let raw = current.status.emergencyContactPhone ?? ""
        let digits = raw.filter { "+0123456789".contains($0) }
        guard !digits.isEmpty, let url = URL(string: "tel:\(digits)") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Refresh

    private func refreshNow() async {
        if let updated = await sharing.refreshFollowed(person: current) {
            withAnimation { current = updated }
            await sharing.evaluateAlerts()
        }
    }
}
