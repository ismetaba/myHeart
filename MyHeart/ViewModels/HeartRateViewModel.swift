import Foundation
import SwiftUI

@MainActor
final class HeartRateViewModel: ObservableObject {
    // Overall mode state
    @Published var samples: [HeartRateSample] = []
    @Published var summary: HeartRateSummary = .empty
    @Published var selectedRange: OverallRange = .day1

    // Daily mode state
    @Published var dailyStats: [DailyHeartRateStats] = []
    @Published var dailySamples: [HeartRateSample] = []
    @Published var dailyStart: Date
    @Published var dailyEnd: Date

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
    }

    private let health: HealthKitManager
    private let calendar: Calendar

    init(health: HealthKitManager = .shared, calendar: Calendar = .current) {
        self.health = health
        self.calendar = calendar
        let today = calendar.startOfDay(for: Date())
        self.dailyEnd = today
        self.dailyStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
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

        async let samplesTask = health.fetchHeartRateSamples(start: start, end: end)
        async let restingTask = health.fetchLatestRestingHeartRate()
        async let hrvTask = health.fetchLatestHRV()

        let fetchedSamples = try await samplesTask
        let resting = try await restingTask
        let hrv = try await hrvTask

        samples = fetchedSamples
        summary = Self.buildSummary(
            samples: fetchedSamples,
            resting: resting,
            hrv: hrv,
            start: start,
            end: end
        )
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
}

extension HeartRateViewModel {
    static var preview: HeartRateViewModel {
        let vm = HeartRateViewModel()
        let now = Date()
        let fake = (0..<80).map { i in
            HeartRateSample(
                bpm: Double(55 + Int.random(in: 0...55)),
                date: now.addingTimeInterval(-Double(i) * 900),
                source: "Preview Watch"
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
        vm.dailyStats = (0..<7).map { i in
            let day = Calendar.current.date(byAdding: .day, value: -i, to: Calendar.current.startOfDay(for: now))!
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
            let dayStart = Calendar.current.date(byAdding: .day, value: -i, to: Calendar.current.startOfDay(for: now))!
            return (0..<48).map { s in
                HeartRateSample(
                    bpm: Double(55 + Int.random(in: 0...60)),
                    date: dayStart.addingTimeInterval(Double(s) * 1800),
                    source: "Preview Watch"
                )
            }
        }
        return vm
    }
}
