import Foundation
import SwiftUI
import Combine

@MainActor
final class HeartRateViewModel: ObservableObject {
    // Overall mode state
    @Published var samples: [HeartRateSample] = []
    @Published var summary: HeartRateSummary = .empty
    @Published var previousSummary: HeartRateSummary = .empty
    @Published var zoneBreakdown: ZoneBreakdown = .empty
    @Published var selectedRange: OverallRange = .day1

    // Daily mode state
    @Published var dailyStats: [DailyHeartRateStats] = []
    @Published var dailySamples: [HeartRateSample] = []
    @Published var dailyZones: [Date: ZoneBreakdown] = [:]
    @Published var dailyStart: Date
    @Published var dailyEnd: Date

    // Derived
    @Published var insights: [Insight] = []
    @Published var sourceBreakdown: [SourceSlice] = []

    // Shared
    @Published var mode: ReportMode = .overall
    @Published var isLoading: Bool = false
    @Published var authorizationError: String?
    @Published var lastRefresh: Date?

    static let maxDailyRangeDays = 31

    enum ReportMode: String, CaseIterable, Identifiable {
        case overall = "Overall"
        case daily = "Daily"
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
            case .day1: return "yesterday"
            case .week1: return "last week"
            case .month1: return "last month"
            case .month3: return "previous 3 months"
            case .month6: return "previous 6 months"
            }
        }
    }

    private let health: HealthKitManager
    private let calendar: Calendar
    private let profile: UserProfile
    private var profileCancellables: Set<AnyCancellable> = []

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

        // Re-derive zones + insights whenever the profile changes (age or max HR override).
        Publishers
            .CombineLatest3(profile.$age, profile.$maxHROverride, profile.$elevatedThreshold)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.recomputeDerived()
            }
            .store(in: &profileCancellables)
    }

    func bootstrap() async {
        do {
            try await health.requestAuthorization()
            await refresh()
        } catch {
            authorizationError = error.localizedDescription
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            switch mode {
            case .overall:
                try await refreshOverall()
            case .daily:
                try await refreshDaily()
            }
            lastRefresh = Date()
        } catch {
            authorizationError = error.localizedDescription
        }
    }

    func setMode(_ newMode: ReportMode) async {
        mode = newMode
        await refresh()
    }

    func setOverallRange(_ range: OverallRange) async {
        selectedRange = range
        await refresh()
    }

    func setDailyRange(start: Date, end: Date) async {
        let clampedStart = calendar.startOfDay(for: start)
        let clampedEnd = calendar.startOfDay(for: end)
        let (s, e) = Self.clampDailyRange(start: clampedStart, end: clampedEnd, calendar: calendar)
        dailyStart = s
        dailyEnd = e
        await refresh()
    }

    // MARK: - Fetching

    private func refreshOverall() async throws {
        let end = Date()
        let start = end.addingTimeInterval(-selectedRange.interval)
        let prevEnd = start
        let prevStart = prevEnd.addingTimeInterval(-selectedRange.interval)

        async let samplesTask = health.fetchHeartRateSamples(
            start: start, end: end, limit: HealthKitManager.noSampleLimit
        )
        async let prevSamplesTask = health.fetchHeartRateSamples(
            start: prevStart, end: prevEnd, limit: HealthKitManager.noSampleLimit
        )
        async let restingTask = health.fetchAverageResting(start: start, end: end)
        async let prevRestingTask = health.fetchAverageResting(start: prevStart, end: prevEnd)
        async let hrvTask = health.fetchAverageHRV(start: start, end: end)
        async let prevHrvTask = health.fetchAverageHRV(start: prevStart, end: prevEnd)
        async let latestRestingTask = health.fetchLatestRestingHeartRate()

        let fetched = try await samplesTask
        let prevFetched = try await prevSamplesTask
        let avgResting = try await restingTask
        let prevAvgResting = try await prevRestingTask
        let avgHrv = try await hrvTask
        let prevAvgHrv = try await prevHrvTask
        let latestResting = try await latestRestingTask

        samples = fetched
        // Prefer window-averaged resting when we have it, else fall back to the latest all-time value.
        summary = Self.buildSummary(
            samples: fetched,
            resting: avgResting ?? latestResting,
            hrv: avgHrv,
            start: start,
            end: end
        )
        previousSummary = Self.buildSummary(
            samples: prevFetched,
            resting: prevAvgResting,
            hrv: prevAvgHrv,
            start: prevStart,
            end: prevEnd
        )
        recomputeDerived()
        publishLiveStatusIfSharing()
    }

    /// Pushes the latest heart state into the live-sharing service.
    /// The service throttles/coalesces writes — call it often, it's cheap.
    /// Runs emergency evaluation and opportunistically refreshes the
    /// last-24h trend (capped to one fetch per 15 minutes).
    private func publishLiveStatusIfSharing() {
        let sharing = LiveSharingService.shared
        guard sharing.sharingEnabled else { return }
        guard let latest = summary.latest else { return }

        let maxHR = profile.maxHR
        let zone = HeartRateZone(bpm: latest.bpm, maxHR: maxHR)
        let bpm = Int(latest.bpm.rounded())

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Emergency evaluation. Uses last 15 min of samples for "sustained" detection.
            let recent = (try? await self.health.fetchRecentSamples(minutes: 15)) ?? self.samples
            let thresholds = EmergencyEvaluator.Thresholds(
                criticalHighBPM: self.profile.criticalHighBPM,
                criticalLowBPM: self.profile.criticalLowBPM,
                sustainedHighBPM: max(self.profile.elevatedThreshold, 120),
                sustainedMinutes: 10
            )
            let emergency = EmergencyEvaluator.evaluate(
                currentBPM: bpm,
                recent: recent,
                thresholds: thresholds
            )

            // Trend (hourly averages, last 24h) — refresh at most every 15 min.
            var trend: [Int] = sharing.lastPublishedStatus?.trendHourlyBPM ?? []
            var trendDate: Date? = sharing.lastPublishedStatus?.trendUpdatedAt
            let trendStale: Bool = {
                guard let trendDate else { return true }
                return Date().timeIntervalSince(trendDate) > 15 * 60
            }()
            if trendStale {
                if let fresh = try? await self.health.fetchLast24hHourlyHeartRate() {
                    trend = fresh
                    trendDate = Date()
                }
            }

            let status = LiveHeartStatus(
                id: CloudKitConfig.liveStatusRecordName,
                ownerID: nil,
                currentBPM: bpm,
                zoneRaw: zone.rawValue,
                restingBPM: self.summary.restingBPM.map { Int($0.rounded()) },
                hrvMs: self.summary.hrvSDNN,
                updatedAt: latest.date,
                isElevated: bpm >= self.profile.elevatedThreshold,
                elevatedThreshold: self.profile.elevatedThreshold,
                displayName: self.profile.displayName,
                deviceName: latest.source,
                maxHR: Int(maxHR.rounded()),
                note: nil,
                trendHourlyBPM: trend,
                trendUpdatedAt: trendDate,
                isEmergency: emergency.kind != nil,
                emergencyKind: emergency.kind,
                emergencySince: emergency.since
            )
            sharing.publish(status)
        }
    }

    private func refreshDaily() async throws {
        let end = calendar.date(byAdding: .day, value: 1, to: dailyEnd) ?? dailyEnd
        let start = dailyStart
        async let statsTask = health.fetchDailyStats(start: start, end: end, calendar: calendar)
        async let samplesTask = health.fetchHeartRateSamples(
            start: start, end: end, limit: HealthKitManager.noSampleLimit
        )
        dailyStats = try await statsTask
        dailySamples = try await samplesTask
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
            let byDay = Dictionary(grouping: dailySamples) { calendar.startOfDay(for: $0.date) }
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

    static func clampDailyRange(start: Date, end: Date, calendar: Calendar = .current) -> (Date, Date) {
        var s = start
        var e = end
        if e < s { swap(&s, &e) }
        let days = calendar.dateComponents([.day], from: s, to: e).day ?? 0
        if days >= maxDailyRangeDays {
            if let adjusted = calendar.date(byAdding: .day, value: maxDailyRangeDays - 1, to: s) {
                e = adjusted
            }
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
            latest: samples.last,
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
                    detail: "Now \(Int(current.rounded())) vs \(Int(prev.rounded())) \(selectedRange.previousTitle)",
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
                    icon: better ? "waveform.path.ecg" : "waveform.path.ecg",
                    title: "HRV \(better ? "up" : "down") \(Int(abs(delta).rounded())) ms",
                    detail: "\(Int(current.rounded())) ms vs \(Int(prev.rounded())) \(selectedRange.previousTitle)",
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
            let fmt = DateFormatter()
            fmt.dateFormat = selectedRange == .day1 ? "h:mm a" : "EEE h:mm a"
            out.append(Insight(
                icon: "bolt.heart.fill",
                title: "Peak \(Int(maxBpm.rounded())) bpm",
                detail: "on \(fmt.string(from: peakSample.date))",
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
            let fmt = DateFormatter()
            fmt.dateFormat = "EEEE"
            out.append(Insight(
                icon: "bed.double.fill",
                title: "Best recovery day",
                detail: "\(fmt.string(from: best.0)) — resting \(Int(best.1.rounded())) bpm",
                tint: .green
            ))
        }

        // Highest peak day
        if let highest = dailyStats.compactMap({ stat -> (Date, Double)? in
            guard let v = stat.maxBPM else { return nil }
            return (stat.day, v)
        }).max(by: { $0.1 < $1.1 }) {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEEE"
            out.append(Insight(
                icon: "bolt.heart.fill",
                title: "Hardest effort",
                detail: "\(fmt.string(from: highest.0)) — peak \(Int(highest.1.rounded())) bpm",
                tint: .pink
            ))
        }

        // Day with most active time
        if !dailyZones.isEmpty {
            let scored = dailyZones.map { (day, z) -> (Date, TimeInterval) in
                (day, z.duration(.fatBurn) + z.duration(.cardio) + z.duration(.peak))
            }
            if let top = scored.max(by: { $0.1 < $1.1 }), top.1 > 0 {
                let fmt = DateFormatter()
                fmt.dateFormat = "EEEE"
                out.append(Insight(
                    icon: "flame.fill",
                    title: "Most active day",
                    detail: "\(fmt.string(from: top.0)) — \(DurationFormat.compact(top.1)) active",
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
        return vm
    }
}
