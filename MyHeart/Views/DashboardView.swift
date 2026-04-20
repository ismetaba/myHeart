import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @State private var pdfURL: URL?
    @State private var showShare = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    modePicker

                    if viewModel.mode == .overall {
                        overallControls
                        latestCard
                        statsGrid(overall: true)
                        overallChart
                    } else {
                        dailyControls
                        dailySummaryCard
                        dailyChart
                        dailyList
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("MyHeart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
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
            .refreshable { await viewModel.refresh() }
            .sheet(isPresented: $showShare) {
                if let pdfURL { ShareSheet(activityItems: [pdfURL]) }
            }
            .alert("Export Failed",
                   isPresented: .constant(exportError != nil),
                   actions: { Button("OK") { exportError = nil } },
                   message: { Text(exportError ?? "") })
        }
    }

    // MARK: - Mode & Range Controls

    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { viewModel.mode },
            set: { new in Task { await viewModel.setMode(new) } }
        )) {
            ForEach(HeartRateViewModel.ReportMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
    }

    private var overallControls: some View {
        Picker("Range", selection: Binding(
            get: { viewModel.selectedRange },
            set: { new in Task { await viewModel.setOverallRange(new) } }
        )) {
            ForEach(HeartRateViewModel.OverallRange.allCases) { r in
                Text(r.rawValue).tag(r)
            }
        }
        .pickerStyle(.segmented)
    }

    @State private var localStart: Date = Date()
    @State private var localEnd: Date = Date()
    @State private var didInitDates = false

    private var dailyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily Report")
                .font(.headline)
            Text("Pick a range up to \(HeartRateViewModel.maxDailyRangeDays) days. Each day in the range gets its own row.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                DatePicker("Start", selection: $localStart, in: ...localEnd, displayedComponents: .date)
                DatePicker("End", selection: $localEnd, in: localStart...Date(), displayedComponents: .date)
            }

            HStack {
                if let days = Calendar.current.dateComponents([.day], from: localStart, to: localEnd).day {
                    Label("\(days + 1) day\(days == 0 ? "" : "s")", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Apply") {
                    Task { await viewModel.setDailyRange(start: localStart, end: localEnd) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        .onAppear {
            if !didInitDates {
                localStart = viewModel.dailyStart
                localEnd = viewModel.dailyEnd
                didInitDates = true
            }
        }
    }

    // MARK: - Overall Cards

    private var latestCard: some View {
        VStack(spacing: 6) {
            Text("Current Heart Rate")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(viewModel.summary.latest.map { String(Int($0.bpm)) } ?? "—")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.pink)
                Text("BPM")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if let date = viewModel.summary.latest?.date {
                Text(date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func statsGrid(overall: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(title: "Resting", value: format(viewModel.summary.restingBPM), unit: "bpm", icon: "bed.double.fill")
            StatTile(title: "Average", value: format(viewModel.summary.averageBPM), unit: "bpm", icon: "waveform.path.ecg")
            StatTile(title: "Min", value: format(viewModel.summary.minBPM), unit: "bpm", icon: "arrow.down.heart")
            StatTile(title: "Max", value: format(viewModel.summary.maxBPM), unit: "bpm", icon: "arrow.up.heart")
            StatTile(title: "HRV (SDNN)", value: format(viewModel.summary.hrvSDNN), unit: "ms", icon: "heart.text.square")
            StatTile(title: "Samples", value: "\(viewModel.summary.sampleCount)", unit: "", icon: "number")
        }
    }

    // MARK: - Charts

    private var overallChart: some View {
        ChartCard(title: "Trend — \(viewModel.selectedRange.fullTitle)") {
            if viewModel.samples.isEmpty {
                emptyState
            } else {
                Chart {
                    // Zone bands (optional, subtle)
                    RectangleMark(
                        xStart: .value("Start", viewModel.summary.rangeStart),
                        xEnd: .value("End", viewModel.summary.rangeEnd),
                        yStart: .value("Low", 60),
                        yEnd: .value("High", 100)
                    )
                    .foregroundStyle(.pink.opacity(0.05))

                    ForEach(viewModel.samples) { sample in
                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value("BPM", sample.bpm)
                        )
                        .foregroundStyle(.pink)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }

                    if let avg = viewModel.summary.averageBPM {
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
                .chartYScale(domain: yDomain(for: viewModel.samples.map(\.bpm)))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 6)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(.gray.opacity(0.35))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.gray.opacity(0.5))
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
                    AxisMarks(values: .automatic(desiredCount: xTickCount)) { value in
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
                .frame(height: 260)
            }
        }
    }

    // MARK: - Daily mode

    private var dailySummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatTile(title: "Avg of Daily Avg", value: format(viewModel.dailyAverageOfAverages), unit: "bpm", icon: "waveform.path.ecg")
                StatTile(title: "Avg Resting", value: format(viewModel.dailyOverallResting), unit: "bpm", icon: "bed.double.fill")
                StatTile(title: "Min", value: format(viewModel.dailyOverallMin), unit: "bpm", icon: "arrow.down.heart")
                StatTile(title: "Max", value: format(viewModel.dailyOverallMax), unit: "bpm", icon: "arrow.up.heart")
            }
        }
    }

    private var dailyChart: some View {
        ChartCard(title: "Daily Range (min — max)") {
            if viewModel.dailyStats.isEmpty {
                emptyState
            } else {
                Chart(viewModel.dailyStats) { day in
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
                .chartYScale(domain: dailyYDomain())
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
                .frame(height: 260)
            }
        }
    }

    private var dailyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-Day Breakdown")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(viewModel.dailyStats) { day in
                    DailyRow(day: day)
                    Divider().padding(.leading)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        }
    }

    // MARK: - Helpers

    private var emptyState: some View {
        Text("No heart rate data in this range. Wear your Apple Watch or record samples, then pull to refresh.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180)
            .multilineTextAlignment(.center)
            .padding()
    }

    private var exportDisabled: Bool {
        switch viewModel.mode {
        case .overall: return viewModel.samples.isEmpty
        case .daily:   return viewModel.dailyStats.isEmpty
        }
    }

    private var xTickCount: Int {
        switch viewModel.selectedRange {
        case .day1: return 6
        case .week1: return 7
        case .month1: return 6
        case .month3: return 6
        case .month6: return 6
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch viewModel.selectedRange {
        case .day1:
            return .dateTime.hour()
        case .week1:
            return .dateTime.weekday(.abbreviated)
        case .month1:
            return .dateTime.day().month(.abbreviated)
        case .month3, .month6:
            return .dateTime.month(.abbreviated)
        }
    }

    private func yDomain(for values: [Double]) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 40...160 }
        let padding = max(5, (hi - lo) * 0.1)
        let lower = max(30, (lo - padding).rounded(.down))
        let upper = (hi + padding).rounded(.up)
        return lower...upper
    }

    private func dailyYDomain() -> ClosedRange<Double> {
        let mins = viewModel.dailyStats.compactMap(\.minBPM)
        let maxs = viewModel.dailyStats.compactMap(\.maxBPM)
        guard let lo = mins.min(), let hi = maxs.max() else { return 40...160 }
        let padding = max(5, (hi - lo) * 0.1)
        return max(30, lo - padding)...(hi + padding)
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
                    samples: viewModel.samples,
                    rangeTitle: viewModel.selectedRange.fullTitle
                )
            case .daily:
                url = try PDFExporter.exportDaily(
                    stats: viewModel.dailyStats,
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

// MARK: - Small subviews

private struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title2.weight(.semibold))
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}

private struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}

private struct DailyRow: View {
    let day: DailyHeartRateStats

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.day, format: .dateTime.weekday(.abbreviated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(day.day, format: .dateTime.month(.abbreviated).day())
                    .font(.subheadline.weight(.medium))
            }
            .frame(width: 70, alignment: .leading)

            Spacer()

            HStack(spacing: 16) {
                metric(label: "min", value: day.minBPM)
                metric(label: "avg", value: day.avgBPM, highlight: true)
                metric(label: "max", value: day.maxBPM)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func metric(label: String, value: Double?, highlight: Bool = false) -> some View {
        VStack(spacing: 0) {
            Text(value.map { String(Int($0.rounded())) } ?? "—")
                .font(.subheadline.monospacedDigit().weight(highlight ? .semibold : .regular))
                .foregroundStyle(highlight ? Color.pink : Color.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 44)
    }
}

#Preview {
    DashboardView()
        .environmentObject(HeartRateViewModel.preview)
}
