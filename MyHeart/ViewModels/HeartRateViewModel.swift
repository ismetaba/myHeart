import Foundation
import SwiftUI

@MainActor
final class HeartRateViewModel: ObservableObject {
    @Published var samples: [HeartRateSample] = []
    @Published var summary: HeartRateSummary = .empty
    @Published var isLoading: Bool = false
    @Published var authorizationError: String?
    @Published var lastRefresh: Date?
    @Published var selectedRange: TimeRange = .day

    enum TimeRange: String, CaseIterable, Identifiable {
        case day = "24h"
        case week = "Week"
        case month = "Month"
        var id: String { rawValue }

        var interval: TimeInterval {
            switch self {
            case .day: return 60 * 60 * 24
            case .week: return 60 * 60 * 24 * 7
            case .month: return 60 * 60 * 24 * 30
            }
        }
    }

    private let health: HealthKitManager

    init(health: HealthKitManager = .shared) {
        self.health = health
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

        let end = Date()
        let start = end.addingTimeInterval(-selectedRange.interval)

        do {
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
            lastRefresh = Date()
        } catch {
            authorizationError = error.localizedDescription
        }
    }

    func changeRange(to range: TimeRange) async {
        selectedRange = range
        await refresh()
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
            latest: samples.first,
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
}

extension HeartRateViewModel {
    static var preview: HeartRateViewModel {
        let vm = HeartRateViewModel()
        let now = Date()
        let fake = (0..<40).map { i in
            HeartRateSample(
                bpm: Double(60 + Int.random(in: 0...40)),
                date: now.addingTimeInterval(-Double(i) * 600),
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
        return vm
    }
}
