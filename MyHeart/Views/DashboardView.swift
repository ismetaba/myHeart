import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @EnvironmentObject private var profile: UserProfile
    @State private var pdfURL: URL?
    @State private var showShare = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    modePicker
                        .padding(.horizontal)

                    if viewModel.mode == .overall {
                        overallSection
                    } else {
                        dailySection
                    }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("MyHeart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .refreshable { await viewModel.refresh() }
            .sheet(isPresented: $showShare) {
                if let pdfURL { ShareSheet(activityItems: [pdfURL]) }
            }
            .alert(
                "Export Failed",
                isPresented: .constant(exportError != nil),
                actions: { Button("OK") { exportError = nil } },
                message: { Text(exportError ?? "") }
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await export() }
            } label: {
                if viewModel.isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .disabled(exportDisabled)
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { viewModel.mode },
            set: { new in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { await viewModel.setMode(new) }
            }
        )) {
            ForEach(HeartRateViewModel.ReportMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Overall section

    private var overallSection: some View {
        VStack(spacing: 16) {
            overallRangePicker
            heroCard
            keyStatsRow
            statsGrid
            zoneCard
            if !viewModel.insights.isEmpty {
                insightsCard
            }
            overallChartCard
            if viewModel.sourceBreakdown.count > 1 {
                sourcesRow
            }
            lastRefreshFooter
        }
        .padding(.horizontal)
    }

    private var overallRangePicker: some View {
        Picker("Range", selection: Binding(
            get: { viewModel.selectedRange },
            set: { new in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        VStack(spacing: 8) {
            HStack {
                Label("Heart Rate", systemImage: "heart.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.pink)
                Spacer()
                if let date = viewModel.summary.latest?.date {
                    (Text(date, style: .relative) + Text(" ago"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(viewModel.summary.latest.map { String(Int($0.bpm)) } ?? "—")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.pink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel(heroAccessibilityLabel)
                Text("BPM")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 10) {
                if let latest = viewModel.summary.latest {
                    let zone = HeartRateZone(bpm: latest.bpm, maxHR: profile.maxHR)
                    zoneBadge(zone)
                }
                Spacer()
                if let latest = viewModel.summary.latest {
                    Text(latest.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    private var keyStatsRow: some View {
        HStack(spacing: 12) {
            DeltaStatTile(
                title: "Resting",
                icon: "bed.double.fill",
                value: viewModel.summary.restingBPM,
                unit: "bpm",
                delta: viewModel.restingDelta,
                deltaRangeLabel: viewModel.selectedRange.previousTitle,
                tint: .pink
            )
            DeltaStatTile(
                title: "Average",
                icon: "waveform.path.ecg",
                value: viewModel.summary.averageBPM,
                unit: "bpm",
                delta: viewModel.averageDelta,
                deltaRangeLabel: viewModel.selectedRange.previousTitle,
                tint: .pink
            )
            DeltaStatTile(
                title: "HRV",
                icon: "heart.text.square",
                value: viewModel.summary.hrvSDNN,
                unit: "ms",
                delta: viewModel.hrvDelta,
                deltaRangeLabel: viewModel.selectedRange.previousTitle,
                tint: .purple
            )
        }
    }

    private var statsGrid: some View {
        HStack(spacing: 12) {
            SmallStatTile(
                title: "Min",
                icon: "arrow.down.heart",
                value: viewModel.summary.minBPM,
                unit: "bpm",
                tint: .blue
            )
            SmallStatTile(
                title: "Max",
                icon: "arrow.up.heart",
                value: viewModel.summary.maxBPM,
                unit: "bpm",
                tint: .red
            )
            SmallStatTile(
                title: "Samples",
                icon: "number",
                value: Double(viewModel.summary.sampleCount),
                unit: "",
                tint: .gray
            )
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
        }
    }

    private var zoneCardSubtitle: String? {
        viewModel.zoneBreakdown.totalDuration > 0
            ? "Across \(DurationFormat.compact(viewModel.zoneBreakdown.totalDuration))"
            : nil
    }

    private var insightsCard: some View {
        CardContainer(title: "Insights", subtitle: nil) {
            VStack(spacing: 10) {
                ForEach(viewModel.insights) { InsightRow(insight: $0) }
            }
        }
    }

    private var overallChartCard: some View {
        CardContainer(title: "Trend", subtitle: viewModel.selectedRange.fullTitle) {
            if viewModel.samples.isEmpty {
                emptyChartState
            } else {
                OverallChart(
                    samples: viewModel.samples,
                    averageBPM: viewModel.summary.averageBPM,
                    range: viewModel.selectedRange,
                    maxHR: profile.maxHR
                )
                .frame(height: 240)
            }
        }
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

    private var lastRefreshFooter: some View {
        Group {
            if let last = viewModel.lastRefresh {
                Text("Last refreshed \(last, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Daily section

    @State private var localStart: Date = Date()
    @State private var localEnd: Date = Date()
    @State private var didInitDates = false

    private var dailySection: some View {
        VStack(spacing: 16) {
            dailyControls
            dailySummaryCard
            if !viewModel.insights.isEmpty {
                insightsCard
            }
            dailyChartCard
            dailyListCard
            if viewModel.sourceBreakdown.count > 1 {
                sourcesRow
            }
            lastRefreshFooter
        }
        .padding(.horizontal)
    }

    private var dailyControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Daily Report", systemImage: "calendar")
                    .font(.headline)
                Spacer()
                if let days = Calendar.current.dateComponents([.day], from: localStart, to: localEnd).day {
                    Text("\(days + 1) day\(days == 0 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.pink.opacity(0.15)))
                        .foregroundStyle(.pink)
                }
            }
            Text("Pick a range up to \(HeartRateViewModel.maxDailyRangeDays) days. Each day gets its own 24-hour chart in the PDF.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                DatePicker("Start", selection: $localStart, in: ...localEnd, displayedComponents: .date)
                DatePicker("End", selection: $localEnd, in: localStart...Date(), displayedComponents: .date)
            }

            HStack(spacing: 8) {
                quickPreset("7 days", days: 6)
                quickPreset("14 days", days: 13)
                quickPreset("30 days", days: 29)
                Spacer()
                Button("Apply") {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await viewModel.setDailyRange(start: localStart, end: localEnd) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
            }
        }
        .padding()
        .background(CardBackground())
        .onAppear {
            if !didInitDates {
                localStart = viewModel.dailyStart
                localEnd = viewModel.dailyEnd
                didInitDates = true
            }
        }
    }

    private func quickPreset(_ title: String, days: Int) -> some View {
        Button(title) {
            let today = Calendar.current.startOfDay(for: Date())
            localEnd = today
            localStart = Calendar.current.date(byAdding: .day, value: -days, to: today) ?? today
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
    }

    private var dailySummaryCard: some View {
        CardContainer(title: "Summary", subtitle: rangeSubtitle) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                CompactMetricRow(label: "Avg of Daily Avg", value: format(viewModel.dailyAverageOfAverages), unit: "bpm", icon: "waveform.path.ecg")
                CompactMetricRow(label: "Avg Resting", value: format(viewModel.dailyOverallResting), unit: "bpm", icon: "bed.double.fill")
                CompactMetricRow(label: "Lowest Min", value: format(viewModel.dailyOverallMin), unit: "bpm", icon: "arrow.down.heart")
                CompactMetricRow(label: "Highest Max", value: format(viewModel.dailyOverallMax), unit: "bpm", icon: "arrow.up.heart")
            }
        }
    }

    private var rangeSubtitle: String? {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return "\(fmt.string(from: viewModel.dailyStart)) – \(fmt.string(from: viewModel.dailyEnd))"
    }

    private var dailyChartCard: some View {
        CardContainer(title: "Daily Range", subtitle: "min – max per day") {
            if viewModel.dailyStats.isEmpty {
                emptyChartState
            } else {
                DailyChart(stats: viewModel.dailyStats)
                    .frame(height: 240)
            }
        }
    }

    private var dailyListCard: some View {
        CardContainer(title: "Per-Day Breakdown", subtitle: nil) {
            VStack(spacing: 0) {
                ForEach(Array(viewModel.dailyStats.enumerated()), id: \.element.id) { index, day in
                    DailyRow(
                        day: day,
                        breakdown: viewModel.dailyZones[day.day],
                        maxHR: profile.maxHR
                    )
                    if index < viewModel.dailyStats.count - 1 {
                        Divider().padding(.leading, 60)
                    }
                }
            }
        }
    }

    // MARK: - Shared helpers

    @ViewBuilder
    private func zoneBadge(_ zone: HeartRateZone) -> some View {
        HStack(spacing: 6) {
            Image(systemName: zone.systemImage)
                .font(.caption2.weight(.semibold))
            Text(zone.label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(zone.color.opacity(0.18)))
        .foregroundStyle(zone.color)
    }

    private var emptyChartState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No heart rate data in this range")
                .font(.subheadline.weight(.medium))
            Text("Wear your Apple Watch or record samples in Apple Health, then pull down to refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(.vertical)
    }

    private var exportDisabled: Bool {
        if viewModel.isLoading { return true }
        switch viewModel.mode {
        case .overall: return viewModel.samples.isEmpty
        case .daily:   return viewModel.dailyStats.isEmpty
        }
    }

    private var heroAccessibilityLabel: String {
        guard let latest = viewModel.summary.latest else { return "No heart rate data" }
        return "\(Int(latest.bpm.rounded())) beats per minute"
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(Int(value.rounded()))
    }

    private func export() async {
        do {
            let url: URL
            switch viewModel.mode {
            case .overall:
                url = try PDFExporter.exportOverall(
                    summary: viewModel.summary,
                    previousSummary: viewModel.previousSummary,
                    samples: viewModel.samples,
                    zones: viewModel.zoneBreakdown,
                    maxHR: profile.maxHR,
                    rangeTitle: viewModel.selectedRange.fullTitle,
                    previousRangeLabel: viewModel.selectedRange.previousTitle
                )
            case .daily:
                url = try PDFExporter.exportDaily(
                    stats: viewModel.dailyStats,
                    samples: viewModel.dailySamples,
                    zonesByDay: viewModel.dailyZones,
                    maxHR: profile.maxHR,
                    start: viewModel.dailyStart,
                    end: viewModel.dailyEnd
                )
            }
            pdfURL = url
            showShare = true
        } catch {
            exportError = error.localizedDescription
        }
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
        .background(CardBackground())
    }
}

private struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

private struct DeltaStatTile: View {
    let title: String
    let icon: String
    let value: Double?
    let unit: String
    let delta: TrendDelta
    let deltaRangeLabel: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)

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

            HStack(spacing: 3) {
                if let s = delta.shortString {
                    Image(systemName: delta.arrow)
                        .font(.caption2.weight(.bold))
                    Text(s)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                    Text("vs \(deltaRangeLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("—")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(delta.tint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    private var valueString: String {
        guard let v = value else { return "—" }
        return String(Int(v.rounded()))
    }
}

private struct SmallStatTile: View {
    let title: String
    let icon: String
    let value: Double?
    let unit: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { String(Int($0.rounded())) } ?? "—")
                    .font(.headline)
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
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
                    ForEach(HeartRateZone.allCases) { zone in
                        let frac = breakdown.fraction(zone)
                        if frac > 0 {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(zone.color)
                                .frame(width: max(3, w * CGFloat(frac) - 2))
                        }
                    }
                }
            }
        }
    }
}

private struct ZoneRow: View {
    let zone: HeartRateZone
    let duration: TimeInterval
    let fraction: Double
    let bpmRange: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(zone.color)
                .frame(width: 10, height: 10)
            Text(zone.label)
                .font(.subheadline.weight(.medium))
            Text(bpmText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(DurationFormat.compact(duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(duration > 0 ? zone.color : Color.secondary)
        }
    }

    private var bpmText: String {
        zone == .peak
            ? "\(bpmRange.lowerBound)+"
            : "\(bpmRange.lowerBound)–\(bpmRange.upperBound)"
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

            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title)
                    .font(.subheadline.weight(.semibold))
                Text(insight.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
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
    }
}

private struct DailyRow: View {
    let day: DailyHeartRateStats
    let breakdown: ZoneBreakdown?
    let maxHR: Double

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.day, format: .dateTime.weekday(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(day.day, format: .dateTime.month(.abbreviated).day())
                    .font(.subheadline.weight(.semibold))
            }
            .frame(width: 48, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    metric("min", value: day.minBPM)
                    metric("avg", value: day.avgBPM, highlight: true)
                    metric("max", value: day.maxBPM)
                    if let r = day.restingBPM {
                        metric("rest", value: r)
                    }
                    Spacer()
                }
                if let breakdown, breakdown.totalDuration > 0 {
                    ZoneStripMini(breakdown: breakdown)
                        .frame(height: 6)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
}

private struct ZoneStripMini: View {
    let breakdown: ZoneBreakdown

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 1) {
                ForEach(HeartRateZone.allCases) { zone in
                    let frac = breakdown.fraction(zone)
                    if frac > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(zone.color)
                            .frame(width: max(1, w * CGFloat(frac) - 1))
                    }
                }
            }
        }
    }
}

// MARK: - Charts

private struct OverallChart: View {
    let samples: [HeartRateSample]
    let averageBPM: Double?
    let range: HeartRateViewModel.OverallRange
    let maxHR: Double

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("BPM", sample.bpm)
                )
                .foregroundStyle(.pink)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
            }

            ForEach(samples) { sample in
                PointMark(
                    x: .value("Time", sample.date),
                    y: .value("BPM", sample.bpm)
                )
                .symbolSize(8)
                .foregroundStyle(.pink.opacity(0.55))
            }

            if let avg = averageBPM {
                RuleMark(y: .value("Avg", avg))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .topTrailing, alignment: .trailing) {
                        Text("avg \(Int(avg))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartYScale(domain: yDomain())
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

    private func yDomain() -> ClosedRange<Double> {
        let values = samples.map(\.bpm)
        guard let lo = values.min(), let hi = values.max() else { return 40...160 }
        let padding = max(5, (hi - lo) * 0.1)
        let lower = max(30, (lo - padding).rounded(.down))
        let upper = (hi + padding).rounded(.up)
        return lower...upper
    }
}

private struct DailyChart: View {
    let stats: [DailyHeartRateStats]

    var body: some View {
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
            }
            if let avg = day.avgBPM {
                PointMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Avg", avg)
                )
                .symbolSize(60)
                .foregroundStyle(.white)
                PointMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Avg", avg)
                )
                .symbolSize(22)
                .foregroundStyle(.pink)
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
            AxisMarks(values: .stride(by: .day)) { value in
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
    }

    private func yDomain() -> ClosedRange<Double> {
        let mins = stats.compactMap(\.minBPM)
        let maxs = stats.compactMap(\.maxBPM)
        guard let lo = mins.min(), let hi = maxs.max() else { return 40...160 }
        let padding = max(5, (hi - lo) * 0.1)
        return max(30, lo - padding)...(hi + padding)
    }
}

#Preview {
    DashboardView()
        .environmentObject(HeartRateViewModel.preview)
        .environmentObject(UserProfile.shared)
}
