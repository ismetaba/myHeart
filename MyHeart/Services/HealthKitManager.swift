import Foundation
import HealthKit

enum HealthKitError: LocalizedError {
    case notAvailable
    case typeUnavailable
    case authorizationDenied

    /// True for the "device is locked" error HealthKit throws while protected
    /// data is unavailable (typical for background wakes). Not worth surfacing.
    static func isProtectedDataUnavailable(_ error: Error) -> Bool {
        (error as? HKError)?.code == .errorDatabaseInaccessible
    }

    /// Statistics queries over a window without samples fail with
    /// `errorNoData` instead of returning an empty result.
    static func isNoData(_ error: Error) -> Bool {
        (error as? HKError)?.code == .errorNoData
    }

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
    static let noSampleLimit: Int = HKObjectQueryNoLimit

    let store = HKHealthStore()

    // MARK: - Types

    // Heart
    private let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    private let restingHeartRateType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!
    private let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
    private let walkingHeartRateType = HKQuantityType.quantityType(forIdentifier: .walkingHeartRateAverage)!
    private let vo2MaxType = HKQuantityType.quantityType(forIdentifier: .vo2Max)

    // Activity
    private let stepCountType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    private let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!
    private let flightsType = HKQuantityType.quantityType(forIdentifier: .flightsClimbed)!
    private let activeEnergyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
    private let basalEnergyType = HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned)!
    private let exerciseTimeType = HKQuantityType.quantityType(forIdentifier: .appleExerciseTime)!
    private let standTimeType = HKQuantityType.quantityType(forIdentifier: .appleStandTime)

    // Respiratory / oxygen
    private let respiratoryRateType = HKQuantityType.quantityType(forIdentifier: .respiratoryRate)!
    private let oxygenSaturationType = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!

    // Body
    private let bodyMassType = HKQuantityType.quantityType(forIdentifier: .bodyMass)!
    private let bmiType = HKQuantityType.quantityType(forIdentifier: .bodyMassIndex)!
    private let heightType = HKQuantityType.quantityType(forIdentifier: .height)!
    private let bodyFatType = HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage)!
    private let leanBodyMassType = HKQuantityType.quantityType(forIdentifier: .leanBodyMass)!

    // Mobility
    private let walkingSpeedType = HKQuantityType.quantityType(forIdentifier: .walkingSpeed)
    private let walkingStepLengthType = HKQuantityType.quantityType(forIdentifier: .walkingStepLength)
    private let walkingAsymmetryType = HKQuantityType.quantityType(forIdentifier: .walkingAsymmetryPercentage)
    private let walkingDoubleSupportType = HKQuantityType.quantityType(forIdentifier: .walkingDoubleSupportPercentage)
    private let stairAscentSpeedType = HKQuantityType.quantityType(forIdentifier: .stairAscentSpeed)
    private let stairDescentSpeedType = HKQuantityType.quantityType(forIdentifier: .stairDescentSpeed)

    // Nutrition
    private let dietaryEnergyType = HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed)!
    private let dietaryWaterType = HKQuantityType.quantityType(forIdentifier: .dietaryWater)!
    private let caffeineType = HKQuantityType.quantityType(forIdentifier: .dietaryCaffeine)!
    private let proteinType = HKQuantityType.quantityType(forIdentifier: .dietaryProtein)!

    // Audio
    private let headphoneDBAType = HKQuantityType.quantityType(forIdentifier: .headphoneAudioExposure)
    private let environmentalDBAType = HKQuantityType.quantityType(forIdentifier: .environmentalAudioExposure)

    // Sleep / mindfulness
    private let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
    private let mindfulType = HKCategoryType.categoryType(forIdentifier: .mindfulSession)

    // Units
    private let bpmUnit: HKUnit = HKUnit.count().unitDivided(by: .minute())
    private let kcalUnit: HKUnit = .kilocalorie()
    private let kmUnit: HKUnit = .meterUnit(with: .kilo)
    private let kgUnit: HKUnit = .gramUnit(with: .kilo)
    private let cmUnit: HKUnit = .meterUnit(with: .centi)
    private let percentUnit: HKUnit = .percent()
    private let breathsPerMinUnit: HKUnit = HKUnit.count().unitDivided(by: .minute())
    private let meterPerSecondUnit: HKUnit = HKUnit.meter().unitDivided(by: .second())
    private let decibelAWeightedUnit: HKUnit = .decibelAWeightedSoundPressureLevel()
    private let litreUnit: HKUnit = .literUnit(with: .milli)

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            heartRateType, restingHeartRateType, hrvType, walkingHeartRateType,
            stepCountType, distanceType, flightsType,
            activeEnergyType, basalEnergyType, exerciseTimeType,
            respiratoryRateType, oxygenSaturationType,
            bodyMassType, bmiType, heightType, bodyFatType, leanBodyMassType,
            dietaryEnergyType, dietaryWaterType, caffeineType, proteinType,
            sleepType,
            // Required for HKActivitySummaryQuery (ring goals + stand hours).
            HKObjectType.activitySummaryType(),
        ]
        let optional: [HKObjectType?] = [
            vo2MaxType, standTimeType,
            walkingSpeedType, walkingStepLengthType, walkingAsymmetryType, walkingDoubleSupportType,
            stairAscentSpeedType, stairDescentSpeedType,
            headphoneDBAType, environmentalDBAType,
            mindfulType,
        ]
        for t in optional { if let t { types.insert(t) } }
        return types
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.notAvailable
        }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Whether the permission sheet has already been shown at least once.
    /// HealthKit never reveals whether *read* access was granted, only whether
    /// asking again would show UI.
    func hasRequestedAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return await withCheckedContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, _ in
                continuation.resume(returning: status == .unnecessary)
            }
        }
    }

    // MARK: - Live updates

    /// Registers a long-running observer that fires whenever new heart-rate
    /// samples land in HealthKit (Apple Watch sync, manual entry, …).
    /// `onChange` must call the provided completion when it's done so iOS
    /// knows the background delivery was handled. `onError` fires when the
    /// query dies (e.g. authorization not determined yet).
    func startHeartRateObserver(
        onChange: @escaping (_ completion: @escaping () -> Void) -> Void,
        onError: @escaping (Error) -> Void
    ) -> HKObserverQuery {
        let query = HKObserverQuery(sampleType: heartRateType, predicate: nil) { _, completion, error in
            if let error {
                completion()
                onError(error)
                return
            }
            onChange(completion)
        }
        store.execute(query)
        return query
    }

    func stopObserver(_ query: HKObserverQuery) {
        store.stop(query)
    }

    /// Lets iOS wake the app in the background when new heart-rate samples
    /// arrive. Requires the HealthKit background-delivery entitlement.
    func enableHeartRateBackgroundDelivery() {
        store.enableBackgroundDelivery(for: heartRateType, frequency: .immediate) { _, error in
            if let error {
                print("[HealthKit] background delivery unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// The single most recent heart-rate sample, regardless of date.
    func fetchLatestHeartRateSample() async throws -> HeartRateSample? {
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let sample: HKQuantitySample? = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: heartRateType,
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
        return sample.map { makeSample($0) }
    }

    /// Average / min / max heart rate over a window without loading every
    /// sample into memory. Used for the previous-period comparison.
    func fetchHeartRateStatistics(start: Date, end: Date) async throws -> (average: Double?, min: Double?, max: Double?) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        let unit = bpmUnit
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: heartRateType,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMin, .discreteMax]
            ) { _, stats, error in
                if let error {
                    if HealthKitError.isNoData(error) {
                        continuation.resume(returning: (nil, nil, nil))
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: (
                    stats?.averageQuantity()?.doubleValue(for: unit),
                    stats?.minimumQuantity()?.doubleValue(for: unit),
                    stats?.maximumQuantity()?.doubleValue(for: unit)
                ))
            }
            store.execute(query)
        }
    }

    private func makeSample(_ sample: HKQuantitySample) -> HeartRateSample {
        HeartRateSample(
            id: sample.uuid,
            bpm: sample.quantity.doubleValue(for: bpmUnit),
            date: sample.endDate,
            source: sample.sourceRevision.source.name
        )
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

        return samples.map { makeSample($0) }
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

    /// Average resting heart rate across a window (discreteAverage over HKHealthStore).
    func fetchAverageResting(start: Date, end: Date) async throws -> Double? {
        try await fetchAverageQuantity(for: restingHeartRateType, unit: bpmUnit, start: start, end: end)
    }

    /// Average HRV (SDNN) across a window.
    func fetchAverageHRV(start: Date, end: Date) async throws -> Double? {
        try await fetchAverageQuantity(
            for: hrvType,
            unit: .secondUnit(with: .milli),
            start: start,
            end: end
        )
    }

    private func fetchAverageQuantity(
        for type: HKQuantityType,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, stats, error in
                if let error {
                    // HealthKit reports an empty window as an error; that's just "no value".
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

    /// Fetches per-day min/avg/max heart rate and resting heart rate between `start` and `end`.
    /// `sampleCount` is left at 0 — callers that already hold the raw samples
    /// fill it in, which avoids loading every sample a second time.
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

            stats.append(
                DailyHeartRateStats(
                    day: day,
                    minBPM: minVal,
                    avgBPM: avgVal,
                    maxBPM: maxVal,
                    restingBPM: restingVal,
                    sampleCount: 0
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
