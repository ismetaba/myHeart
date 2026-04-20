import Foundation
import HealthKit

enum HealthKitError: LocalizedError {
    case notAvailable
    case typeUnavailable
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "HealthKit is not available on this device."
        case .typeUnavailable:
            return "The requested health data type is not available."
        case .authorizationDenied:
            return "Access to Apple Health was denied. Enable it in Settings → Privacy → Health."
        }
    }
}

final class HealthKitManager {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()

    private let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    private let restingHeartRateType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!
    private let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!

    private let bpmUnit: HKUnit = HKUnit.count().unitDivided(by: .minute())

    private var readTypes: Set<HKObjectType> {
        [heartRateType, restingHeartRateType, hrvType]
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.notAvailable
        }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func fetchHeartRateSamples(start: Date, end: Date, limit: Int = 2000) async throws -> [HeartRateSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]

        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: heartRateType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sort
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }

        return samples.map { sample in
            HeartRateSample(
                id: sample.uuid,
                bpm: sample.quantity.doubleValue(for: bpmUnit),
                date: sample.endDate,
                source: sample.sourceRevision.source.name
            )
        }
    }

    func fetchLatestQuantity(for type: HKQuantityType, unit: HKUnit) async throws -> Double? {
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let sample: HKQuantitySample? = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: sort
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKQuantitySample])?.first)
            }
            store.execute(query)
        }
        return sample?.quantity.doubleValue(for: unit)
    }

    func fetchLatestRestingHeartRate() async throws -> Double? {
        try await fetchLatestQuantity(for: restingHeartRateType, unit: bpmUnit)
    }

    func fetchLatestHRV() async throws -> Double? {
        try await fetchLatestQuantity(for: hrvType, unit: .secondUnit(with: .milli))
    }

    /// Fetches per-day min/avg/max heart rate and resting heart rate between `start` and `end`.
    func fetchDailyStats(start: Date, end: Date, calendar: Calendar = .current) async throws -> [DailyHeartRateStats] {
        let dayComp = DateComponents(day: 1)
        let anchor = calendar.startOfDay(for: start)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        async let avg: HKStatisticsCollection = runStatisticsCollection(
            type: heartRateType, predicate: predicate, options: .discreteAverage, anchor: anchor, interval: dayComp
        )
        async let minC: HKStatisticsCollection = runStatisticsCollection(
            type: heartRateType, predicate: predicate, options: .discreteMin, anchor: anchor, interval: dayComp
        )
        async let maxC: HKStatisticsCollection = runStatisticsCollection(
            type: heartRateType, predicate: predicate, options: .discreteMax, anchor: anchor, interval: dayComp
        )
        async let countC: HKStatisticsCollection = runStatisticsCollection(
            type: heartRateType, predicate: predicate, options: .cumulativeSum, anchor: anchor, interval: dayComp
        )
        // Resting HR is one value per day already; use average for the bucket.
        async let restingC: HKStatisticsCollection = runStatisticsCollection(
            type: restingHeartRateType,
            predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
            options: .discreteAverage,
            anchor: anchor,
            interval: dayComp
        )

        let avgCol = try await avg
        let minCol = try await minC
        let maxCol = try await maxC
        let countCol = try await countC
        let restingCol = try await restingC

        var stats: [DailyHeartRateStats] = []
        avgCol.enumerateStatistics(from: start, to: end) { avgStat, _ in
            let day = calendar.startOfDay(for: avgStat.startDate)
            let avgVal = avgStat.averageQuantity()?.doubleValue(for: self.bpmUnit)

            let minStat = minCol.statistics(for: avgStat.startDate)
            let minVal = minStat?.minimumQuantity()?.doubleValue(for: self.bpmUnit)

            let maxStat = maxCol.statistics(for: avgStat.startDate)
            let maxVal = maxStat?.maximumQuantity()?.doubleValue(for: self.bpmUnit)

            let restingStat = restingCol.statistics(for: avgStat.startDate)
            let restingVal = restingStat?.averageQuantity()?.doubleValue(for: self.bpmUnit)

            // `cumulativeSum` on a discrete type isn't meaningful, but we can get sample count from the sources object count. Fallback to 0.
            var count = 0
            if let sources = countCol.statistics(for: avgStat.startDate)?.sources {
                count = sources.count
            }
            // If we got any avg value, count > 0 at minimum.
            if avgVal != nil, count == 0 { count = 1 }

            stats.append(
                DailyHeartRateStats(
                    day: day,
                    minBPM: minVal,
                    avgBPM: avgVal,
                    maxBPM: maxVal,
                    restingBPM: restingVal,
                    sampleCount: count
                )
            )
        }
        return stats
    }

    private func runStatisticsCollection(
        type: HKQuantityType,
        predicate: NSPredicate?,
        options: HKStatisticsOptions,
        anchor: Date,
        interval: DateComponents
    ) async throws -> HKStatisticsCollection {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: anchor,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let collection {
                    continuation.resume(returning: collection)
                } else {
                    continuation.resume(throwing: HealthKitError.typeUnavailable)
                }
            }
            store.execute(query)
        }
    }
}
