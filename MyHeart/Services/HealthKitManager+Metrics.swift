import Foundation
import HealthKit

// MARK: - Generic metric fetchers & helpers

extension HealthKitManager {
    /// Cumulative total (e.g. steps, energy) between two dates.
    func fetchCumulative(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, error in
                if let error {
                    if HealthKitError.isNoData(error) {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Average of discrete samples (e.g. SpO2, resp rate).
    func fetchDiscreteAverage(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, stats, error in
                if let error {
                    if HealthKitError.isNoData(error) {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Most recent single sample (e.g. body weight).
    func fetchMostRecent(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async throws -> (value: Double, date: Date)? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: sort
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error); return
                }
                guard let sample = (results as? [HKQuantitySample])?.first else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: (sample.quantity.doubleValue(for: unit), sample.endDate))
            }
            store.execute(query)
        }
    }

    /// Hourly sums for a single day — used for bar charts (steps per hour, energy per hour).
    func fetchHourlySums(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        day: Date,
        calendar: Calendar = .current
    ) async throws -> [MetricPoint] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: DateComponents(hour: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error { cont.resume(throwing: error); return }
                if let collection { cont.resume(returning: collection) }
                else { cont.resume(throwing: HealthKitError.typeUnavailable) }
            }
            store.execute(query)
        }

        var points: [MetricPoint] = []
        collection.enumerateStatistics(from: start, to: end) { stat, _ in
            let v = stat.sumQuantity()?.doubleValue(for: unit) ?? 0
            points.append(MetricPoint(date: stat.startDate, value: v))
        }
        return points
    }

    /// Daily aggregate series for N days ending today.
    /// Cumulative metrics (steps, energy) report 0 for empty days; discrete
    /// metrics (weight, resting HR, HRV) skip days without a sample so charts
    /// don't plunge to zero between measurements.
    func fetchDailySeries(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        days: Int,
        options: HKStatisticsOptions,
        calendar: Calendar = .current
    ) async throws -> [MetricPoint] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
        let today = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let start = calendar.date(byAdding: .day, value: -days + 1, to: today) ?? today
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: start,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error { cont.resume(throwing: error); return }
                if let collection { cont.resume(returning: collection) }
                else { cont.resume(throwing: HealthKitError.typeUnavailable) }
            }
            store.execute(query)
        }

        let isCumulative = options.contains(.cumulativeSum)
        var points: [MetricPoint] = []
        collection.enumerateStatistics(from: start, to: end) { stat, _ in
            let value: Double?
            if isCumulative {
                value = stat.sumQuantity()?.doubleValue(for: unit)
            } else if options.contains(.discreteAverage) {
                value = stat.averageQuantity()?.doubleValue(for: unit)
            } else if options.contains(.discreteMin) {
                value = stat.minimumQuantity()?.doubleValue(for: unit)
            } else if options.contains(.discreteMax) {
                value = stat.maximumQuantity()?.doubleValue(for: unit)
            } else {
                value = nil
            }
            if let value {
                points.append(MetricPoint(date: stat.startDate, value: value))
            } else if isCumulative {
                points.append(MetricPoint(date: stat.startDate, value: 0))
            }
        }
        return points
    }

    // MARK: - Activity summary (rings)

    func fetchTodayActivitySummary(calendar: Calendar = .current) async throws -> HKActivitySummary? {
        let today = calendar.dateComponents([.year, .month, .day, .era, .calendar], from: Date())
        let predicate = HKQuery.predicateForActivitySummary(with: today)
        return try await withCheckedThrowingContinuation { cont in
            let query = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: summaries?.first)
            }
            store.execute(query)
        }
    }

    // MARK: - Sleep

    /// Fetches the most recent sleep "night": sleep samples overlapping the
    /// last 24 hours, clipped to that window. Returns a phase breakdown.
    ///
    /// iPhone (Sleep Schedule), Apple Watch and third-party apps can all
    /// record the same night. Adding them together double-counts sleep, so we
    /// keep only the single source with the most recorded sleep (ties go to
    /// the one with stage data, i.e. the Watch).
    func fetchLastNightSleep(calendar: Calendar = .current) async throws -> SleepSummary? {
        let now = Date()
        let start = calendar.date(byAdding: .hour, value: -24, to: now) ?? now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sort
            ) { _, results, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }

        guard !samples.isEmpty else { return nil }

        let stagedValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let asleepValues: Set<Int> = stagedValues.union([HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue])

        func clippedDuration(_ sample: HKCategorySample) -> TimeInterval {
            let s = max(sample.startDate, start)
            let e = min(sample.endDate, now)
            return max(0, e.timeIntervalSince(s))
        }

        // Pick the primary source.
        let bySource = Dictionary(grouping: samples) { $0.sourceRevision.source.bundleIdentifier }
        let primary = bySource.max { lhs, rhs in
            func score(_ list: [HKCategorySample]) -> (TimeInterval, Bool, TimeInterval) {
                let asleep = list.filter { asleepValues.contains($0.value) }.reduce(0.0) { $0 + clippedDuration($1) }
                let staged = list.contains { stagedValues.contains($0.value) }
                let total = list.reduce(0.0) { $0 + clippedDuration($1) }
                return (asleep, staged, total)
            }
            let l = score(lhs.value), r = score(rhs.value)
            if l.0 != r.0 { return l.0 < r.0 }
            if l.1 != r.1 { return !l.1 && r.1 }
            return l.2 < r.2
        }?.value ?? samples

        var inBed: TimeInterval = 0
        var core: TimeInterval = 0
        var deep: TimeInterval = 0
        var rem: TimeInterval = 0
        var awake: TimeInterval = 0
        var asleepUnspecified: TimeInterval = 0

        var bedtime: Date? = nil
        var wakeTime: Date? = nil
        var inBedStart: Date? = nil
        var inBedEnd: Date? = nil

        for sample in primary {
            let duration = clippedDuration(sample)
            guard duration > 0 else { continue }
            let sampleStart = max(sample.startDate, start)
            let sampleEnd = min(sample.endDate, now)
            switch sample.value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                inBed += duration
                inBedStart = min(inBedStart ?? sampleStart, sampleStart)
                inBedEnd = max(inBedEnd ?? sampleEnd, sampleEnd)
                continue
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                core += duration
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                deep += duration
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                rem += duration
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                asleepUnspecified += duration
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                awake += duration
                continue
            default:
                continue
            }
            bedtime = min(bedtime ?? sampleStart, sampleStart)
            wakeTime = max(wakeTime ?? sampleEnd, sampleEnd)
        }

        let asleep = core + deep + rem + asleepUnspecified
        guard asleep > 0 || inBed > 0 else { return nil }

        return SleepSummary(
            night: bedtime ?? inBedStart ?? primary.first?.startDate ?? now,
            inBed: inBed > 0 ? max(inBed, asleep) : (asleep + awake),
            asleep: asleep,
            core: core,
            deep: deep,
            rem: rem,
            awake: awake,
            unspecified: asleepUnspecified,
            bedtime: bedtime ?? inBedStart,
            wakeTime: wakeTime ?? inBedEnd
        )
    }

    // MARK: - Last-24h hourly heart-rate averages (for trend sharing)

    /// 24 values, oldest → newest, one per clock hour. The last value is the
    /// current (partial) hour. 0 means "no data that hour".
    func fetchLast24hHourlyHeartRate(calendar: Calendar = .current) async throws -> [Int] {
        let now = Date()
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let anchor = calendar.date(byAdding: .hour, value: -23, to: currentHour) ?? currentHour
        let start = anchor
        let end = now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType.quantityType(forIdentifier: .heartRate)!,
                quantitySamplePredicate: predicate,
                options: .discreteAverage,
                anchorDate: anchor,
                intervalComponents: DateComponents(hour: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error { cont.resume(throwing: error); return }
                if let collection { cont.resume(returning: collection) }
                else { cont.resume(throwing: HealthKitError.typeUnavailable) }
            }
            store.execute(query)
        }

        let unit = HKUnit.count().unitDivided(by: .minute())
        var result = [Int](repeating: 0, count: 24)
        collection.enumerateStatistics(from: start, to: end) { stat, _ in
            let index = Int((stat.startDate.timeIntervalSince(anchor) / 3600).rounded())
            guard (0..<24).contains(index) else { return }
            let v = stat.averageQuantity()?.doubleValue(for: unit) ?? 0
            result[index] = Int(v.rounded())
        }
        return result
    }

    // MARK: - Mindfulness

    func fetchTodayMindfulness(calendar: Calendar = .current) async throws -> (minutes: Double, sessions: Int) {
        guard let type = HKCategoryType.categoryType(forIdentifier: .mindfulSession) else { return (0, 0) }
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
        let totalSec = samples.reduce(into: 0.0) { acc, s in
            acc += s.endDate.timeIntervalSince(s.startDate)
        }
        return (totalSec / 60.0, samples.count)
    }
}

// MARK: - Supporting types

/// A single (date, value) point used by charts and daily series.
struct MetricPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let value: Double
}

struct SleepSummary: Hashable {
    let night: Date
    let inBed: TimeInterval
    let asleep: TimeInterval
    let core: TimeInterval
    let deep: TimeInterval
    let rem: TimeInterval
    let awake: TimeInterval
    /// "Asleep" without stage detail (older watches, iPhone-only trackers).
    var unspecified: TimeInterval = 0
    let bedtime: Date?
    let wakeTime: Date?

    var efficiencyPercent: Double? {
        guard inBed > 0, asleep > 0 else { return nil }
        return min(1, asleep / inBed)
    }

    /// Only "in bed" time was recorded (e.g. iPhone Sleep Schedule, no Watch).
    var isInBedOnly: Bool { asleep <= 0 }

    var hasStages: Bool { core + deep + rem > 0 }

    var totalSeconds: TimeInterval { asleep > 0 ? asleep : inBed }
}
