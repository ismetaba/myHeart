import Foundation
import SwiftUI
import Combine
import UIKit

@MainActor
final class HeartRateViewModel: ObservableObject {
    // Overall mode state
    @Published var samples: [HeartRateSample] = []
    /// Pre-aggregated chart data for long ranges (empty when `samples` is small
    /// enough to plot directly).
    @Published var chartBuckets: [HeartRateBucket] = []
    @Published var summary: HeartRateSummary = .empty
    @Published var previousSummary: HeartRateSummary = .empty
    @Published var zoneBreakdown: ZoneBreakdown = .empty
    @Published var selectedRange: OverallRange = .day1
    /// The range `samples`, `summary` and the deltas were loaded for. Trails
    /// `selectedRange` while a switch is loading (or after it failed), so
    /// labels can describe the data actually on screen.
    @Published private(set) var loadedRange: OverallRange = .day1

    // Daily mode state
    @Published var dailyStats: [DailyHeartRateStats] = []
    @Published var dailySamples: [HeartRateSample] = []
    @Published var dailyZones: [Date: ZoneBreakdown] = [:]
    @Published var dailyStart: Date
    @Published var dailyEnd: Date
    /// The daily range `dailyStats` belong to; nil until the first daily load.
    @Published private(set) var loadedDailyStart: Date?
    @Published private(set) var loadedDailyEnd: Date?

    // Derived
    @Published var insights: [Insight] = []
    @Published var sourceBreakdown: [SourceSlice] = []

    // Shared
    @Published var mode: ReportMode = .overall
    @Published var isLoading: Bool = false
    /// Set only when HealthKit itself is unavailable / the request failed.
    @Published var authorizationError: String?
    /// Any other loading problem (shown inline, not as a blocking alert).
    @Published var errorMessage: String?
    @Published var lastRefresh: Date?
    /// HealthKit doesn't exist on this device (e.g. iPad on iPadOS 16).
    @Published private(set) var healthUnavailable = false

    /// Nothing has loaded yet — show placeholders / spinners, not "no data".
    var isFirstLoadPending: Bool {
        lastRefresh == nil && errorMessage == nil && authorizationError == nil && !healthUnavailable
    }

    /// A new overall range is loading while the previous range's data is
    /// still on screen. Plain refreshes of the same range don't count.
    var isSwitchingRange: Bool {
        isLoading && mode == .overall && loadedRange != selectedRange
    }

    /// Daily-mode counterpart of `isSwitchingRange`.
    var isSwitchingDailyRange: Bool {
        isLoading && mode == .daily && (loadedDailyStart != dailyStart || loadedDailyEnd != dailyEnd)
    }

    static let maxDailyRangeDays = 31
    /// Above this many samples the trend chart switches to aggregated buckets.
    static let rawChartLimit = 400
    static let chartBucketCount = 180

    /// Raw values are the segmented-control titles (display only, never stored).
    enum ReportMode: String, CaseIterable, Identifiable {
        case overall = "Trends"
        case daily = "By Day"
        var id: String { rawValue }
    }

    enum OverallRange: String, CaseIterable, Identifiable {
        case day1 = "1D"
        case week1 = "1W"
        case month1 = "1M"
        case month3 = "3M"
        case month6 = "6M"
        var id: String { rawValue }

        var interval: TimeInterval {
            switch self {
            case .day1: return 60 * 60 * 24
            case .week1: return 60 * 60 * 24 * 7
            case .month1: return 60 * 60 * 24 * 30
            case .month3: return 60 * 60 * 24 * 90
            case .month6: return 60 * 60 * 24 * 180
            }
        }

        var fullTitle: String {
            switch self {
            case .day1: return "Last 24 Hours"
            case .week1: return "Last 7 Days"
            case .month1: return "Last 30 Days"
            case .month3: return "Last 3 Months"
            case .month6: return "Last 6 Months"
            }
        }

        var shortTitle: String {
            switch self {
            case .day1: return "today"
            case .week1: return "this week"
            case .month1: return "this month"
            case .month3: return "3 months"
            case .month6: return "6 months"
            }
        }

        var previousTitle: String {
            switch self {
            case .day1: return "previous 24 hours"
            case .week1: return "previous 7 days"
            case .month1: return "previous 30 days"
            case .month3: return "previous 3 months"
            case .month6: return "previous 6 months"
            }
        }
    }

    private let health: HealthKitManager
    private let calendar: Calendar
    private let profile: UserProfile
    private var cancellables: Set<AnyCancellable> = []

    /// Bumped on every refresh so a slow, older refresh (e.g. 6M after the
    /// user already switched to 1D) can't overwrite newer results.
    private var generation = 0
    /// Foreground refreshes wait until HealthKit authorization was requested.
    private var hasBootstrapped = false

    init(
        health: HealthKitManager = .shared,
        calendar: Calendar = .current,
        profile: UserProfile? = nil
    ) {
        self.health = health
        self.calendar = calendar
        // Resolve inside the @MainActor init body so we never hit the
        // "static property accessed from a nonisolated context" warning.
        let profile = profile ?? UserProfile.shared
        self.profile = profile
        let today = calendar.startOfDay(for: Date())
        self.dailyEnd = today
        self.dailyStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today

        // Re-derive zones + insights (and republish the live status) whenever
        // the profile changes. Debounced so stepping the age stepper doesn't
        // trigger a burst of work; by the time it fires the new values are set.
        profile.objectWillChange
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.recomputeDerived()
                Task { @MainActor in await LiveStatusPublisher.shared.publishLatest() }
            }
            .store(in: &cancellables)

        // New heart-rate samples arrived in HealthKit (e.g. Apple Watch sync).
        NotificationCenter.default.publisher(for: .heartRateDataDidChange)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.handleNewHealthData() }
            }
            .store(in: &cancellables)
    }

    func bootstrap() async {
        do {
            try await health.requestAuthorization()
        } catch HealthKitError.notAvailable {
            // Not an error the user can fix — screens explain it inline.
            healthUnavailable = true
            return
        } catch {
            authorizationError = error.localizedDescription
            return
        }
        hasBootstrapped = true
        await LiveStatusPublisher.shared.start()
        await refresh()
    }

    func refresh() async {
        generation += 1
        let myGeneration = generation
        isLoading = true
        defer { if myGeneration == generation { isLoading = false } }

        do {
            switch mode {
            case .overall:
                try await refreshOverall(generation: myGeneration)
            case .daily:
                try await refreshDaily(generation: myGeneration)
            }
            guard myGeneration == generation else { return }
            lastRefresh = Date()
            errorMessage = nil
        } catch {
            guard myGeneration == generation else { return }
            // Locked phone → HealthKit is unreadable for a moment. Not an error
            // worth showing; the next foreground refresh will succeed.
            if HealthKitError.isProtectedDataUnavailable(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Foreground refresh, skipped when the data is still recent.
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        guard hasBootstrapped, !isLoading else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        await refresh()
    }

    private func handleNewHealthData() async {
        guard UIApplication.shared.applicationState == .active else { return }
        await refreshIfStale(maxAge: 20)
    }

    func setMode(_ newMode: ReportMode) async {
        guard newMode != mode else { return }
        mode = newMode
        await refresh()
    }

    func setOverallRange(_ range: OverallRange) async {
        guard range != selectedRange else { return }
        selectedRange = range
        await refresh()
    }

    func setDailyRange(start: Date, end: Date) async {
        let (s, e) = Self.clampDailyRange(start: start, end: end, calendar: calendar)
        guard s != dailyStart || e != dailyEnd else { return }
        dailyStart = s
        dailyEnd = e
        await refresh()
    }

    // MARK: - Fetching

    private func refreshOverall(generation myGeneration: Int) async throws {
        let range = selectedRange
        let end = Date()
        let start = end.addingTimeInterval(-range.interval)
        let prevEnd = start
        let prevStart = prevEnd.addingTimeInterval(-range.interval)

        async let samplesTask = health.fetchHeartRateSamples(
            start: start, end: end, limit: HealthKitManager.noSampleLimit
        )
        // The previous period only feeds the deltas, so use HealthKit's
        // statistics instead of loading every sample a second time.
        async let prevStatsTask = health.fetchHeartRateStatistics(start: prevStart, end: prevEnd)
        async let restingTask = health.fetchAverageResting(start: start, end: end)
        async let prevRestingTask = health.fetchAverageResting(start: prevStart, end: prevEnd)
        async let hrvTask = health.fetchAverageHRV(start: start, end: end)
        async let prevHrvTask = health.fetchAverageHRV(start: prevStart, end: prevEnd)
        async let latestRestingTask = health.fetchLatestRestingHeartRate()

        let fetched = try await samplesTask
        // Secondary metrics are optional: a user without HRV / resting data
        // must still get a working dashboard.
        let prevStats = try? await prevStatsTask
        let avgResting = try? await restingTask
        let prevAvgResting = try? await prevRestingTask
        let avgHrv = try? await hrvTask
        let prevAvgHrv = try? await prevHrvTask
        let latestResting = try? await latestRestingTask

        guard myGeneration == generation else { return }

        loadedRange = range
        samples = fetched
        chartBuckets = fetched.count > Self.rawChartLimit
            ? HeartRateBucket.make(from: fetched, start: start, end: end, maxBuckets: Self.chartBucketCount)
            : []
        // Prefer window-averaged resting when we have it, else fall back to the latest all-time value.
        summary = Self.buildSummary(
            samples: fetched,
            resting: avgResting ?? latestResting,
            hrv: avgHrv,
            start: start,
            end: end
        )
        previousSummary = HeartRateSummary(
            latest: nil,
            restingBPM: prevAvgResting,
            averageBPM: prevStats?.average,
            minBPM: prevStats?.min,
            maxBPM: prevStats?.max,
            hrvSDNN: prevAvgHrv,
            sampleCount: 0,
            rangeStart: prevStart,
            rangeEnd: prevEnd
        )
        recomputeDerived()
    }

    private func refreshDaily(generation myGeneration: Int) async throws {
        let start = dailyStart
        let lastDay = dailyEnd
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        async let statsTask = health.fetchDailyStats(start: start, end: end, calendar: calendar)
        async let samplesTask = health.fetchHeartRateSamples(
            start: start, end: end, limit: HealthKitManager.noSampleLimit
        )
        let stats = try await statsTask
        let fetchedSamples = try await samplesTask
        guard myGeneration == generation else { return }

        let cal = calendar
        let countsByDay = Dictionary(grouping: fetchedSamples) { cal.startOfDay(for: $0.date) }
            .mapValues { $0.count }
        dailyStats = stats.map { day in
            DailyHeartRateStats(
                id: day.id,
                day: day.day,
                minBPM: day.minBPM,
                avgBPM: day.avgBPM,
                maxBPM: day.maxBPM,
                restingBPM: day.restingBPM,
                sampleCount: countsByDay[day.day] ?? 0
            )
        }
        dailySamples = fetchedSamples
        loadedDailyStart = start
        loadedDailyEnd = lastDay
        recomputeDerived()
    }

    /// Re-runs zone analysis + insights from the already-fetched samples.
    /// Called when the user changes their profile (no HK re-fetch needed).
    func recomputeDerived() {
        let maxHR = profile.maxHR
        switch mode {
        case .overall:
            zoneBreakdown = HeartRateZoneAnalyzer.breakdown(samples: samples, maxHR: maxHR)
            sourceBreakdown = Self.buildSourceBreakdown(from: samples)
            insights = buildOverallInsights(maxHR: maxHR)
        case .daily:
            let cal = calendar
            let byDay = Dictionary(grouping: dailySamples) { cal.startOfDay(for: $0.date) }
            var zones: [Date: ZoneBreakdown] = [:]
            for (day, samples) in byDay {
                zones[day] = HeartRateZoneAnalyzer.breakdown(samples: samples, maxHR: maxHR)
            }
            dailyZones = zones
            sourceBreakdown = Self.buildSourceBreakdown(from: dailySamples)
            insights = buildDailyInsights(maxHR: maxHR)
        }
    }

    // MARK: - Helpers

    /// Normalizes a user-picked range: whole days, never in the future, start
    /// before end, and at most `maxDailyRangeDays` long (keeping the most
    /// recent days when trimming).
    static func clampDailyRange(start: Date, end: Date, calendar: Calendar = .current) -> (Date, Date) {
        let today = calendar.startOfDay(for: Date())
        var s = min(calendar.startOfDay(for: start), today)
        var e = min(calendar.startOfDay(for: end), today)
        if e < s { swap(&s, &e) }
        let days = calendar.dateComponents([.day], from: s, to: e).day ?? 0
        if days >= maxDailyRangeDays,
           let adjusted = calendar.date(byAdding: .day, value: -(maxDailyRangeDays - 1), to: e) {
            s = adjusted
        }
        return (s, e)
    }

    static func buildSummary(
        samples: [HeartRateSample],
        resting: Double?,
        hrv: Double?,
        start: Date,
        end: Date
    ) -> HeartRateSummary {
        let bpms = samples.map(\.bpm)
        let avg = bpms.isEmpty ? nil : bpms.reduce(0, +) / Double(bpms.count)
        return HeartRateSummary(
            latest: samples.max { $0.date < $1.date },
            restingBPM: resting,
            averageBPM: avg,
            minBPM: bpms.min(),
            maxBPM: bpms.max(),
            hrvSDNN: hrv,
            sampleCount: samples.count,
            rangeStart: start,
            rangeEnd: end
        )
    }

    static func buildSourceBreakdown(from samples: [HeartRateSample]) -> [SourceSlice] {
        guard !samples.isEmpty else { return [] }
        let grouped = Dictionary(grouping: samples, by: \.source)
        let total = Double(samples.count)
        return grouped
            .map { SourceSlice(name: $0.key, count: $0.value.count, fraction: Double($0.value.count) / total) }
            .sorted { $0.count > $1.count }
    }

    var dailyAverageOfAverages: Double? {
        let vals = dailyStats.compactMap(\.avgBPM)
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// `fetchDailyStats` returns an entry for every day, even days without
    /// samples, so `dailyStats.isEmpty` doesn't mean "no data".
    var hasDailyData: Bool { dailyStats.contains { $0.avgBPM != nil } }
    var daysWithData: Int { dailyStats.filter { $0.avgBPM != nil }.count }

    var dailyOverallMin: Double? { dailyStats.compactMap(\.minBPM).min() }
    var dailyOverallMax: Double? { dailyStats.compactMap(\.maxBPM).max() }
    var dailyOverallResting: Double? {
        let vals = dailyStats.compactMap(\.restingBPM)
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: - Trend deltas

    var restingDelta: TrendDelta { TrendDelta(current: summary.restingBPM, previous: previousSummary.restingBPM, lowerIsBetter: true) }
    var averageDelta: TrendDelta { TrendDelta(current: summary.averageBPM, previous: previousSummary.averageBPM, lowerIsBetter: nil) }
    var hrvDelta: TrendDelta { TrendDelta(current: summary.hrvSDNN, previous: previousSummary.hrvSDNN, lowerIsBetter: false) }
    var minDelta: TrendDelta { TrendDelta(current: summary.minBPM, previous: previousSummary.minBPM, lowerIsBetter: nil) }
    var maxDelta: TrendDelta { TrendDelta(current: summary.maxBPM, previous: previousSummary.maxBPM, lowerIsBetter: nil) }

    // MARK: - Insights

    private func buildOverallInsights(maxHR: Double) -> [Insight] {
        var out: [Insight] = []

        // Resting trend
        if let current = summary.restingBPM, let prev = previousSummary.restingBPM {
            let delta = current - prev
            if abs(delta) >= 1 {
                let better = delta < 0
                out.append(Insight(
                    icon: better ? "arrow.down.circle.fill" : "arrow.up.circle.fill",
                    title: "Resting HR \(better ? "improved" : "rose") \(Int(abs(delta).rounded())) bpm",
                    detail: "Now \(Int(current.rounded())) vs \(Int(prev.rounded())) \(loadedRange.previousTitle)",
                    tint: better ? .green : .orange
                ))
            }
        }

        // HRV trend
        if let current = summary.hrvSDNN, let prev = previousSummary.hrvSDNN {
            let delta = current - prev
            if abs(delta) >= 2 {
                let better = delta > 0
                out.append(Insight(
                    icon: "waveform.path.ecg",
                    title: "HRV \(better ? "up" : "down") \(Int(abs(delta).rounded())) ms",
                    detail: "\(Int(current.rounded())) ms vs \(Int(prev.rounded())) \(loadedRange.previousTitle)",
                    tint: better ? .green : .orange
                ))
            }
        }

        // Dominant zone
        if zoneBreakdown.totalDuration > 0, let dom = zoneBreakdown.dominantZone {
            let duration = zoneBreakdown.duration(dom)
            let pct = zoneBreakdown.fraction(dom)
            out.append(Insight(
                icon: dom.systemImage,
                title: "Mostly in \(dom.label)",
                detail: "\(DurationFormat.compact(duration)) (\(Int(pct * 100))%)",
                tint: .zone(dom)
            ))
        }

        // Time in moderate+ (fat burn, cardio, peak combined)
        let activeSeconds = zoneBreakdown.duration(.fatBurn)
            + zoneBreakdown.duration(.cardio)
            + zoneBreakdown.duration(.peak)
        if activeSeconds > 300 {  // > 5 min
            out.append(Insight(
                icon: "flame.fill",
                title: "Active time",
                detail: "\(DurationFormat.compact(activeSeconds)) in fat burn or higher zones",
                tint: .orange
            ))
        }

        // Peak HR in window
        if let maxBpm = summary.maxBPM, let peakSample = samples.max(by: { $0.bpm < $1.bpm }) {
            let style: Date.FormatStyle = loadedRange == .day1
                ? .dateTime.hour().minute()
                : .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
            out.append(Insight(
                icon: "bolt.heart.fill",
                title: "Peak \(Int(maxBpm.rounded())) bpm",
                detail: "at \(peakSample.date.formatted(style))",
                tint: .pink
            ))
        }

        // Elevated HR (samples above threshold, outside context)
        let elevatedThreshold = Double(profile.elevatedThreshold)
        let elevatedSamples = samples.filter { $0.bpm >= elevatedThreshold }
        if !elevatedSamples.isEmpty, samples.count > 10 {
            let pct = Double(elevatedSamples.count) / Double(samples.count)
            if pct >= 0.05 {
                out.append(Insight(
                    icon: "exclamationmark.triangle.fill",
                    title: "\(Int((pct * 100).rounded()))% above \(Int(elevatedThreshold)) bpm",
                    detail: "\(elevatedSamples.count) of \(samples.count) samples in range",
                    tint: .red
                ))
            }
        }

        return Array(out.prefix(4))
    }

    private func buildDailyInsights(maxHR: Double) -> [Insight] {
        var out: [Insight] = []
        guard !dailyStats.isEmpty else { return out }

        // Lowest resting day
        if let best = dailyStats.compactMap({ stat -> (Date, Double)? in
            guard let v = stat.restingBPM else { return nil }
            return (stat.day, v)
        }).min(by: { $0.1 < $1.1 }) {
            out.append(Insight(
                icon: "bed.double.fill",
                title: "Best recovery day",
                detail: "\(Self.dayLabel(best.0)) — resting \(Int(best.1.rounded())) bpm",
                tint: .green
            ))
        }

        // Highest peak day
        if let highest = dailyStats.compactMap({ stat -> (Date, Double)? in
            guard let v = stat.maxBPM else { return nil }
            return (stat.day, v)
        }).max(by: { $0.1 < $1.1 }) {
            out.append(Insight(
                icon: "bolt.heart.fill",
                title: "Hardest effort",
                detail: "\(Self.dayLabel(highest.0)) — peak \(Int(highest.1.rounded())) bpm",
                tint: .pink
            ))
        }

        // Day with most active time
        if !dailyZones.isEmpty {
            let scored = dailyZones.map { (day, z) -> (Date, TimeInterval) in
                (day, z.duration(.fatBurn) + z.duration(.cardio) + z.duration(.peak))
            }
            if let top = scored.max(by: { $0.1 < $1.1 }), top.1 > 0 {
                out.append(Insight(
                    icon: "flame.fill",
                    title: "Most active day",
                    detail: "\(Self.dayLabel(top.0)) — \(DurationFormat.compact(top.1)) active",
                    tint: .orange
                ))
            }
        }

        // Resting HR stability / trend across the range
        let restings = dailyStats.compactMap(\.restingBPM)
        if restings.count >= 3 {
            let first = restings.prefix(restings.count / 2).reduce(0, +) / Double(restings.count / 2)
            let second = restings.suffix(restings.count / 2).reduce(0, +) / Double(restings.count / 2)
            let diff = second - first
            if abs(diff) >= 1.5 {
                let better = diff < 0
                out.append(Insight(
                    icon: better ? "arrow.down.circle.fill" : "arrow.up.circle.fill",
                    title: "Resting HR trending \(better ? "down" : "up")",
                    detail: "\(Int(first.rounded())) → \(Int(second.rounded())) bpm across the range",
                    tint: better ? .green : .orange
                ))
            }
        }

        return Array(out.prefix(4))
    }

    private static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

// MARK: - Preview data

extension HeartRateViewModel {
    static var preview: HeartRateViewModel {
        let vm = HeartRateViewModel()
        let now = Date()
        let cal = Calendar.current
        let fake = (0..<80).map { i in
            HeartRateSample(
                bpm: Double(55 + Int.random(in: 0...55)),
                date: now.addingTimeInterval(-Double(i) * 900),
                source: i.isMultiple(of: 3) ? "Preview Watch" : "Preview iPhone"
            )
        }
        vm.samples = fake
        vm.summary = HeartRateViewModel.buildSummary(
            samples: fake,
            resting: 58,
            hrv: 46,
            start: now.addingTimeInterval(-86400),
            end: now
        )
        vm.previousSummary = HeartRateViewModel.buildSummary(
            samples: [],
            resting: 60,
            hrv: 43,
            start: now.addingTimeInterval(-2 * 86400),
            end: now.addingTimeInterval(-86400)
        )
        vm.dailyStats = (0..<7).map { i in
            let day = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: now))!
            return DailyHeartRateStats(
                day: day,
                minBPM: Double(52 + Int.random(in: 0...5)),
                avgBPM: Double(70 + Int.random(in: 0...10)),
                maxBPM: Double(110 + Int.random(in: 0...40)),
                restingBPM: Double(56 + Int.random(in: 0...6)),
                sampleCount: Int.random(in: 100...400)
            )
        }.reversed()
        vm.dailySamples = (0..<7).flatMap { i -> [HeartRateSample] in
            let dayStart = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: now))!
            return (0..<48).map { s in
                HeartRateSample(
                    bpm: Double(55 + Int.random(in: 0...60)),
                    date: dayStart.addingTimeInterval(Double(s) * 1800),
                    source: "Preview Watch"
                )
            }
        }
        vm.recomputeDerived()
        // Otherwise `isFirstLoadPending` shows the preview as placeholders.
        vm.lastRefresh = now
        return vm
    }
}
