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
                    continuation.resume(throwing: error); return
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
                    continuation.resume(throwing: error); return
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

        var points: [MetricPoint] = []
        collection.enumerateStatistics(from: start, to: end) { stat, _ in
            let value: Double?
            if options.contains(.cumulativeSum) {
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
            points.append(MetricPoint(date: stat.startDate, value: value ?? 0))
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

    /// Fetches the most recent sleep "night", defined as any sleep samples whose
    /// endDate is within the last 24 hours. Returns a phase breakdown.
    func fetchLastNightSleep(calendar: Calendar = .current) async throws -> SleepSummary? {
        let now = Date()
        // Look back 24h for sleep samples.
        let start = calendar.date(byAdding: .hour, value: -24, to: now) ?? now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]

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

        var inBed: TimeInterval = 0
        var core: TimeInterval = 0
        var deep: TimeInterval = 0
        var rem: TimeInterval = 0
        var awake: TimeInterval = 0
        var asleepUnspecified: TimeInterval = 0

        var bedtime: Date? = nil
        var wakeTime: Date? = nil

        for sample in samples {
            let duration = sample.endDate.timeIntervalSince(sample.startDate)
            let raw = sample.value
            switch raw {
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                inBed += duration
                bedtime = min(bedtime ?? sample.startDate, sample.startDate)
                wakeTime = max(wakeTime ?? sample.endDate, sample.endDate)
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                core += duration
                bedtime = min(bedtime ?? sample.startDate, sample.startDate)
                wakeTime = max(wakeTime ?? sample.endDate, sample.endDate)
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                deep += duration
                bedtime = min(bedtime ?? sample.startDate, sample.startDate)
                wakeTime = max(wakeTime ?? sample.endDate, sample.endDate)
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                rem += duration
                bedtime = min(bedtime ?? sample.startDate, sample.startDate)
                wakeTime = max(wakeTime ?? sample.endDate, sample.endDate)
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                awake += duration
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                asleepUnspecified += duration
                bedtime = min(bedtime ?? sample.startDate, sample.startDate)
                wakeTime = max(wakeTime ?? sample.endDate, sample.endDate)
            default:
                break
            }
        }

        let asleep = core + deep + rem + asleepUnspecified
        guard asleep > 0 || inBed > 0 else { return nil }

        return SleepSummary(
            night: bedtime ?? samples.first?.startDate ?? now,
            inBed: inBed > 0 ? inBed : (asleep + awake),
            asleep: asleep,
            core: core,
            deep: deep,
            rem: rem,
            awake: awake,
            bedtime: bedtime,
            wakeTime: wakeTime
        )
    }

    // MARK: - Last-24h hourly heart-rate averages (for trend sharing)

    /// 24 values, oldest → newest. 0 means "no data that hour".
    func fetchLast24hHourlyHeartRate(calendar: Calendar = .current) async throws -> [Int] {
        let now = Date()
        let anchor = calendar.date(byAdding: .hour, value: -23, to: now) ?? now
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
        var result: [Int] = []
        collection.enumerateStatistics(from: start, to: end) { stat, _ in
            let v = stat.averageQuantity()?.doubleValue(for: unit) ?? 0
            result.append(Int(v.rounded()))
        }
        // Pad to 24 entries if the range was shorter than expected
        while result.count < 24 { result.insert(0, at: 0) }
        return Array(result.suffix(24))
    }

    // MARK: - Recent samples for sustained-emergency detection

    /// Fetches samples from the last `minutes`. Used by the emergency evaluator
    /// to decide whether an elevated BPM has been sustained.
    func fetchRecentSamples(minutes: Int = 15) async throws -> [HeartRateSample] {
        let end = Date()
        let start = end.addingTimeInterval(-Double(minutes) * 60)
        return try await fetchHeartRateSamples(start: start, end: end, limit: HealthKitManager.noSampleLimit)
    }

    // MARK: - Mindfulness

    func fetchTodayMindfulMinutes(calendar: Calendar = .current) async throws -> Double {
        guard let type = HKCategoryType.categoryType(forIdentifier: .mindfulSession) else { return 0 }
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
        return totalSec / 60.0
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
    let bedtime: Date?
    let wakeTime: Date?

    var efficiencyPercent: Double? {
        guard inBed > 0 else { return nil }
        return asleep / inBed
    }

    var totalSeconds: TimeInterval { asleep > 0 ? asleep : inBed }
}
