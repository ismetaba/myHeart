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

    private var readTypes: Set<HKObjectType> {
        [heartRateType, restingHeartRateType, hrvType]
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.notAvailable
        }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func fetchHeartRateSamples(start: Date, end: Date, limit: Int = 500) async throws -> [HeartRateSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]

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

        let unit = HKUnit.count().unitDivided(by: .minute())
        return samples.map { sample in
            HeartRateSample(
                id: sample.uuid,
                bpm: sample.quantity.doubleValue(for: unit),
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
        let unit = HKUnit.count().unitDivided(by: .minute())
        return try await fetchLatestQuantity(for: restingHeartRateType, unit: unit)
    }

    func fetchLatestHRV() async throws -> Double? {
        try await fetchLatestQuantity(for: hrvType, unit: .secondUnit(with: .milli))
    }
}
