import SwiftUI
import Charts
import UserNotifications
import UIKit

/// Detail for one followed person. Auto-refreshes while visible so the live
/// BPM stays current, aligned with the sharer's 30s publish cadence.
struct FollowDetailView: View {
    @EnvironmentObject private var sharing: LiveSharingService
    @EnvironmentObject private var notifications: NotificationPermission
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var current: FollowedPerson
    @State private var showUnfollowConfirm = false
    @State private var isUnfollowing = false
    @State private var unfollowError: String?
    /// The last refresh failed (usually this phone is offline), so what's on
    /// screen is from `current.lastFetchedAt` — not the sharer's fault.
    @State private var refreshFailed = false
    /// The sharer stopped sharing while this screen was open.
    @State private var isRemoved = false
    @AppStorage private var alertThreshold: Int
    @AppStorage private var alertsEnabled: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 96

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

    private var name: String { current.status.displayName }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isRemoved {
                    removedState
                } else {
                    if sharing.justFollowedID == current.id { followConfirmation }
                    if refreshFailed { offlineStrip }
                    if current.status.isEmergency { emergencyBanner }
                    heroCard
                    statsRow
                    if trendRange != nil { trendCard }
                    alertsCard
                    emergencyContactCard
                    metaCard
                }
            }
            .padding()
            .readableContentWidth()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isUnfollowing {
                    ProgressView()
                } else if !isRemoved {
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
        }
        .confirmationDialog(
            "Stop following \(name)?",
            isPresented: $showUnfollowConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop Following", role: .destructive) {
                Task { await unfollow() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stop seeing \(name)'s heart rate and won't get alerts. To follow again, you'll need a new invite link from \(name).")
        }
        .alert(
            "Couldn't stop following",
            isPresented: Binding(
                get: { unfollowError != nil },
                set: { if !$0 { unfollowError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(unfollowError ?? "")
        }
        // Polls while visible; SwiftUI cancels the task when the view goes away.
        .task {
            while !Task.isCancelled && !isRemoved {
                await refreshNow()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
        .refreshable { await refreshNow() }
        // The confirmation has been seen once the user leaves this screen.
        .onDisappear {
            if sharing.justFollowedID == current.id { sharing.justFollowedID = nil }
        }
    }

    // MARK: Status strips

    private var followConfirmation: some View {
        InlineBanner(
            message: notifications.isDenied
                ? "You're now following \(name). Turn on notifications to be alerted if their heart rate is very high or low."
                : "You're now following \(name). You'll get an alert if their heart rate is very high or low.",
            systemImage: "checkmark.circle.fill",
            tint: .green,
            onDismiss: { sharing.justFollowedID = nil }
        )
    }

    private var offlineStrip: some View {
        InlineBanner(
            message: "Can't refresh right now. Showing what was received at \(current.lastFetchedAt.formatted(date: .omitted, time: .shortened)).",
            systemImage: "icloud.slash",
            tint: .gray
        )
    }

    private var removedState: some View {
        EmptyStateView(
            systemImage: "person.crop.circle.badge.xmark",
            title: "\(name) is no longer sharing",
            message: "\(name) stopped sharing their heart rate, or their invite link was turned off. To follow again, ask \(name) for a new invite link."
        ) {
            Button("Back to Family") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .cardBackground()
    }

    // MARK: Emergency banner

    private var emergencyBanner: some View {
        let status = current.status
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status.isStale
                      ? "clock.arrow.circlepath"
                      : (status.emergencyKind?.systemImage ?? "exclamationmark.triangle.fill"))
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.emergencyKind?.label ?? "Emergency")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let since = status.emergencySince {
                        ReadingTimeText(date: since, prefix: "Since")
                            .font(.footnote)
                    }
                    if status.isStale {
                        ReadingTimeText(date: status.updatedAt, prefix: "Last reading", suffix: ". This may be outdated.")
                            .font(.footnote)
                    }
                }
                Spacer(minLength: 0)
            }
            if status.hasEmergencyContact {
                Button {
                    callEmergencyContact()
                } label: {
                    Label("Call \(contactDisplayName)", systemImage: "phone.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FamilyStyle.emergencyFill)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .controlSize(.large)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        // One solid red whether live or stale: the text says when it's
        // outdated, and white text needs this shade to stay readable.
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FamilyStyle.emergencyFill))
        .foregroundStyle(.white)
    }

    private var contactDisplayName: String {
        let name = current.status.emergencyContactName ?? ""
        return name.isEmpty ? (current.status.emergencyContactPhone ?? "") : name
    }

    // MARK: Hero

    private var heroCard: some View {
        let status = current.status
        return VStack(spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    let liveColor: Color = status.isStale ? .orange : .green
                    Circle()
                        .fill(liveColor)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(liveColor.opacity(0.35), lineWidth: 4).scaleEffect(1.6))
                        .accessibilityHidden(true)
                    Text(status.isStale ? "Not updating" : "Live")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.isStale ? FamilyStyle.warningText : FamilyStyle.liveText)
                }
                Spacer()
                if status.hasReading {
                    ReadingTimeText(date: status.updatedAt, prefix: "Measured")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(status.hasReading ? "\(status.currentBPM)" : "—")
                        .font(.system(size: min(heroSize, 96 * 1.6), weight: .bold, design: .rounded))
                        .foregroundStyle(status.isEmergency ? FamilyStyle.emergencyText : (status.isElevated ? FamilyStyle.warningText : Color.pink))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText())
                    Text("BPM")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if status.hasReading {
                    statusLine
                    if !(isPlainResting) {
                        ZoneChip(zone: status.zone)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(heroAccessibilityLabel)

            if status.isStale {
                staleExplanation
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .cardBackground()
    }

    /// Resting with nothing unusual: the status line already says "Resting",
    /// so a "Resting" zone chip would just repeat it.
    private var isPlainResting: Bool {
        let status = current.status
        return status.zone == .resting && !status.isEmergency && !status.isElevated
    }

    /// Plain-language state under the number; the fitness zone is secondary.
    @ViewBuilder
    private var statusLine: some View {
        let status = current.status
        Group {
            if status.isEmergency {
                Label("Emergency", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(FamilyStyle.emergencyText)
            } else if status.isElevated {
                Label("Above \(name)'s usual limit (\(status.elevatedThreshold) bpm)", systemImage: "arrow.up.heart.fill")
                    .foregroundStyle(FamilyStyle.warningText)
            } else {
                Text(status.zone == .resting ? "Resting" : "Active")
                    .foregroundStyle(.primary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .multilineTextAlignment(.center)
    }

    private var staleExplanation: some View {
        VStack(spacing: 6) {
            Label {
                if current.status.hasReading {
                    ReadingTimeText(date: current.status.updatedAt, prefix: "No new reading since")
                } else {
                    Text("No reading shared yet")
                }
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(FamilyStyle.warningText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.orange.opacity(0.15)))

            Text(current.status.hasReading
                 ? "\(name)'s Apple Watch may be off or charging, or their iPhone may be offline."
                 : "Waiting for \(name)'s first reading. It appears after their Apple Watch syncs with their iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var heroAccessibilityLabel: String {
        let status = current.status
        guard status.hasReading else { return "No reading yet" }
        var text = "\(status.currentBPM) beats per minute, \(status.zone.label) zone"
        if status.isEmergency {
            text += ", emergency"
        } else if status.isElevated {
            text += ", above \(name)'s usual limit of \(status.elevatedThreshold)"
        }
        if status.isStale { text += ", not updating" }
        return text
    }

    // MARK: Stats

    private var statsRow: some View {
        let status = current.status
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            statTile(
                title: "Resting", spokenTitle: "Resting heart rate",
                value: status.restingBPM.map { "\($0)" } ?? "—",
                unit: "bpm", spokenUnit: "beats per minute", icon: "bed.double.fill"
            )
            statTile(
                title: "HRV", spokenTitle: "Heart rate variability",
                value: status.hrvMs.map { String(format: "%.0f", $0) } ?? "—",
                unit: "ms", spokenUnit: "milliseconds", icon: "waveform.path.ecg"
            )
            if let range = trendRange {
                statTile(
                    title: "24h range", spokenTitle: "Range of hourly averages, last 24 hours",
                    value: "\(range.lowerBound)–\(range.upperBound)",
                    spokenValue: "\(range.lowerBound) to \(range.upperBound)",
                    unit: "bpm", spokenUnit: "beats per minute", icon: "arrow.up.and.down"
                )
            }
        }
    }

    private func statTile(
        title: String,
        spokenTitle: String,
        value: String,
        spokenValue: String? = nil,
        unit: String,
        spokenUnit: String,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon).foregroundStyle(.pink)
            }
            .font(.caption2.weight(.medium))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .cardBackground(cornerRadius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTitle)
        .accessibilityValue(value == "—" ? "No data" : "\(spokenValue ?? value) \(spokenUnit)")
    }

    /// Lowest and highest hourly average in the shared trend (gaps skipped).
    private var trendRange: ClosedRange<Int>? {
        let values = current.status.trendHourlyBPM.filter { $0 > 0 }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return lo...hi
    }

    // MARK: Trend

    private var trendCard: some View {
        FamilySectionCard(
            title: "Last 24 hours",
            icon: "chart.xyaxis.line",
            trailing: {
                if let updated = current.status.trendUpdatedAt {
                    ReadingTimeText(date: updated, prefix: "Updated", showsClockTime: false)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            },
            content: {
                trendChart
                    .frame(height: 150)
            }
        )
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
        let dataMin = values.min() ?? 50
        let dataMax = values.max() ?? 120
        let threshold = Double(alertThreshold)
        // Only draw the alert line when it's near the data; a far-away line
        // would squash the curve into a flat strip.
        let showsAlertLine = alertsEnabled && threshold >= dataMin - 40 && threshold <= dataMax + 40
        let lo = (showsAlertLine ? min(dataMin, threshold) : dataMin) - 8
        let hi = (showsAlertLine ? max(dataMax, threshold) : dataMax) + 8
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

            if showsAlertLine {
                RuleMark(y: .value("Alert", threshold))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Alert \(alertThreshold)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
        // One summary instead of ~50 unlabeled marks.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate, last 24 hours")
        .accessibilityValue(trendAccessibilityValue(points: points))
    }

    private func trendAccessibilityValue(points: [(date: Date, bpm: Double)]) -> String {
        let values = points.map { Int($0.bpm.rounded()) }
        guard let lo = values.min(), let hi = values.max(), let last = values.last else { return "No data" }
        return "Hourly averages from \(lo) to \(hi) beats per minute. Most recent hour: \(last)."
    }

    // MARK: Alerts

    private var alertsCard: some View {
        FamilySectionCard(title: "Alerts", icon: "bell.badge.fill") {
            notificationPermissionRow

            Toggle(isOn: $alertsEnabled) {
                Text("High heart-rate alerts")
                    .font(.subheadline.weight(.medium))
            }
            if alertsEnabled {
                Stepper(value: $alertThreshold, in: 60...200, step: 5) {
                    Text("Alert me at \(alertThreshold) bpm or higher")
                        .font(.subheadline)
                }
            }
            if let resting = current.status.restingBPM {
                Text("\(name)'s resting rate: \(resting) bpm · usual limit: \(current.status.elevatedThreshold) bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Promising alerts only makes sense when iOS will deliver them.
            if notifications.isAllowed {
                Text("Emergency alerts (very high, very low, or high for 10+ minutes) are always sent. iOS may delay alerts by a few minutes when MyHeart is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var notificationPermissionRow: some View {
        switch notifications.status {
        case .denied:
            InlineBanner(
                message: "Notifications are off for MyHeart, so you won't be alerted about \(name), even in an emergency.",
                systemImage: "bell.slash.fill",
                actionTitle: "Turn On in Settings",
                action: { notifications.openSystemSettings() }
            )
        case .notDetermined:
            InlineBanner(
                message: "Allow notifications so MyHeart can alert you if \(name) needs attention.",
                systemImage: "bell.badge.fill",
                tint: .pink,
                actionTitle: "Allow Alerts",
                action: { Task { await notifications.requestIfNeeded() } }
            )
        default:
            if notifications.timeSensitiveDisabled {
                InlineBanner(
                    message: "Time Sensitive notifications are off for MyHeart, so a Focus may silence emergency alerts.",
                    systemImage: "moon.fill",
                    actionTitle: "Open Settings",
                    action: { notifications.openSystemSettings() }
                )
            }
        }
    }

    // MARK: Emergency contact

    @ViewBuilder
    private var emergencyContactCard: some View {
        if current.status.hasEmergencyContact {
            FamilySectionCard(title: "\(name)'s Emergency Contact", icon: "phone.fill") {
                Button {
                    callEmergencyContact()
                } label: {
                    HStack {
                        Image(systemName: "phone.fill")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(contactDisplayName)
                                .fontWeight(.semibold)
                            if let contactName = current.status.emergencyContactName, !contactName.isEmpty {
                                Text(current.status.emergencyContactPhone ?? "")
                                    .font(.caption)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(FamilyStyle.emergencyFill)
                .controlSize(.large)
                .accessibilityLabel("Call \(contactDisplayName)")
            }
        }
    }

    // MARK: Meta

    private var metaCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            metaRow("Measured by", value: current.status.deviceName ?? "Unknown device")
            metaRow("Current zone range", value: zoneRangeText)
            metaRow("Usual limit", value: "\(current.status.elevatedThreshold) bpm")
            metaRow("Estimated max heart rate", value: "\(current.status.maxHR) bpm")
            metaRow("Last checked", value: current.lastFetchedAt.formatted(date: .omitted, time: .shortened))
        }
        .font(.caption)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var zoneRangeText: String {
        let range = current.status.zone.range(maxHR: Double(current.status.maxHR))
        if current.status.zone == .peak { return "\(range.lowerBound)+ bpm" }
        return "\(range.lowerBound) – \(range.upperBound) bpm"
    }

    @ViewBuilder
    private func metaRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func callEmergencyContact() {
        let raw = current.status.emergencyContactPhone ?? ""
        let digits = raw.filter { "+0123456789".contains($0) }
        guard !digits.isEmpty, let url = URL(string: "tel:\(digits)") else { return }
        UIApplication.shared.open(url)
    }

    private func unfollow() async {
        isUnfollowing = true
        let succeeded = await sharing.unfollow(current)
        isUnfollowing = false
        if succeeded {
            Haptics.success()
            dismiss()
        } else {
            Haptics.error()
            unfollowError = sharing.followError?.friendlyMessage ?? "Please try again."
            // Shown here; don't repeat it on the Family list afterwards.
            sharing.followError = nil
        }
    }

    // MARK: Refresh

    private func refreshNow() async {
        let result = await sharing.refreshFollowed(person: current)
        switch result {
        case .updated(let updated):
            let wasEmergency = current.status.isEmergency
            withAnimation { current = updated }
            refreshFailed = false
            if !wasEmergency && updated.status.isEmergency {
                announceEmergency(updated.status)
            }
            await sharing.evaluateAlerts()
        case .removed:
            withAnimation { isRemoved = true }
        case .failed:
            refreshFailed = true
        }
    }

    /// The red banner appearing is easy to miss, especially with VoiceOver.
    private func announceEmergency(_ status: LiveHeartStatus) {
        Haptics.warning()
        let kind = status.emergencyKind?.label ?? "Emergency"
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(status.displayName): \(kind), \(status.currentBPM) beats per minute"
        )
    }
}

// MARK: - Shared Family pieces

/// Status colors for the Family screens. White text on `emergencyFill` stays
/// above 4.5:1, and the text colors are darker in Light Mode so small labels
/// stay readable on white cards (the system orange/green are ~2:1 there).
enum FamilyStyle {
    static let emergencyFill = Color(red: 0.78, green: 0.11, blue: 0.11)
    static let emergencyText = adaptive(light: UIColor(red: 0.70, green: 0.09, blue: 0.09, alpha: 1), dark: .systemRed)
    static let warningText = adaptive(light: UIColor(red: 0.62, green: 0.34, blue: 0.00, alpha: 1), dark: .systemOrange)
    static let liveText = adaptive(light: UIColor(red: 0.11, green: 0.49, blue: 0.22, alpha: 1), dark: .systemGreen)

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

/// A reading's time as "14:05 · 12 min ago", refreshed once a minute rather
/// than ticking every second like `Text(_:style: .relative)`. The relative
/// part comes from `RelativeDateTimeFormatter`, so it localizes as a whole
/// instead of gluing on an English " ago".
struct ReadingTimeText: View {
    let date: Date
    var prefix: String? = nil
    var suffix: String? = nil
    /// Include the clock time; off where only the age matters.
    var showsClockTime = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(label(now: context.date))
        }
    }

    private func label(now: Date) -> String {
        let relative = Self.relative(date, now: now, formatter: Self.shortFormatter)
        var text = showsClockTime ? "\(Self.clockFormatter.string(from: date)) · \(relative)" : relative
        if let prefix {
            text = "\(prefix) \(text)"
        } else {
            text = text.prefix(1).uppercased() + text.dropFirst()
        }
        if let suffix { text += suffix }
        return text
    }

    /// Spelled-out age for VoiceOver labels, e.g. "3 minutes ago".
    static func spokenRelative(_ date: Date, now: Date = Date()) -> String {
        relative(date, now: now, formatter: fullFormatter)
    }

    private static func relative(_ date: Date, now: Date, formatter: RelativeDateTimeFormatter) -> String {
        // Clamp so a sharer's clock running ahead can't produce "in 2 min".
        let clamped = min(date, now)
        if now.timeIntervalSince(clamped) < 60 { return "just now" }
        return formatter.localizedString(for: clamped, relativeTo: now)
    }

    // Formatters are expensive to create, and rows render often.
    private static let shortFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let fullFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
