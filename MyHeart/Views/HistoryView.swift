import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @EnvironmentObject private var profile: UserProfile
    @EnvironmentObject private var router: AppRouter
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var searchText: String = ""
    @State private var sourceFilter: String?
    @State private var zoneFilter: HeartRateZone?
    @State private var onlyElevated: Bool = false
    /// Remembered across launches: people who switch to hourly rows to get
    /// through busy workout days usually want them every time.
    @AppStorage("history.grouping") private var grouping: Grouping = .everySample
    /// Long ranges hold tens of thousands of samples; render them in pages so
    /// the list stays responsive.
    @State private var visibleLimit: Int = Self.pageSize
    /// Keeps the empty state on screen during a pull-to-refresh; swapping it
    /// for the loading spinner would tear the scroll view down mid-gesture.
    @State private var isPullRefreshing = false

    private static let pageSize = 1000

    private enum Grouping: String, CaseIterable, Identifiable {
        case everySample, hourly
        var id: String { rawValue }

        var title: String {
            switch self {
            case .everySample: return "Every Sample"
            case .hourly: return "Hourly Summary"
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("History")
                .toolbar { toolbarContent }
                .refreshable { await pullToRefresh() }
                .searchable(text: $searchText, prompt: "Search sources")
                .onChange(of: searchText) { _ in resetPaging() }
                // Reset paging only when the dataset itself changes, not when
                // a new Watch sample arrives while you're reading older data.
                .onChange(of: sourceFilter) { _ in resetPaging() }
                .onChange(of: zoneFilter) { _ in resetPaging() }
                .onChange(of: onlyElevated) { _ in resetPaging() }
                .onChange(of: viewModel.mode) { _ in resetPaging() }
                .onChange(of: viewModel.selectedRange) { _ in resetPaging() }
                .onChange(of: viewModel.dailyStart) { _ in resetPaging() }
                .onChange(of: viewModel.dailyEnd) { _ in resetPaging() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.healthUnavailable {
            healthUnavailableState
        } else if currentSamples.isEmpty && !isPullRefreshing
                    // Only for the first load or a range switch: background
                    // refreshes keep the empty state (and its buttons) still.
                    && (viewModel.isFirstLoadPending || viewModel.isSwitchingRange
                        || viewModel.isSwitchingDailyRange) {
            // Scrollable so pull-to-refresh still works if loading stalls.
            GeometryReader { geo in
                ScrollView {
                    ProgressView("Loading heart rate…")
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
            .background(Color(.systemGroupedBackground))
        } else if currentSamples.isEmpty {
            // A scroll view (not a plain stack) so pull-to-refresh works here too.
            GeometryReader { geo in
                ScrollView {
                    emptyOrErrorState
                        .readableContentWidth(520)
                        .frame(minHeight: geo.size.height)
                }
            }
            .background(Color(.systemGroupedBackground))
        } else {
            list(filteredSamples)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !viewModel.healthUnavailable {
                rangeControl
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !viewModel.healthUnavailable && !currentSamples.isEmpty {
                filterMenu
            }
        }
    }

    // MARK: Data

    private var currentSamples: [HeartRateSample] {
        switch viewModel.mode {
        case .overall: return viewModel.samples
        case .daily:   return viewModel.dailySamples
        }
    }

    private var rangeDescription: String {
        switch viewModel.mode {
        case .overall:
            // The rows' range, which trails the menu while a switch loads or after it failed.
            return viewModel.loadedRange.fullTitle
        case .daily:
            // Same idea: describe the days the rows actually come from.
            let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            let start = viewModel.loadedDailyStart ?? viewModel.dailyStart
            let end = viewModel.loadedDailyEnd ?? viewModel.dailyEnd
            return "\(start.formatted(style)) – \(end.formatted(style))"
        }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The next longer range, offered when the current one has no data.
    private var longerRange: HeartRateViewModel.OverallRange? {
        guard viewModel.mode == .overall else { return nil }
        let all = HeartRateViewModel.OverallRange.allCases
        guard let i = all.firstIndex(of: viewModel.selectedRange), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    private var activeFilterCount: Int {
        (sourceFilter == nil ? 0 : 1) + (zoneFilter == nil ? 0 : 1) + (onlyElevated ? 1 : 0)
            + (trimmedSearch.isEmpty ? 0 : 1)
    }

    private var filterSummary: String {
        var parts: [String] = []
        if !trimmedSearch.isEmpty { parts.append("“\(trimmedSearch)”") }
        if let sourceFilter { parts.append(sourceFilter) }
        if let zoneFilter { parts.append(zoneFilter.label) }
        if onlyElevated { parts.append("≥ \(profile.elevatedThreshold) bpm") }
        return parts.joined(separator: " · ")
    }

    /// Newest first, with the source / zone / elevated filters applied.
    private var filteredSamples: [HeartRateSample] {
        var result = currentSamples
        if let sourceFilter {
            result = result.filter { $0.source == sourceFilter }
        }
        let query = trimmedSearch
        if !query.isEmpty {
            result = result.filter { $0.source.localizedCaseInsensitiveContains(query) }
        }
        if let zoneFilter {
            let maxHR = profile.maxHR
            result = result.filter { HeartRateZone(bpm: $0.bpm, maxHR: maxHR) == zoneFilter }
        }
        if onlyElevated {
            let t = Double(profile.elevatedThreshold)
            result = result.filter { $0.bpm.rounded() >= t }
        }
        return result.sorted { $0.date > $1.date }
    }

    /// Splits newest-first samples into days, newest day first. One linear
    /// pass: the calendar is only asked when the day changes.
    private func groupedByDay<S: Sequence>(_ samples: S) -> [(Date, [HeartRateSample])] where S.Element == HeartRateSample {
        let cal = Calendar.current
        var days: [(Date, [HeartRateSample])] = []
        var dayStart = Date.distantFuture
        for sample in samples {
            if sample.date < dayStart {
                dayStart = cal.startOfDay(for: sample.date)
                days.append((dayStart, []))
            }
            days[days.count - 1].1.append(sample)
        }
        return days
    }

    /// Per-day range / average over the whole filtered set (not just the
    /// visible page), so a day header is right even when its rows are paged.
    private func daySummaries(_ samples: [HeartRateSample]) -> [Date: BPMStats] {
        let cal = Calendar.current
        var out: [Date: BPMStats] = [:]
        var dayStart = Date.distantFuture
        for sample in samples {
            if sample.date < dayStart { dayStart = cal.startOfDay(for: sample.date) }
            out[dayStart, default: BPMStats()].add(sample.bpm)
        }
        return out
    }

    /// One summary per clock hour, newest first, for one day's samples.
    private func hourSummaries(_ samples: [HeartRateSample]) -> [HourSummary] {
        let cal = Calendar.current
        var hours: [HourSummary] = []
        var hourStart = Date.distantFuture
        for sample in samples {
            if sample.date < hourStart {
                hourStart = cal.dateInterval(of: .hour, for: sample.date)?.start ?? sample.date
                hours.append(HourSummary(start: hourStart))
            }
            hours[hours.count - 1].stats.add(sample.bpm)
        }
        return hours
    }

    // MARK: Actions

    private func pullToRefresh() async {
        guard !viewModel.healthUnavailable else { return }
        isPullRefreshing = true
        await viewModel.refresh()
        isPullRefreshing = false
    }

    private func resetPaging() {
        visibleLimit = Self.pageSize
    }

    private func clearFilters() {
        searchText = ""
        sourceFilter = nil
        zoneFilter = nil
        onlyElevated = false
    }

    private func openHealth() {
        if let url = URL(string: "x-apple-health://") {
            openURL(url)
        }
    }

    // MARK: Toolbar

    /// Changing the range here changes the Heart tab too (shared view model);
    /// the header footer says so.
    @ViewBuilder
    private var rangeControl: some View {
        switch viewModel.mode {
        case .overall:
            Menu {
                Picker("Range", selection: Binding(
                    get: { viewModel.selectedRange },
                    set: { range in
                        Haptics.selection()
                        Task { await viewModel.setOverallRange(range) }
                    }
                )) {
                    ForEach(HeartRateViewModel.OverallRange.allCases) { range in
                        Text(range.fullTitle).tag(range)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(viewModel.selectedRange.rawValue)
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
            .accessibilityLabel("Range")
            .accessibilityValue(viewModel.isLoading
                                ? "\(viewModel.selectedRange.fullTitle), loading"
                                : viewModel.selectedRange.fullTitle)
        case .daily:
            // The day range is picked on the Heart tab; this only shows it.
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(rangeDescription)
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Days \(rangeDescription), set on the Heart tab")
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $grouping) {
                ForEach(Grouping.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            Divider()

            // Tags must be exactly `String?` / `HeartRateZone?` to match the
            // selection, or picking an item silently does nothing.
            Picker("Source", selection: $sourceFilter) {
                Text("All Sources").tag(String?.none)
                ForEach(viewModel.sourceBreakdown) { source in
                    Label(source.name, systemImage: Self.sourceIcon(source.name))
                        .tag(Optional(source.name))
                }
                // Still selectable after a range change dropped that source.
                if let sourceFilter, !viewModel.sourceBreakdown.contains(where: { $0.name == sourceFilter }) {
                    Text(sourceFilter).tag(Optional(sourceFilter))
                }
            }
            .pickerStyle(.menu)

            Picker("Zone", selection: $zoneFilter) {
                Text("All Zones").tag(HeartRateZone?.none)
                ForEach(HeartRateZone.allCases) { zone in
                    Label(zone.label, systemImage: zone.systemImage)
                        .tag(Optional(zone))
                }
            }
            .pickerStyle(.menu)

            Toggle(isOn: $onlyElevated) {
                Label("Only ≥ \(profile.elevatedThreshold) bpm", systemImage: "exclamationmark.triangle")
            }

            if activeFilterCount > 0 {
                Divider()
                Button(action: clearFilters) {
                    Label("Clear Filters", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: activeFilterCount > 0
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter")
        .accessibilityValue(activeFilterCount == 0 ? "None" : "\(activeFilterCount) active")
    }

    private static func sourceIcon(_ name: String) -> String {
        name.localizedCaseInsensitiveContains("watch") ? "applewatch" : "iphone"
    }

    // MARK: List

    private func list(_ filtered: [HeartRateSample]) -> some View {
        let hourly = grouping == .hourly
        // Hourly rows are at most 24 a day, so they don't need paging.
        let visible = filtered.prefix(hourly ? filtered.count : visibleLimit)
        let days = groupedByDay(visible)
        let summaries = daySummaries(filtered)
        let total = summaries.values.reduce(into: BPMStats()) { $0.merge($1) }
        let maxHR = profile.maxHR
        let threshold = profile.elevatedThreshold
        return List {
            if let message = viewModel.errorMessage {
                Section {
                    InlineBanner(
                        message: message,
                        actionTitle: "Try Again",
                        action: { Task { await viewModel.refresh() } },
                        onDismiss: { viewModel.errorMessage = nil }
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            headerSection(count: filtered.count, total: total)
            if filtered.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No samples match the current filter.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Clear Filters", action: clearFilters)
                            .buttonStyle(.borderless)
                    }
                }
            }
            ForEach(days, id: \.0) { day, samples in
                Section {
                    if hourly {
                        ForEach(hourSummaries(samples)) { hour in
                            HourRow(
                                hour: hour,
                                zone: HeartRateZone(bpm: Double(hour.stats.avgBPM), maxHR: maxHR),
                                elevatedThreshold: threshold
                            )
                        }
                    } else {
                        ForEach(samples) { sample in
                            HistoryRow(
                                sample: sample,
                                zone: HeartRateZone(bpm: sample.bpm, maxHR: maxHR),
                                elevatedThreshold: threshold
                            )
                        }
                    }
                } header: {
                    dayHeader(day, stats: summaries[day])
                }
            }
            if filtered.count > visible.count {
                Section {
                    Button {
                        visibleLimit += Self.pageSize
                    } label: {
                        Label("Show older samples (\((filtered.count - visible.count).formatted()) more)", systemImage: "chevron.down")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func headerSection(count: Int, total: BPMStats) -> some View {
        let tiles = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return Section {
            if activeFilterCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(.pink)
                        .accessibilityHidden(true)
                    Text("Filtered: \(filterSummary)")
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    // Borderless, so only the button (not the whole row) is tappable.
                    Button("Clear", action: clearFilters)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
            tiles {
                miniStat(label: "Samples", spokenLabel: "Samples",
                         value: count.formatted(), spokenValue: count.formatted(), icon: "number")
                if total.count > 0 {
                    miniStat(label: "Min", spokenLabel: "Lowest",
                             value: "\(total.minBPM)", spokenValue: "\(total.minBPM) beats per minute",
                             icon: "arrow.down.heart")
                    miniStat(label: "Max", spokenLabel: "Highest",
                             value: "\(total.maxBPM)", spokenValue: "\(total.maxBPM) beats per minute",
                             icon: "arrow.up.heart")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        } footer: {
            switch viewModel.mode {
            case .overall:
                Text("\(rangeDescription) · changing the range here also changes the Heart tab.")
            case .daily:
                Text("\(rangeDescription), from the Heart tab’s “\(HeartRateViewModel.ReportMode.daily.rawValue)” view — change the days there.")
            }
        }
    }

    private func miniStat(label: String, spokenLabel: String, value: String, spokenValue: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .cardBackground(cornerRadius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(spokenValue)
    }

    private func dayHeader(_ day: Date, stats: BPMStats?) -> some View {
        let title = Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day())
            .font(.footnote.weight(.semibold))
        let detail = stats.map { s in
            Text("\(s.minBPM)–\(s.maxBPM) bpm · avg \(s.avgBPM) · \(s.count.formatted()) sample\(s.count == 1 ? "" : "s")")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                title
                Spacer(minLength: 8)
                detail
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                detail
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dayHeaderSpokenText(day, stats: stats))
        .accessibilityAddTraits(.isHeader)
    }

    private func dayHeaderSpokenText(_ day: Date, stats: BPMStats?) -> String {
        let date = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard let stats else { return date }
        let samples = "\(stats.count) sample\(stats.count == 1 ? "" : "s")"
        return "\(date), \(samples), \(stats.minBPM) to \(stats.maxBPM) beats per minute, average \(stats.avgBPM)"
    }

    // MARK: Empty / unavailable states

    @ViewBuilder
    private var emptyOrErrorState: some View {
        if let message = viewModel.errorMessage {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't Load Heart Rate",
                message: message
            ) {
                Button("Try Again") {
                    Task { await viewModel.refresh() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            EmptyStateView(
                systemImage: "heart.slash",
                title: "No Heart Rate Data",
                message: "Nothing recorded for \(rangeDescription)."
            ) {
                VStack(spacing: 12) {
                    Button("Refresh") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)

                    if let longer = longerRange {
                        Button("Show \(longer.fullTitle)") {
                            Haptics.selection()
                            Task { await viewModel.setOverallRange(longer) }
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Open Health", action: openHealth)
                        .buttonStyle(.bordered)

                    // HealthKit hides read denials, so "no access" looks
                    // exactly like "no data" — say both.
                    Text("Wear your Apple Watch, or check that MyHeart can read Heart Rate. \(HealthCopy.permissionPath) Health doesn't tell apps when access is off, so it looks the same as no data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
        }
    }

    /// iPad on iPadOS 16 has no Apple Health; following family still works.
    private var healthUnavailableState: some View {
        EmptyStateView(
            systemImage: "heart.slash",
            title: "Health data isn't available on this device",
            message: "You can still follow family members' live heart rate on the Family tab."
        ) {
            Button("Open Family") { router.openFamily() }
                .buttonStyle(.borderedProminent)
        }
        .readableContentWidth(520)
        .frame(maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Summaries

/// Running min / max / average for a group of samples.
private struct BPMStats {
    private(set) var low = Double.infinity
    private(set) var high = -Double.infinity
    private(set) var sum = 0.0
    private(set) var count = 0

    mutating func add(_ bpm: Double) {
        low = min(low, bpm)
        high = max(high, bpm)
        sum += bpm
        count += 1
    }

    mutating func merge(_ other: BPMStats) {
        guard other.count > 0 else { return }
        low = min(low, other.low)
        high = max(high, other.high)
        sum += other.sum
        count += other.count
    }

    var minBPM: Int { count > 0 ? Int(low.rounded()) : 0 }
    var maxBPM: Int { count > 0 ? Int(high.rounded()) : 0 }
    var avgBPM: Int { count > 0 ? Int((sum / Double(count)).rounded()) : 0 }
}

private struct HourSummary: Identifiable {
    let start: Date
    var stats = BPMStats()
    var id: Date { start }
}

// MARK: - Rows

private struct HistoryRow: View {
    let sample: HeartRateSample
    let zone: HeartRateZone
    let elevatedThreshold: Int

    @Environment(\.dynamicTypeSize) private var typeSize

    private var bpm: Int { Int(sample.bpm.rounded()) }
    // Same rounding as the "Only ≥ threshold" filter, so icon and filter agree.
    private var isElevated: Bool { bpm >= elevatedThreshold }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        time
                        Spacer(minLength: 8)
                        if isElevated { elevatedIcon }
                        bpmText
                    }
                    source
                    ZoneChip(zone: zone)
                }
            } else {
                HStack(spacing: 8) {
                    // The source gets its own line under time + zone, so long
                    // names ("Ismet's Apple Watch") have room before truncating.
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            time
                            ZoneChip(zone: zone)
                        }
                        source
                    }
                    Spacer(minLength: 8)
                    if isElevated { elevatedIcon }
                    bpmText
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenDescription)
    }

    private var time: some View {
        Text(sample.date, format: .dateTime.hour().minute())
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .fixedSize()
    }

    private var source: some View {
        Text(sample.source)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            .truncationMode(.middle)
    }

    private var elevatedIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.red)
    }

    private var bpmText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(bpm)")
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.pink)
            Text("BPM")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var spokenDescription: String {
        var parts = [
            sample.date.formatted(date: .omitted, time: .shortened),
            "\(bpm) beats per minute",
            "\(zone.label) zone",
        ]
        if isElevated { parts.append("above your elevated threshold") }
        parts.append("from \(sample.source)")
        return parts.joined(separator: ", ")
    }
}

/// One clock hour in the hourly summary: range, average and sample count.
private struct HourRow: View {
    let hour: HourSummary
    /// Zone of the hour's average.
    let zone: HeartRateZone
    let elevatedThreshold: Int

    @Environment(\.dynamicTypeSize) private var typeSize

    private var isElevated: Bool { hour.stats.maxBPM >= elevatedThreshold }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        time
                        Spacer(minLength: 8)
                        if isElevated { elevatedIcon }
                        rangeText
                    }
                    detail
                    ZoneChip(zone: zone)
                }
            } else {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            time
                            ZoneChip(zone: zone)
                        }
                        detail
                    }
                    Spacer(minLength: 8)
                    if isElevated { elevatedIcon }
                    rangeText
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenDescription)
    }

    private var time: some View {
        Text(hour.start, format: .dateTime.hour().minute())
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .fixedSize()
    }

    private var detail: some View {
        Text("avg \(hour.stats.avgBPM) · \(hour.stats.count.formatted()) sample\(hour.stats.count == 1 ? "" : "s")")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var elevatedIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.red)
    }

    private var rangeText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(hour.stats.minBPM)–\(hour.stats.maxBPM)")
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.pink)
            Text("BPM")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var spokenDescription: String {
        let end = hour.start.addingTimeInterval(3600)
        var parts = [
            "\(hour.start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))",
            "\(hour.stats.minBPM) to \(hour.stats.maxBPM) beats per minute",
            "average \(hour.stats.avgBPM)",
            "\(zone.label) zone",
        ]
        if isElevated { parts.append("reached your elevated threshold") }
        parts.append("\(hour.stats.count) sample\(hour.stats.count == 1 ? "" : "s")")
        return parts.joined(separator: ", ")
    }
}

#Preview {
    HistoryView()
        .environmentObject(HeartRateViewModel.preview)
        .environmentObject(UserProfile.shared)
        .environmentObject(AppRouter.shared)
}
