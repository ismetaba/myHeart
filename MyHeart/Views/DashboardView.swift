import SwiftUI
import Charts

/// The Heart tab. Doesn't own a NavigationStack: it's embedded in one by
/// `ContentView` and also pushed from the Health tab.
struct DashboardView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @EnvironmentObject private var profile: UserProfile
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 72
    @State private var exportedFile: ExportedFile?
    @State private var exportError: String?
    @State private var isExporting = false

    private struct ExportedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.healthUnavailable {
                    healthUnavailableCard
                        .padding(.horizontal)
                } else {
                    modePicker
                        .padding(.horizontal)

                    if let message = viewModel.errorMessage {
                        InlineBanner(
                            message: message,
                            actionTitle: "Try Again",
                            action: { Task { await viewModel.refresh() } },
                            onDismiss: { viewModel.errorMessage = nil }
                        )
                        .padding(.horizontal)
                    }

                    if viewModel.mode == .overall {
                        overallSection
                    } else {
                        dailySection
                    }
                }
            }
            .padding(.vertical)
            .readableContentWidth()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Heart")
        .toolbar { toolbar }
        .refreshable {
            guard !viewModel.healthUnavailable else { return }
            await viewModel.refresh()
        }
        .sheet(item: $exportedFile) { file in
            ShareSheet(activityItems: [file.url])
                .presentationDetents([.medium, .large])
                // Avoids a blank band under the activity sheet at the medium detent.
                .ignoresSafeArea()
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(exportError ?? "") }
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Trailing, so it never sits next to the back button when this
        // screen is pushed from the Health tab.
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !viewModel.healthUnavailable {
                Button {
                    Task {
                        await viewModel.refresh()
                        // Success is visible on screen; only a failure needs a cue.
                        if viewModel.errorMessage != nil { Haptics.error() }
                    }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isLoading)
                .accessibilityLabel("Refresh")

                Button {
                    Task { await export() }
                } label: {
                    if isExporting {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(exportDisabled)
                .accessibilityLabel("Export PDF report")
            }
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { viewModel.mode },
            set: { new in
                Haptics.selection()
                Task { await viewModel.setMode(new) }
            }
        )) {
            ForEach(HeartRateViewModel.ReportMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
    }

    /// iPad on iPadOS 16 has no Apple Health; following family still works.
    private var healthUnavailableCard: some View {
        EmptyStateView(
            systemImage: "heart.slash",
            title: "Health data isn't available on this device",
            message: "You can still follow family members' live heart rate on the Family tab."
        ) {
            Button("Open Family") { router.openFamily() }
                .buttonStyle(.borderedProminent)
        }
        .cardBackground()
    }

    // MARK: - Overall section

    private var overallSection: some View {
        let pending = viewModel.isFirstLoadPending
        let switching = viewModel.isSwitchingRange
        // The chart sits right under the range picker, so changing the range
        // visibly changes what's below it. The hero is range-independent.
        return VStack(spacing: 16) {
            heroCard
                .redacted(reason: pending ? .placeholder : [])
            overallRangePicker
            overallChartCard
            keyStatsSection
                .redacted(reason: pending ? .placeholder : [])
                .opacity(switching ? 0.4 : 1)
            zoneCard
                .redacted(reason: pending ? .placeholder : [])
                .opacity(switching ? 0.4 : 1)
            if !viewModel.insights.isEmpty {
                insightsCard
                    .opacity(switching ? 0.4 : 1)
            }
            if viewModel.sourceBreakdown.count > 1 {
                sourcesRow
            }
            // Without data the chart card already explains why; a disabled
            // button underneath would only repeat it.
            if !viewModel.samples.isEmpty {
                overallExportSection
            }
            lastRefreshFooter
        }
        .padding(.horizontal)
    }

    private var overallRangePicker: some View {
        Picker("Range", selection: Binding(
            get: { viewModel.selectedRange },
            set: { new in
                Haptics.selection()
                Task { await viewModel.setOverallRange(new) }
            }
        )) {
            ForEach(HeartRateViewModel.OverallRange.allCases) { r in
                Text(r.rawValue).tag(r)
            }
        }
        .pickerStyle(.segmented)
    }

    private var heroCard: some View {
        // Ticks once a minute: keeps "5 minutes ago" and the stale state
        // current without the per-second churn of `Text(date, style: .relative)`.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            heroContent(now: context.date)
        }
    }

    @ViewBuilder
    private func heroContent(now: Date) -> some View {
        let latest = viewModel.summary.latest
        // An hour-old reading isn't "your heart rate" any more; don't present
        // it in the same bright style as a live one.
        let isStale = latest.map { now.timeIntervalSince($0.date) > 3600 } ?? false
        let title: String = isStale ? "Last Reading" : "Heart Rate"
        let spokenTitle: String = isStale ? "Last heart rate reading" : "Latest heart rate"

        VStack(spacing: 8) {
            HStack {
                Label(title, systemImage: "heart.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.pink)
                Spacer()
                if let latest {
                    Text(readingTime(latest.date, isStale: isStale, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(latest.map { String(Int($0.bpm.rounded())) } ?? "—")
                    // Capped so the number doesn't crowd out the card at AX sizes.
                    .font(.system(size: min(heroSize, 115), weight: .bold, design: .rounded))
                    .foregroundStyle(isStale ? Color.secondary : Color.pink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: latest?.bpm)
                Text("BPM")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 10) {
                if let latest {
                    ZoneChip(zone: HeartRateZone(bpm: latest.bpm, maxHR: profile.maxHR))
                    Spacer()
                    Text(latest.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTitle)
        .accessibilityValue(heroAccessibilityValue(latest: latest, isStale: isStale, now: now))
    }

    private func readingTime(_ date: Date, isStale: Bool, now: Date) -> String {
        isStale
            ? DashboardText.absoluteTime(date, now: now)
            : DashboardText.relativeTime(date, now: now)
    }

    private func heroAccessibilityValue(latest: HeartRateSample?, isStale: Bool, now: Date) -> String {
        guard let latest else { return "No heart rate data" }
        let zone = HeartRateZone(bpm: latest.bpm, maxHR: profile.maxHR)
        let when = readingTime(latest.date, isStale: isStale, now: now)
        return "\(DashboardText.spokenBPM(latest.bpm)), \(zone.label) zone, \(when), from \(latest.source)"
    }

    /// Three tiles side by side normally, stacked at accessibility text sizes
    /// where three ~80 pt columns would truncate every label and value.
    private var tileLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    private var keyStatsSection: some View {
        let previous = viewModel.loadedRange.previousTitle
        return VStack(alignment: .leading, spacing: 6) {
            // Said once for the row; inside each tile it truncated to "vs prev…".
            Text("Compared with the \(previous)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            tileLayout {
                DeltaStatTile(
                    title: "Resting",
                    accessibilityTitle: "Resting heart rate",
                    icon: "bed.double.fill",
                    value: viewModel.summary.restingBPM,
                    unit: "bpm",
                    delta: viewModel.restingDelta,
                    deltaRangeLabel: previous,
                    tint: .pink
                )
                DeltaStatTile(
                    title: "Average",
                    accessibilityTitle: "Average heart rate",
                    icon: "waveform.path.ecg",
                    value: viewModel.summary.averageBPM,
                    unit: "bpm",
                    delta: viewModel.averageDelta,
                    deltaRangeLabel: previous,
                    tint: .pink
                )
                DeltaStatTile(
                    title: "HRV",
                    accessibilityTitle: "Heart rate variability",
                    icon: "heart.text.square",
                    value: viewModel.summary.hrvSDNN,
                    unit: "ms",
                    delta: viewModel.hrvDelta,
                    deltaRangeLabel: previous,
                    tint: .purple
                )
            }
        }
    }

    private var zoneCard: some View {
        CardContainer(title: "Time in Zones", subtitle: zoneCardSubtitle) {
            ZoneBar(breakdown: viewModel.zoneBreakdown)
                .frame(height: 18)
                .padding(.bottom, 4)

            VStack(spacing: 8) {
                ForEach(HeartRateZone.allCases) { zone in
                    ZoneRow(
                        zone: zone,
                        duration: viewModel.zoneBreakdown.duration(zone),
                        fraction: viewModel.zoneBreakdown.fraction(zone),
                        bpmRange: zone.range(maxHR: profile.maxHR)
                    )
                }
            }

            Text(zoneBasisNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var zoneCardSubtitle: String? {
        viewModel.zoneBreakdown.totalDuration > 0
            ? "Across \(DurationFormat.compact(viewModel.zoneBreakdown.totalDuration))"
            : nil
    }

    /// Most people never open Settings, where age silently defaults to 30,
    /// so say what the zone boundaries assume.
    private var zoneBasisNote: String {
        let maxHR = Int(profile.maxHR)
        if profile.isMaxHROverridden {
            return "Zones use your max heart rate of \(maxHR) bpm. Change it in Settings."
        }
        return "Zones use an estimated max heart rate of \(maxHR) bpm (220 − age \(profile.age)). Set your age in Settings."
    }

    private var insightsCard: some View {
        CardContainer(title: "Insights", subtitle: nil) {
            VStack(spacing: 10) {
                ForEach(viewModel.insights) { InsightRow(insight: $0) }
            }
        }
    }

    private var overallChartCard: some View {
        CardContainer(title: "Trend", subtitle: trendSubtitle) {
            if viewModel.samples.isEmpty {
                if viewModel.isLoading || viewModel.isFirstLoadPending {
                    chartLoadingState
                } else {
                    emptyChartState
                }
            } else {
                OverallChart(
                    samples: viewModel.samples,
                    buckets: viewModel.chartBuckets,
                    averageBPM: viewModel.summary.averageBPM,
                    range: viewModel.loadedRange
                )
                // The old range stays visible (dimmed) until the new one
                // arrives, so the axis labels always match the data.
                .opacity(viewModel.isSwitchingRange ? 0.4 : 1)
                .overlay {
                    if viewModel.isSwitchingRange {
                        ProgressView()
                    }
                }
            }
        }
    }

    /// Names the range of the data shown; while a switch loads with nothing
    /// to show yet, names the range being loaded.
    private var trendSubtitle: String {
        let range = viewModel.isSwitchingRange && viewModel.samples.isEmpty
            ? viewModel.selectedRange
            : viewModel.loadedRange
        return range.fullTitle
    }

    private var sourcesRow: some View {
        CardContainer(title: "Data sources", subtitle: nil) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.sourceBreakdown) { slice in
                        SourceChip(slice: slice)
                    }
                }
            }
        }
    }

    private var overallExportSection: some View {
        VStack(spacing: 6) {
            exportButton(prominent: false)
            Text("\(viewModel.loadedRange.fullTitle) · trend, zones and insights")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }

    private var lastRefreshFooter: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 2) {
                if let readings = readingCountText {
                    Text(readings)
                }
                if let last = viewModel.lastRefresh {
                    Text("Updated \(DashboardText.relativeTime(last, now: context.date))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
    }

    /// The sample count lives here rather than in a stat tile: it's context
    /// for the numbers above, not a health metric.
    private var readingCountText: String? {
        let count = viewModel.mode == .overall ? viewModel.summary.sampleCount : viewModel.dailySamples.count
        guard count > 0 else { return nil }
        return count == 1 ? "Based on 1 reading" : "Based on \(count.formatted()) readings"
    }

    // MARK: - Daily section

    @State private var localStart: Date = Date()
    @State private var localEnd: Date = Date()
    @State private var didInitDates = false
    /// Explains why the other date moved when a pick exceeded the maximum range.
    @State private var clampNote: String?

    private var dailySection: some View {
        VStack(spacing: 16) {
            dailyControls
            if !viewModel.hasDailyData {
                // `dailyStats` has an entry for every day even without samples,
                // so check for actual values before showing the cards.
                if viewModel.isLoading || viewModel.isFirstLoadPending {
                    chartLoadingState
                        .cardBackground()
                } else {
                    emptyChartState
                        .cardBackground()
                }
            } else {
                dailySummaryCard
                    .opacity(dailyDimming)
                if !viewModel.insights.isEmpty {
                    insightsCard
                        .opacity(dailyDimming)
                }
                dailyChartCard
                dailyListCard
                    .opacity(dailyDimming)
            }
            if viewModel.sourceBreakdown.count > 1 {
                sourcesRow
            }
            lastRefreshFooter
        }
        .padding(.horizontal)
    }

    /// Cards keep showing the previous range, dimmed, while a new one loads.
    private var dailyDimming: Double {
        viewModel.isSwitchingDailyRange ? 0.4 : 1
    }

    private var selectedDayCount: Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: localStart), to: cal.startOfDay(for: localEnd)).day ?? 0
        return max(0, days) + 1
    }

    private var dailyControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Daily Report", systemImage: "calendar")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(selectedDayCount) day\(selectedDayCount == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.pink.opacity(0.15)))
                    .foregroundStyle(.pink)
            }
            Text("Pick up to \(HeartRateViewModel.maxDailyRangeDays) days. Tap a day below for its 24-hour chart; the PDF includes one for each day.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                DatePicker("Start", selection: startBinding, in: ...localEnd, displayedComponents: .date)
                DatePicker("End", selection: endBinding, in: min(localStart, Date())...Date(), displayedComponents: .date)
            }

            if let clampNote {
                Label(clampNote, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    presetButtons
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 0) {
                    presetButtons
                }
            }

            exportButton(prominent: true)
            if let note = exportUnavailableNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .cardBackground()
        .onAppear {
            if !didInitDates {
                localStart = viewModel.dailyStart
                localEnd = viewModel.dailyEnd
                didInitDates = true
            }
        }
        // Apply as soon as the range changes. Observing both dates together
        // means a preset (or a clamp that moves the other date) triggers a
        // single reload.
        .onChange(of: [localStart, localEnd]) { _ in
            guard didInitDates else { return }
            Task { await applyLocalRange() }
        }
    }

    /// Picking a Start that makes the range too long moves End, not the
    /// date the user just picked (the view model would trim Start).
    private var startBinding: Binding<Date> {
        Binding(
            get: { localStart },
            set: { new in
                clampNote = nil
                localStart = new
                let cal = Calendar.current
                let today = cal.startOfDay(for: Date())
                guard let limit = cal.date(
                    byAdding: .day,
                    value: HeartRateViewModel.maxDailyRangeDays - 1,
                    to: cal.startOfDay(for: new)
                ) else { return }
                let maxEnd = min(limit, today)
                if cal.startOfDay(for: localEnd) > maxEnd {
                    localEnd = maxEnd
                    noteClamp(field: "End", movedTo: maxEnd)
                }
            }
        )
    }

    /// Mirror of `startBinding`: a far-off End pulls Start forward.
    private var endBinding: Binding<Date> {
        Binding(
            get: { localEnd },
            set: { new in
                clampNote = nil
                localEnd = new
                let cal = Calendar.current
                guard let minStart = cal.date(
                    byAdding: .day,
                    value: -(HeartRateViewModel.maxDailyRangeDays - 1),
                    to: cal.startOfDay(for: new)
                ) else { return }
                if cal.startOfDay(for: localStart) < minStart {
                    localStart = minStart
                    noteClamp(field: "Start", movedTo: minStart)
                }
            }
        )
    }

    private func noteClamp(field: String, movedTo date: Date) {
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        clampNote = "Reports cover up to \(HeartRateViewModel.maxDailyRangeDays) days, so \(field) moved to \(day)."
        Haptics.warning()
    }

    private func applyLocalRange() async {
        await viewModel.setDailyRange(start: localStart, end: localEnd)
        // Reflect clamping (max length, no future dates) back into the pickers.
        if localStart != viewModel.dailyStart { localStart = viewModel.dailyStart }
        if localEnd != viewModel.dailyEnd { localEnd = viewModel.dailyEnd }
    }

    @ViewBuilder
    private var presetButtons: some View {
        quickPreset("7 days", days: 6)
        quickPreset("14 days", days: 13)
        quickPreset("30 days", days: 29)
    }

    private func quickPreset(_ title: String, days: Int) -> some View {
        let cal = Calendar.current
        let isSelected = cal.isDateInToday(localEnd) && selectedDayCount == days + 1
        return Button {
            Haptics.selection()
            clampNote = nil
            let today = cal.startOfDay(for: Date())
            localEnd = today
            localStart = cal.date(byAdding: .day, value: -days, to: today) ?? today
        } label: {
            // Padding and capsule live inside the label so the whole capsule
            // (plus some margin, ~44 pt tall) is tappable, not just the text.
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(Capsule().fill(isSelected ? Color.pink : Color(.tertiarySystemFill)))
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var dailySummaryCard: some View {
        CardContainer(title: "Summary", subtitle: dailySummarySubtitle) {
            LazyVGrid(columns: summaryColumns, spacing: 10) {
                CompactMetricRow(label: "Daily average", value: DashboardText.whole(viewModel.dailyAverageOfAverages), unit: "bpm", icon: "waveform.path.ecg")
                CompactMetricRow(label: "Avg resting", value: DashboardText.whole(viewModel.dailyOverallResting), unit: "bpm", icon: "bed.double.fill")
                CompactMetricRow(label: "Lowest", value: DashboardText.whole(viewModel.dailyOverallMin), unit: "bpm", icon: "arrow.down.heart")
                CompactMetricRow(label: "Highest", value: DashboardText.whole(viewModel.dailyOverallMax), unit: "bpm", icon: "arrow.up.heart")
            }
        }
    }

    private var summaryColumns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var dailySummarySubtitle: String? {
        let total = viewModel.dailyStats.count
        let withData = viewModel.daysWithData
        guard withData < total else { return rangeSubtitle }
        return "\(withData) of \(total) days with data"
    }

    private var rangeSubtitle: String? {
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        // The range the cards show, which lags the pickers while loading.
        let start = viewModel.loadedDailyStart ?? viewModel.dailyStart
        let end = viewModel.loadedDailyEnd ?? viewModel.dailyEnd
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }

    private var dailyChartCard: some View {
        CardContainer(title: "Daily Range", subtitle: nil) {
            DailyChart(stats: viewModel.dailyStats)
                .opacity(dailyDimming)
                .overlay {
                    if viewModel.isSwitchingDailyRange {
                        ProgressView()
                    }
                }
        }
    }

    private var dailyListCard: some View {
        CardContainer(title: "Per-Day Breakdown", subtitle: nil) {
            VStack(spacing: 0) {
                ForEach(Array(viewModel.dailyStats.enumerated()), id: \.element.id) { index, day in
                    dailyListRow(day)
                    if index < viewModel.dailyStats.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dailyListRow(_ day: DailyHeartRateStats) -> some View {
        let breakdown = viewModel.dailyZones[day.day]
        if day.avgBPM != nil {
            NavigationLink {
                HeartDayDetailView(day: day)
            } label: {
                HStack(spacing: 0) {
                    DailyRow(day: day, breakdown: breakdown)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 14)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(DailyRow.spokenDay(day))
            .accessibilityValue(DailyRow.spokenSummary(day, breakdown: breakdown))
            .accessibilityHint("Shows the 24-hour chart")
        } else {
            DailyRow(day: day, breakdown: breakdown)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DailyRow.spokenDay(day))
                .accessibilityValue("No data")
        }
    }

    // MARK: - Shared helpers

    private var chartLoadingState: some View {
        ProgressView("Loading heart rate…")
            .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var emptyChartState: some View {
        EmptyStateView(
            systemImage: "waveform.path.ecg",
            title: "No heart rate data in this range",
            message: "Wear your Apple Watch, then pull down to refresh. Have heart rate data in Health but don't see it here? Check that MyHeart may read Heart Rate. \(HealthCopy.permissionPath)"
        )
    }

    /// Full-width export next to the content, so it's clear the report is a
    /// PDF and which data it covers. The toolbar icon stays as a shortcut.
    @ViewBuilder
    private func exportButton(prominent: Bool) -> some View {
        let button = Button {
            Task { await export() }
        } label: {
            HStack(spacing: 8) {
                if isExporting {
                    ProgressView()
                    Text("Preparing PDF…")
                } else {
                    Label("Export PDF Report", systemImage: "square.and.arrow.up")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(exportDisabled)

        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var hasExportableData: Bool {
        switch viewModel.mode {
        case .overall: return !viewModel.samples.isEmpty
        case .daily:   return viewModel.hasDailyData
        }
    }

    private var exportDisabled: Bool {
        viewModel.isLoading || isExporting || !hasExportableData
    }

    /// Why export is off, when it isn't just busy.
    private var exportUnavailableNote: String? {
        guard !viewModel.isLoading, !isExporting, !viewModel.isFirstLoadPending, !hasExportableData else { return nil }
        return "No heart rate data in this range to export."
    }

    /// Renders the PDF off the main thread (large ranges take a moment) and
    /// presents the share sheet.
    private func export() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }

        let mode = viewModel.mode
        let summary = viewModel.summary
        let previousSummary = viewModel.previousSummary
        let samples = viewModel.samples
        let zones = viewModel.zoneBreakdown
        let maxHR = profile.maxHR
        // The range the data was loaded for, not a selection still loading.
        let rangeTitle = viewModel.loadedRange.fullTitle
        let previousRangeLabel = viewModel.loadedRange.previousTitle
        let dailyStats = viewModel.dailyStats
        let dailySamples = viewModel.dailySamples
        let dailyZones = viewModel.dailyZones
        let dailyStart = viewModel.loadedDailyStart ?? viewModel.dailyStart
        let dailyEnd = viewModel.loadedDailyEnd ?? viewModel.dailyEnd

        do {
            let url = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                switch mode {
                case .overall:
                    return try PDFExporter.exportOverall(
                        summary: summary,
                        previousSummary: previousSummary,
                        samples: samples,
                        zones: zones,
                        maxHR: maxHR,
                        rangeTitle: rangeTitle,
                        previousRangeLabel: previousRangeLabel
                    )
                case .daily:
                    return try PDFExporter.exportDaily(
                        stats: dailyStats,
                        samples: dailySamples,
                        zonesByDay: dailyZones,
                        maxHR: maxHR,
                        start: dailyStart,
                        end: dailyEnd
                    )
                }
            }.value
            Haptics.success()
            exportedFile = ExportedFile(url: url)
        } catch {
            Haptics.error()
            exportError = error.localizedDescription
        }
    }
}

// MARK: - Text helpers

/// Formatting and VoiceOver wording shared by the dashboard's views.
private enum DashboardText {
    /// "5 minutes ago", or "just now" under a minute: the views refresh once
    /// a minute, so a seconds count would sit there frozen.
    static func relativeTime(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "Today 08:14", "Yesterday 22:10", "Tue 08:14", "Sep 30, 08:14".
    static func absoluteTime(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        if now.timeIntervalSince(date) < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func whole(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(Int(value.rounded()))
    }

    /// VoiceOver spells abbreviations letter by letter ("b p m").
    static func spokenUnit(_ unit: String) -> String {
        switch unit {
        case "bpm": return "beats per minute"
        case "ms":  return "milliseconds"
        default:    return unit
        }
    }

    static func spokenBPM(_ bpm: Double) -> String {
        "\(Int(bpm.rounded())) beats per minute"
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "less than a minute" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .full
        return formatter.string(from: seconds) ?? DurationFormat.compact(seconds)
    }
}

// MARK: - Private reusable subviews

private struct CardContainer<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

private struct DeltaStatTile: View {
    let title: String
    /// Spoken instead of the abbreviated visible title ("HRV").
    let accessibilityTitle: String
    let icon: String
    let value: Double?
    let unit: String
    let delta: TrendDelta
    /// Spoken only; the visible comparison basis is shown once above the row.
    let deltaRangeLabel: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(valueString)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                if !unit.isEmpty && value != nil {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            deltaRow
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(spokenValue)
    }

    private var deltaRow: some View {
        HStack(spacing: 3) {
            if let change = delta.absoluteChange {
                if abs(change) < 0.5 {
                    Text("No change")
                        .font(.caption2)
                } else {
                    // The arrow already carries the sign, so the number doesn't.
                    Image(systemName: delta.arrow)
                        .font(.caption2.weight(.bold))
                    Text("\(Int(abs(change).rounded())) \(unit)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                    // A word, not just green vs orange, says whether it's good.
                    if let good = delta.isImprovement {
                        Text(good ? "better" : "worse")
                            .font(.caption2)
                    }
                }
            } else {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(delta.tint)
    }

    private var valueString: String {
        guard let v = value else { return "—" }
        return String(Int(v.rounded()))
    }

    private var spokenValue: String {
        guard let value else { return "No data" }
        let unitName = DashboardText.spokenUnit(unit)
        return "\(Int(value.rounded())) \(unitName), \(spokenDelta(unitName: unitName))"
    }

    private func spokenDelta(unitName: String) -> String {
        guard let change = delta.absoluteChange else { return "no earlier data to compare" }
        guard abs(change) >= 0.5 else { return "no change from the \(deltaRangeLabel)" }
        let direction = change > 0 ? "up" : "down"
        var text = "\(direction) \(Int(abs(change).rounded())) \(unitName) from the \(deltaRangeLabel)"
        if let good = delta.isImprovement {
            text += good ? ", better" : ", worse"
        }
        return text
    }
}

private struct ZoneBar: View {
    let breakdown: ZoneBreakdown

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 2) {
                if breakdown.totalDuration <= 0 {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.tertiarySystemFill))
                        .overlay(
                            Text("No data")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        )
                } else {
                    let zones = HeartRateZone.allCases.filter { breakdown.fraction($0) > 0 }
                    let usable = max(0, w - 2 * CGFloat(max(zones.count - 1, 0)))
                    ForEach(zones) { zone in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(zone.color)
                            .frame(width: usable * CGFloat(breakdown.fraction(zone)))
                    }
                }
            }
        }
        // The zone rows below say the same thing in words.
        .accessibilityHidden(true)
    }
}

private struct ZoneRow: View {
    let zone: HeartRateZone
    let duration: TimeInterval
    let fraction: Double
    let bpmRange: ClosedRange<Int>
    @ScaledMetric(relativeTo: .caption) var percentWidth: CGFloat = 44

    var body: some View {
        // One line when it fits; at large text sizes the range and time move
        // to a second line instead of truncating.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                dot
                name
                rangeText
                Spacer(minLength: 8)
                durationText
                percentText
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    dot
                    name
                    Spacer(minLength: 8)
                    percentText
                }
                HStack(spacing: 10) {
                    rangeText
                    Spacer(minLength: 8)
                    durationText
                }
                .padding(.leading, 20)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(spokenValue)
    }

    private var dot: some View {
        Circle()
            .fill(zone.color)
            .frame(width: 10, height: 10)
    }

    private var name: some View {
        Text(zone.label)
            .font(.subheadline.weight(.medium))
    }

    private var rangeText: some View {
        Text(bpmText)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var durationText: some View {
        Text(DurationFormat.compact(duration))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var percentText: some View {
        Text("\(Int((fraction * 100).rounded()))%")
            .font(.caption.monospacedDigit().weight(.semibold))
            .frame(width: percentWidth, alignment: .trailing)
            .foregroundStyle(duration > 0 ? zone.textColor : Color.secondary)
    }

    private var bpmText: String {
        zone == .peak
            ? "\(bpmRange.lowerBound)+ bpm"
            : "\(bpmRange.lowerBound)–\(bpmRange.upperBound) bpm"
    }

    private var spokenLabel: String {
        zone == .peak
            ? "\(zone.label) zone, \(bpmRange.lowerBound) beats per minute and above"
            : "\(zone.label) zone, \(bpmRange.lowerBound) to \(bpmRange.upperBound) beats per minute"
    }

    private var spokenValue: String {
        guard duration > 0 else { return "No time in this zone" }
        return "\(DashboardText.spokenDuration(duration)), \(Int((fraction * 100).rounded())) percent"
    }
}

private struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(insight.tint.color.opacity(0.18))
                Image(systemName: insight.icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(insight.tint.color)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title)
                    .font(.subheadline.weight(.semibold))
                Text(insight.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SourceChip: View {
    let slice: SourceSlice

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: slice.name.localizedCaseInsensitiveContains("watch") ? "applewatch" : "iphone")
                .font(.caption2)
            Text(slice.name)
                .font(.caption.weight(.medium))
            Text("· \(Int((slice.fraction * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
}

private struct CompactMetricRow: View {
    let label: String
    let value: String
    let unit: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.pink)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: String {
        value == "—" ? "No data" : "\(value) \(DashboardText.spokenUnit(unit))"
    }
}

private struct DailyRow: View {
    let day: DailyHeartRateStats
    let breakdown: ZoneBreakdown?
    @ScaledMetric(relativeTo: .subheadline) var dateWidth: CGFloat = 48
    @Environment(\.dynamicTypeSize) var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    dateColumn
                    details
                }
            } else {
                HStack(spacing: 12) {
                    dateColumn
                        .frame(width: dateWidth, alignment: .leading)
                    details
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.day, format: .dateTime.weekday(.abbreviated))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(day.day, format: .dateTime.month(.abbreviated).day())
                .font(.subheadline.weight(.semibold))
        }
    }

    @ViewBuilder
    private var details: some View {
        if day.avgBPM == nil {
            // Days without samples still get a row; say so instead of "— — —".
            Text("No data")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        metric("min", value: day.minBPM)
                        metric("avg", value: day.avgBPM, highlight: true)
                        metric("max", value: day.maxBPM)
                        if let r = day.restingBPM {
                            metric("rest", value: r)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 14) {
                            metric("min", value: day.minBPM)
                            metric("avg", value: day.avgBPM, highlight: true)
                        }
                        HStack(spacing: 14) {
                            metric("max", value: day.maxBPM)
                            if let r = day.restingBPM {
                                metric("rest", value: r)
                            }
                        }
                    }
                }
                if let breakdown, breakdown.totalDuration > 0 {
                    ZoneStripMini(breakdown: breakdown)
                        .frame(height: 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func metric(_ label: String, value: Double?, highlight: Bool = false) -> some View {
        VStack(spacing: 0) {
            Text(value.map { String(Int($0.rounded())) } ?? "—")
                .font(.caption.monospacedDigit().weight(highlight ? .semibold : .regular))
                .foregroundStyle(highlight ? Color.pink : Color.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    static func spokenDay(_ day: DailyHeartRateStats) -> String {
        day.day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    static func spokenSummary(_ day: DailyHeartRateStats, breakdown: ZoneBreakdown?) -> String {
        guard let avg = day.avgBPM else { return "No data" }
        var parts = ["average \(Int(avg.rounded()))"]
        if let v = day.minBPM { parts.append("lowest \(Int(v.rounded()))") }
        if let v = day.maxBPM { parts.append("highest \(Int(v.rounded()))") }
        if let v = day.restingBPM { parts.append("resting \(Int(v.rounded()))") }
        var text = parts.joined(separator: ", ") + " beats per minute"
        if let breakdown, breakdown.totalDuration > 0, let zone = breakdown.dominantZone {
            text += ", mostly \(zone.label) zone"
        }
        return text
    }
}

private struct ZoneStripMini: View {
    let breakdown: ZoneBreakdown

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let zones = HeartRateZone.allCases.filter { breakdown.fraction($0) > 0 }
            let usable = max(0, w - CGFloat(max(zones.count - 1, 0)))
            HStack(spacing: 1) {
                ForEach(zones) { zone in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(zone.color)
                        .frame(width: usable * CGFloat(breakdown.fraction(zone)))
                }
            }
        }
        // The row's spoken summary names the dominant zone.
        .accessibilityHidden(true)
    }
}

// MARK: - Day detail

/// One day's 24-hour curve, pushed from the per-day list. Before, the only
/// way to see it was exporting the PDF.
private struct HeartDayDetailView: View {
    let day: DailyHeartRateStats
    @EnvironmentObject var viewModel: HeartRateViewModel
    @EnvironmentObject var profile: UserProfile
    @Environment(\.dynamicTypeSize) var typeSize

    var body: some View {
        let cal = Calendar.current
        let dayEnd = cal.date(byAdding: .day, value: 1, to: day.day) ?? day.day.addingTimeInterval(86_400)
        // Filtered here rather than in init: NavigationLink builds its
        // destination for every row up front, but body only runs once pushed.
        let daySamples = viewModel.dailySamples.filter { cal.isDate($0.date, inSameDayAs: day.day) }
        let buckets = daySamples.count > HeartRateViewModel.rawChartLimit
            ? HeartRateBucket.make(from: daySamples, start: day.day, end: dayEnd, maxBuckets: HeartRateViewModel.chartBucketCount)
            : []
        let zones = viewModel.dailyZones[day.day] ?? .empty

        ScrollView {
            VStack(spacing: 16) {
                summaryCard(readings: daySamples.count)

                CardContainer(title: "24-Hour Chart", subtitle: nil) {
                    if daySamples.isEmpty {
                        EmptyStateView(
                            systemImage: "waveform.path.ecg",
                            title: "No readings on this day",
                            message: "Pull down on the Heart tab to refresh."
                        )
                    } else {
                        OverallChart(
                            samples: daySamples,
                            buckets: buckets,
                            averageBPM: day.avgBPM,
                            range: .day1,
                            xDomain: day.day...dayEnd,
                            plotHeight: 260,
                            accessibilityTitle: "Heart rate on \(DailyRow.spokenDay(day))"
                        )
                    }
                }

                CardContainer(
                    title: "Time in Zones",
                    subtitle: zones.totalDuration > 0 ? "Across \(DurationFormat.compact(zones.totalDuration))" : nil
                ) {
                    ZoneBar(breakdown: zones)
                        .frame(height: 18)
                        .padding(.bottom, 4)
                    VStack(spacing: 8) {
                        ForEach(HeartRateZone.allCases) { zone in
                            ZoneRow(
                                zone: zone,
                                duration: zones.duration(zone),
                                fraction: zones.fraction(zone),
                                bpmRange: zone.range(maxHR: profile.maxHR)
                            )
                        }
                    }
                }
            }
            .padding()
            .readableContentWidth()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(day.day.formatted(.dateTime.weekday(.wide).month().day()))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summaryCard(readings: Int) -> some View {
        CardContainer(title: "Summary", subtitle: readings == 1 ? "1 reading" : "\(readings.formatted()) readings") {
            LazyVGrid(columns: columns, spacing: 10) {
                CompactMetricRow(label: "Average", value: DashboardText.whole(day.avgBPM), unit: "bpm", icon: "waveform.path.ecg")
                CompactMetricRow(label: "Resting", value: DashboardText.whole(day.restingBPM), unit: "bpm", icon: "bed.double.fill")
                CompactMetricRow(label: "Lowest", value: DashboardText.whole(day.minBPM), unit: "bpm", icon: "arrow.down.heart")
                CompactMetricRow(label: "Highest", value: DashboardText.whole(day.maxBPM), unit: "bpm", icon: "arrow.up.heart")
            }
        }
    }

    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
    }
}

// MARK: - Chart scrubbing

/// Where a scrub can snap to.
private struct HeartScrubTarget {
    /// Position of the indicator on the x axis.
    let date: Date
    /// Position of the dot; nil draws only the vertical rule.
    let value: Double?
}

/// iOS 16 scrubbing (`chartXSelection` is iOS 17): press briefly, then drag.
/// The short press keeps vertical scrolling working when a swipe starts on
/// the chart. The indicator is drawn here, not as chart marks, so moving it
/// re-renders this overlay only, not hundreds of marks.
private struct HeartChartScrubber: View {
    let proxy: ChartProxy
    /// Sorted by date.
    let targets: [HeartScrubTarget]
    @Binding var selectedIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let plot = geo[proxy.plotAreaFrame]
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture(plotOriginX: plot.minX))

                if let index = selectedIndex, targets.indices.contains(index),
                   let x = proxy.position(forX: targets[index].date) {
                    Rectangle()
                        .fill(Color.secondary)
                        .frame(width: 1, height: plot.height)
                        .position(x: plot.minX + x, y: plot.midY)
                        .allowsHitTesting(false)
                    if let value = targets[index].value, let y = proxy.position(forY: value) {
                        Circle()
                            .fill(Color.pink)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                            .position(x: plot.minX + x, y: plot.minY + y)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        // VoiceOver reads the chart's own marks instead.
        .accessibilityHidden(true)
    }

    private func scrubGesture(plotOriginX: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value,
                      let date = proxy.value(atX: drag.location.x - plotOriginX, as: Date.self),
                      let index = nearestIndex(to: date),
                      index != selectedIndex else { return }
                Haptics.selection()
                selectedIndex = index
            }
            .onEnded { _ in selectedIndex = nil }
    }

    private func nearestIndex(to date: Date) -> Int? {
        guard !targets.isEmpty else { return nil }
        var low = 0
        var high = targets.count - 1
        while low < high {
            let mid = (low + high) / 2
            if targets[mid].date < date { low = mid + 1 } else { high = mid }
        }
        if low > 0, date.timeIntervalSince(targets[low - 1].date) < targets[low].date.timeIntervalSince(date) {
            return low - 1
        }
        return low
    }
}

private struct HeartReadoutText {
    let label: String
    let value: String
    let detail: String
    let spoken: String
}

/// Header row above a chart: the data's range normally, the scrubbed value
/// while dragging (Apple Health style, instead of an annotation that covers
/// the line). Its own view so a scrub re-renders only this row.
private struct HeartChartReadout: View {
    @Binding var selectedIndex: Int?
    let content: (Int?) -> HeartReadoutText?

    var body: some View {
        if let text = content(selectedIndex) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(text.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text.value)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                Text(text.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text.spoken)
        }
    }
}

// MARK: - Charts

/// One plotted value on the trend chart: a raw sample or a bucket aggregate.
private struct TrendPoint: Identifiable {
    let id: Int
    let date: Date
    let bpm: Double
    /// Set for bucket aggregates only.
    let bucket: HeartRateBucket?
    /// Neighbours closer than the gap threshold share a segment, so the line
    /// breaks where there's no data (e.g. the watch was on its charger).
    var segment = 0
    /// Alone in its segment: a line can't draw a single point, so it gets a dot.
    var isolated = false

    var low: Double { bucket?.minBPM ?? bpm }
    var high: Double { bucket?.maxBPM ?? bpm }
}

private struct OverallChart: View {
    let samples: [HeartRateSample]
    /// When non-empty, the chart draws these aggregates (min–max band + mean
    /// line) instead of every raw sample — tens of thousands of marks would
    /// freeze the UI.
    let buckets: [HeartRateBucket]
    let averageBPM: Double?
    let range: HeartRateViewModel.OverallRange
    /// Pins the x axis (e.g. a whole day, 00–24) instead of fitting the data.
    var xDomain: ClosedRange<Date>? = nil
    var plotHeight: CGFloat = 240
    var accessibilityTitle: String? = nil
    @State var scrubIndex: Int? = nil

    var body: some View {
        let points = Self.makePoints(samples: samples, buckets: buckets)
        let targets = points.map { HeartScrubTarget(date: $0.date, value: $0.bpm) }
        VStack(alignment: .leading, spacing: 8) {
            HeartChartReadout(selectedIndex: $scrubIndex) { index in
                readout(for: index, points: points)
            }
            plot(points)
                .frame(height: plotHeight)
                .chartOverlay { proxy in
                    HeartChartScrubber(proxy: proxy, targets: targets, selectedIndex: $scrubIndex)
                }
            if !buckets.isEmpty {
                legend
            }
        }
        .onChange(of: points.count) { _ in scrubIndex = nil }
    }

    @ViewBuilder
    private func plot(_ points: [TrendPoint]) -> some View {
        if let xDomain {
            chart(points).chartXScale(domain: xDomain)
        } else {
            chart(points)
        }
    }

    private func chart(_ points: [TrendPoint]) -> some View {
        let showAllDots = buckets.isEmpty && points.count <= 150
        return Chart {
            if buckets.isEmpty {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("BPM", point.bpm),
                        series: .value("Segment", point.segment)
                    )
                    .foregroundStyle(.pink)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .accessibilityLabel(markTimeLabel(point.date))
                    .accessibilityValue(DashboardText.spokenBPM(point.bpm))
                }
            } else {
                // The band stays continuous; only the average line breaks at gaps.
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        yStart: .value("Min", point.low),
                        yEnd: .value("Max", point.high)
                    )
                    .foregroundStyle(.pink.opacity(0.18))
                    .interpolationMethod(.monotone)
                    .accessibilityHidden(true)
                }

                ForEach(points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("BPM", point.bpm),
                        series: .value("Segment", point.segment)
                    )
                    .foregroundStyle(.pink)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .accessibilityLabel(markTimeLabel(point.date))
                    .accessibilityValue(bucketSpokenValue(point))
                }
            }

            // Dots duplicate the line for VoiceOver, so they're hidden from it.
            ForEach(points.filter { showAllDots || $0.isolated }) { point in
                PointMark(
                    x: .value("Time", point.date),
                    y: .value("BPM", point.bpm)
                )
                .symbolSize(point.isolated ? 16 : 8)
                .foregroundStyle(Color.pink.opacity(point.isolated ? 0.9 : 0.55))
                .accessibilityHidden(true)
            }

            if let avg = averageBPM {
                RuleMark(y: .value("Avg", avg))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .topTrailing, alignment: .trailing) {
                        Text("avg \(Int(avg.rounded()))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Average")
                    .accessibilityValue(DashboardText.spokenBPM(avg))
            }
        }
        .chartYScale(domain: yDomain(points))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 6)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(.gray.opacity(0.35))
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.gray.opacity(0.5))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: tickCount)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(.gray.opacity(0.2))
                AxisTick().foregroundStyle(.gray.opacity(0.5))
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d, format: xAxisFormat)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxisLabel("BPM", position: .top, alignment: .leading)
        .accessibilityLabel(accessibilityTitle ?? "Heart rate trend, \(range.fullTitle)")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Capsule()
                    .fill(Color.pink)
                    .frame(width: 14, height: 3)
                Text("Average")
            }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.pink.opacity(0.18))
                    .frame(width: 14, height: 9)
                Text("Min–max")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    /// Sorted points with gap-aware segment numbers. A gap is more than three
    /// times the typical spacing (at least 30 min for raw samples, 1.5 buckets
    /// for aggregates), so sparse-but-regular data still draws as a line.
    private static func makePoints(samples: [HeartRateSample], buckets: [HeartRateBucket]) -> [TrendPoint] {
        var points: [TrendPoint]
        let minGap: TimeInterval
        if buckets.isEmpty {
            points = samples.sorted { $0.date < $1.date }.enumerated().map { index, sample in
                TrendPoint(id: index, date: sample.date, bpm: sample.bpm, bucket: nil)
            }
            minGap = 30 * 60
        } else {
            points = buckets.enumerated().map { index, bucket in
                TrendPoint(id: index, date: bucket.mid, bpm: bucket.avgBPM, bucket: bucket)
            }
            minGap = 1.5 * buckets[0].end.timeIntervalSince(buckets[0].start)
        }
        guard points.count > 1 else {
            for i in points.indices { points[i].isolated = true }
            return points
        }

        let gaps = zip(points.dropFirst(), points).map { $0.date.timeIntervalSince($1.date) }
        let typicalGap = gaps.sorted()[gaps.count / 2]
        let threshold = max(minGap, typicalGap * 3)
        var segment = 0
        var segmentSizes = [1]
        for i in 1..<points.count {
            if gaps[i - 1] > threshold {
                segment += 1
                segmentSizes.append(0)
            }
            points[i].segment = segment
            segmentSizes[segment] += 1
        }
        for i in points.indices where segmentSizes[points[i].segment] == 1 {
            points[i].isolated = true
        }
        return points
    }

    private func readout(for index: Int?, points: [TrendPoint]) -> HeartReadoutText? {
        if let index, points.indices.contains(index) {
            let point = points[index]
            if let bucket = point.bucket {
                let label = bucketTimeLabel(bucket)
                let avg = Int(bucket.avgBPM.rounded())
                let low = Int(bucket.minBPM.rounded())
                let high = Int(bucket.maxBPM.rounded())
                return HeartReadoutText(
                    label: label,
                    value: "\(avg)",
                    detail: "avg bpm · \(low)–\(high)",
                    spoken: "\(label), average \(avg), range \(low) to \(high) beats per minute"
                )
            }
            let label = pointTimeLabel(point.date)
            return HeartReadoutText(
                label: label,
                value: "\(Int(point.bpm.rounded()))",
                detail: "bpm",
                spoken: "\(label), \(DashboardText.spokenBPM(point.bpm))"
            )
        }
        guard let extremes = Self.extremes(points) else { return nil }
        let (low, high) = extremes
        return HeartReadoutText(
            label: "RANGE",
            value: "\(Int(low.rounded()))–\(Int(high.rounded()))",
            detail: "bpm",
            spoken: "Range, \(Int(low.rounded())) to \(Int(high.rounded())) beats per minute"
        )
    }

    private static func extremes(_ points: [TrendPoint]) -> (Double, Double)? {
        guard let low = points.map(\.low).min(), let high = points.map(\.high).max() else { return nil }
        return (low, high)
    }

    private func pointTimeLabel(_ date: Date) -> String {
        switch range {
        case .day1:  return date.formatted(.dateTime.hour().minute())
        case .week1: return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .month1, .month3, .month6:
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
    }

    private func bucketTimeLabel(_ bucket: HeartRateBucket) -> String {
        // Day-long buckets (6M) read better as a date than as "00:00–00:00".
        if bucket.end.timeIntervalSince(bucket.start) >= 86_400 - 60 {
            return bucket.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        let start = pointTimeLabel(bucket.start)
        let end = bucket.end.formatted(.dateTime.hour().minute())
        return "\(start)–\(end)"
    }

    private func markTimeLabel(_ date: Date) -> String {
        switch range {
        case .day1, .week1:
            return date.formatted(.dateTime.weekday(.wide).hour().minute())
        case .month1, .month3, .month6:
            return date.formatted(.dateTime.month(.wide).day())
        }
    }

    private func bucketSpokenValue(_ point: TrendPoint) -> String {
        guard let bucket = point.bucket else { return DashboardText.spokenBPM(point.bpm) }
        return "average \(Int(bucket.avgBPM.rounded())), range \(Int(bucket.minBPM.rounded())) to \(Int(bucket.maxBPM.rounded())) beats per minute"
    }

    private var tickCount: Int {
        switch range {
        case .day1:  return 6
        case .week1: return 7
        case .month1, .month3, .month6: return 6
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch range {
        case .day1:   return .dateTime.hour()
        case .week1:  return .dateTime.weekday(.abbreviated)
        case .month1: return .dateTime.day().month(.abbreviated)
        case .month3, .month6: return .dateTime.month(.abbreviated)
        }
    }

    private func yDomain(_ points: [TrendPoint]) -> ClosedRange<Double> {
        guard let extremes = Self.extremes(points) else { return 40...160 }
        let (lo, hi) = extremes
        let padding = max(5, (hi - lo) * 0.1)
        let lower = max(30, (lo - padding).rounded(.down))
        let upper = max(lower + 10, (hi + padding).rounded(.up))
        return lower...upper
    }
}

private struct DailyChart: View {
    let stats: [DailyHeartRateStats]
    @State var scrubIndex: Int? = nil

    var body: some View {
        // Bars are centered in their day, so the indicator snaps to midday.
        let targets = stats.map { HeartScrubTarget(date: $0.day.addingTimeInterval(12 * 3600), value: $0.avgBPM) }
        VStack(alignment: .leading, spacing: 8) {
            HeartChartReadout(selectedIndex: $scrubIndex) { index in
                readout(for: index)
            }
            chart
                .frame(height: 240)
                .chartOverlay { proxy in
                    HeartChartScrubber(proxy: proxy, targets: targets, selectedIndex: $scrubIndex)
                }
            legend
        }
        .onChange(of: stats.count) { _ in scrubIndex = nil }
    }

    private var chart: some View {
        Chart(stats) { day in
            if let minV = day.minBPM, let maxV = day.maxBPM {
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    yStart: .value("Min", minV),
                    yEnd: .value("Max", maxV),
                    width: .ratio(0.55)
                )
                .foregroundStyle(.pink.opacity(0.7))
                .cornerRadius(4)
                .accessibilityLabel(DailyRow.spokenDay(day))
                .accessibilityValue(Self.spokenRange(day, low: minV, high: maxV))
            }
            if let avg = day.avgBPM {
                // A card-colored halo cuts the dot out of the bar; plain white
                // turned into a bright ring in Dark Mode.
                PointMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Avg", avg)
                )
                .symbolSize(60)
                .foregroundStyle(Color(.secondarySystemGroupedBackground))
                .accessibilityHidden(true)
                PointMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Avg", avg)
                )
                .symbolSize(22)
                .foregroundStyle(.pink)
                .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: yDomain())
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 6)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(.gray.opacity(0.35))
                AxisTick().foregroundStyle(.gray.opacity(0.5))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: dayStride)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(.gray.opacity(0.2))
                AxisTick().foregroundStyle(.gray.opacity(0.5))
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d, format: .dateTime.day().month(.abbreviated))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxisLabel("BPM", position: .top, alignment: .leading)
        .accessibilityLabel("Daily heart rate range")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.pink.opacity(0.7))
                    .frame(width: 8, height: 14)
                Text("Daily range")
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.pink)
                    .frame(width: 7, height: 7)
                Text("Average")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func readout(for index: Int?) -> HeartReadoutText? {
        if let index, stats.indices.contains(index) {
            let day = stats[index]
            let label = day.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            guard let low = day.minBPM, let high = day.maxBPM else {
                return HeartReadoutText(label: label, value: "—", detail: "no data", spoken: "\(label), no data")
            }
            let avg = day.avgBPM.map { " · avg \(Int($0.rounded()))" } ?? ""
            return HeartReadoutText(
                label: label,
                value: "\(Int(low.rounded()))–\(Int(high.rounded()))",
                detail: "bpm\(avg)",
                spoken: "\(label), \(Self.spokenRange(day, low: low, high: high))"
            )
        }
        guard let low = stats.compactMap(\.minBPM).min(),
              let high = stats.compactMap(\.maxBPM).max() else { return nil }
        return HeartReadoutText(
            label: "RANGE",
            value: "\(Int(low.rounded()))–\(Int(high.rounded()))",
            detail: "bpm",
            spoken: "Range, \(Int(low.rounded())) to \(Int(high.rounded())) beats per minute"
        )
    }

    private static func spokenRange(_ day: DailyHeartRateStats, low: Double, high: Double) -> String {
        let avg = day.avgBPM.map { String(Int($0.rounded())) } ?? "unknown"
        return "lowest \(Int(low.rounded())), average \(avg), highest \(Int(high.rounded())) beats per minute"
    }

    /// Label every day for a week, then thin out so labels never collide.
    private var dayStride: Int {
        max(1, Int((Double(stats.count) / 7).rounded(.up)))
    }

    private func yDomain() -> ClosedRange<Double> {
        let mins = stats.compactMap(\.minBPM)
        let maxs = stats.compactMap(\.maxBPM)
        guard let lo = mins.min(), let hi = maxs.max() else { return 40...160 }
        let padding = max(5, (hi - lo) * 0.1)
        let lower = max(30, lo - padding)
        return lower...max(lower + 10, hi + padding)
    }
}

#Preview {
    NavigationStack { DashboardView() }
        .environmentObject(HeartRateViewModel.preview)
        .environmentObject(UserProfile.shared)
        .environmentObject(AppRouter.shared)
}
