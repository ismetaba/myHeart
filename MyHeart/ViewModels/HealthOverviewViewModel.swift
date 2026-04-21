import Foundation
import SwiftUI
import HealthKit

/// Owns the big `HealthOverview` snapshot + the logic to assemble it from
/// HealthKit in parallel. Treat every data point as optional — nothing is
/// guaranteed to be present.
@MainActor
final class HealthOverviewViewModel: ObservableObject {
    @Published var overview: HealthOverview = .empty
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let health: HealthKitManager
    private let calendar: Calendar

    init(health: HealthKitManager = .shared, calendar: Calendar = .current) {
        self.health = health
        self.calendar = calendar
    }

    func bootstrap() async {
        // Permission is requested by the heart view model; nothing extra needed
        // here since the read types are a superset already.
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            overview = try await buildOverview()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildOverview() async throws -> HealthOverview {
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now

        // Kick everything off in parallel. Most of these are independent HK queries.
        async let stepsSumTask         = health.fetchCumulative(.stepCount,           unit: .count(),                       start: dayStart, end: dayEnd)
        async let distanceTask         = health.fetchCumulative(.distanceWalkingRunning, unit: .meterUnit(with: .kilo),     start: dayStart, end: dayEnd)
        async let flightsTask          = health.fetchCumulative(.flightsClimbed,      unit: .count(),                       start: dayStart, end: dayEnd)
        async let activeEnergyTask     = health.fetchCumulative(.activeEnergyBurned,  unit: .kilocalorie(),                 start: dayStart, end: dayEnd)
        async let basalEnergyTask      = health.fetchCumulative(.basalEnergyBurned,   unit: .kilocalorie(),                 start: dayStart, end: dayEnd)
        async let exerciseMinutesTask  = health.fetchCumulative(.appleExerciseTime,   unit: .minute(),                      start: dayStart, end: dayEnd)
        async let standTimeTask        = health.fetchCumulative(.appleStandTime,      unit: .hour(),                        start: dayStart, end: dayEnd)

        async let activitySummaryTask  = health.fetchTodayActivitySummary(calendar: calendar)

        async let latestHRTask         = health.fetchMostRecent(.heartRate,           unit: HKUnit.count().unitDivided(by: .minute()))
        async let restingHRTask        = health.fetchMostRecent(.restingHeartRate,    unit: HKUnit.count().unitDivided(by: .minute()))
        async let hrvTask              = health.fetchMostRecent(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli))
        async let walkingHRTask        = health.fetchMostRecent(.walkingHeartRateAverage,  unit: HKUnit.count().unitDivided(by: .minute()))
        async let vo2MaxTask           = health.fetchMostRecent(.vo2Max,              unit: HKUnit(from: "ml/kg*min"))

        async let respRateTask         = health.fetchMostRecent(.respiratoryRate,     unit: HKUnit.count().unitDivided(by: .minute()))
        async let spo2Task             = health.fetchMostRecent(.oxygenSaturation,    unit: .percent())

        async let weightTask           = health.fetchMostRecent(.bodyMass,            unit: .gramUnit(with: .kilo))
        async let heightTask           = health.fetchMostRecent(.height,              unit: .meterUnit(with: .centi))
        async let bmiTask              = health.fetchMostRecent(.bodyMassIndex,       unit: .count())
        async let bodyFatTask          = health.fetchMostRecent(.bodyFatPercentage,   unit: .percent())
        async let leanMassTask         = health.fetchMostRecent(.leanBodyMass,        unit: .gramUnit(with: .kilo))

        async let walkSpeedTask        = health.fetchMostRecent(.walkingSpeed,              unit: HKUnit.meter().unitDivided(by: .second()))
        async let walkLenTask          = health.fetchMostRecent(.walkingStepLength,         unit: .meterUnit(with: .centi))
        async let walkAsymTask         = health.fetchMostRecent(.walkingAsymmetryPercentage,unit: .percent())
        async let walkDblSupTask       = health.fetchMostRecent(.walkingDoubleSupportPercentage, unit: .percent())
        async let stairAscTask         = health.fetchMostRecent(.stairAscentSpeed,          unit: HKUnit.meter().unitDivided(by: .second()))
        async let stairDescTask        = health.fetchMostRecent(.stairDescentSpeed,         unit: HKUnit.meter().unitDivided(by: .second()))

        async let dietEnergyTask       = health.fetchCumulative(.dietaryEnergyConsumed, unit: .kilocalorie(), start: dayStart, end: dayEnd)
        async let waterTask            = health.fetchCumulative(.dietaryWater,          unit: .literUnit(with: .milli), start: dayStart, end: dayEnd)
        async let caffeineTask         = health.fetchCumulative(.dietaryCaffeine,       unit: .gramUnit(with: .milli),  start: dayStart, end: dayEnd)
        async let proteinTask          = health.fetchCumulative(.dietaryProtein,        unit: .gram(),                  start: dayStart, end: dayEnd)

        async let sleepTask            = health.fetchLastNightSleep(calendar: calendar)
        async let mindfulTask          = health.fetchTodayMindfulMinutes(calendar: calendar)

        async let headphoneTask        = health.fetchDiscreteAverage(.headphoneAudioExposure, unit: .decibelAWeightedSoundPressureLevel(), start: calendar.date(byAdding: .day, value: -1, to: now) ?? now, end: now)
        async let environmentTask      = health.fetchDiscreteAverage(.environmentalAudioExposure, unit: .decibelAWeightedSoundPressureLevel(), start: calendar.date(byAdding: .day, value: -1, to: now) ?? now, end: now)

        // Trend mini-series.
        async let steps7Task           = health.fetchDailySeries(.stepCount,            unit: .count(),          days: 7,  options: .cumulativeSum, calendar: calendar)
        async let energy7Task          = health.fetchDailySeries(.activeEnergyBurned,   unit: .kilocalorie(),    days: 7,  options: .cumulativeSum, calendar: calendar)
        async let restingHR14Task      = health.fetchDailySeries(.restingHeartRate,     unit: HKUnit.count().unitDivided(by: .minute()), days: 14, options: .discreteAverage, calendar: calendar)
        async let weight30Task         = health.fetchDailySeries(.bodyMass,             unit: .gramUnit(with: .kilo),    days: 30, options: .discreteAverage, calendar: calendar)
        async let hrv14Task            = health.fetchDailySeries(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), days: 14, options: .discreteAverage, calendar: calendar)

        // Collect.
        var snap = HealthOverview()

        // Activity
        let activity = await (try? activitySummaryTask) ?? nil
        snap.activity = ActivitySnapshot(
            steps:                (try? await stepsSumTask).flatMap { $0.map { Int($0.rounded()) } },
            distanceKm:           try? await distanceTask,
            flightsClimbed:       (try? await flightsTask).flatMap { $0.map { Int($0.rounded()) } },
            activeEnergyKcal:     try? await activeEnergyTask,
            basalEnergyKcal:      try? await basalEnergyTask,
            exerciseMinutes:      (try? await exerciseMinutesTask).flatMap { $0.map { Int($0.rounded()) } },
            standHours:           (try? await standTimeTask).flatMap { $0.map { Int($0.rounded()) } },
            moveGoalKcal:         activity?.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()),
            exerciseGoalMinutes:  activity?.exerciseTimeGoal?.doubleValue(for: .minute()),
            standGoalHours:       activity?.standHoursGoal?.doubleValue(for: .count())
        )

        // Heart
        let latestHR  = (try? await latestHRTask)  ?? nil
        let restingHR = (try? await restingHRTask) ?? nil
        let hrv       = (try? await hrvTask)       ?? nil
        let walkHR    = (try? await walkingHRTask) ?? nil
        let vo2       = (try? await vo2MaxTask)    ?? nil
        snap.heart = HeartSnapshot(
            latestBPM:    latestHR?.value,
            latestBPMAt:  latestHR?.date,
            restingBPM:   restingHR?.value,
            hrvMs:        hrv?.value,
            walkingHRAvg: walkHR?.value,
            vo2Max:       vo2?.value
        )

        // Respiratory
        let rr = (try? await respRateTask) ?? nil
        let sp = (try? await spo2Task)     ?? nil
        snap.respiratory = RespiratorySnapshot(
            respiratoryRate: rr?.value,
            oxygenSaturation: sp?.value
        )

        // Body
        let weight   = (try? await weightTask)   ?? nil
        let height   = (try? await heightTask)   ?? nil
        let bmi      = (try? await bmiTask)      ?? nil
        let bodyFat  = (try? await bodyFatTask)  ?? nil
        let leanMass = (try? await leanMassTask) ?? nil
        snap.body = BodySnapshot(
            weightKg:       weight?.value,
            weightAt:       weight?.date,
            heightCm:       height?.value,
            bmi:            bmi?.value,
            bodyFatPercent: bodyFat?.value,
            leanBodyMassKg: leanMass?.value
        )

        // Mobility
        let ws  = (try? await walkSpeedTask)     ?? nil
        let wl  = (try? await walkLenTask)       ?? nil
        let wa  = (try? await walkAsymTask)      ?? nil
        let wds = (try? await walkDblSupTask)    ?? nil
        let sa  = (try? await stairAscTask)      ?? nil
        let sd  = (try? await stairDescTask)     ?? nil
        snap.mobility = MobilitySnapshot(
            walkingSpeed:                ws?.value,
            walkingStepLength:           wl.map { $0.value / 100.0 }, // cm → m
            walkingAsymmetryPercent:     wa?.value,
            walkingDoubleSupportPercent: wds?.value,
            stairAscentSpeed:            sa?.value,
            stairDescentSpeed:           sd?.value
        )

        // Nutrition
        snap.nutrition = NutritionSnapshot(
            dietaryEnergyKcal: try? await dietEnergyTask,
            waterMl: try? await waterTask,
            caffeineMg: try? await caffeineTask,
            proteinG: try? await proteinTask
        )

        // Sleep
        snap.sleep = try? await sleepTask

        // Mindfulness
        let minutes = (try? await mindfulTask) ?? 0
        snap.mindfulness = MindfulnessSnapshot(todayMinutes: minutes, sessionsToday: minutes > 0 ? 1 : 0)

        // Audio
        snap.audio = AudioSnapshot(
            headphoneDBA: try? await headphoneTask,
            environmentalDBA: try? await environmentTask
        )

        // Trend series
        snap.stepsLast7      = (try? await steps7Task)      ?? []
        snap.activeEnergyLast7 = (try? await energy7Task)   ?? []
        snap.restingHRLast14 = (try? await restingHR14Task) ?? []
        snap.weightLast30    = (try? await weight30Task)    ?? []
        snap.hrvLast14       = (try? await hrv14Task)       ?? []

        snap.generatedAt = Date()
        return snap
    }
}

// MARK: - Preview

extension HealthOverviewViewModel {
    static var preview: HealthOverviewViewModel {
        let vm = HealthOverviewViewModel()
        var o = HealthOverview()
        o.activity = ActivitySnapshot(
            steps: 8432, distanceKm: 6.3, flightsClimbed: 12,
            activeEnergyKcal: 412, basalEnergyKcal: 1580,
            exerciseMinutes: 42, standHours: 9,
            moveGoalKcal: 600, exerciseGoalMinutes: 30, standGoalHours: 12
        )
        o.heart = HeartSnapshot(
            latestBPM: 72, latestBPMAt: Date().addingTimeInterval(-120),
            restingBPM: 58, hrvMs: 48, walkingHRAvg: 102, vo2Max: 42.5
        )
        o.sleep = SleepSummary(
            night: Calendar.current.startOfDay(for: Date()).addingTimeInterval(-8 * 3600),
            inBed: 7.5 * 3600, asleep: 6.8 * 3600,
            core: 3.5 * 3600, deep: 1.2 * 3600, rem: 2.1 * 3600, awake: 0.7 * 3600,
            bedtime: Calendar.current.startOfDay(for: Date()).addingTimeInterval(-8 * 3600),
            wakeTime: Calendar.current.startOfDay(for: Date()).addingTimeInterval(-0.5 * 3600)
        )
        o.body = BodySnapshot(weightKg: 74.2, weightAt: Date(), heightCm: 178, bmi: 23.4, bodyFatPercent: 0.18, leanBodyMassKg: 60.8)
        o.respiratory = RespiratorySnapshot(respiratoryRate: 14.5, oxygenSaturation: 0.98)
        o.mobility = MobilitySnapshot(walkingSpeed: 1.36, walkingStepLength: 0.72, walkingAsymmetryPercent: 0.02, walkingDoubleSupportPercent: 0.24, stairAscentSpeed: 0.42, stairDescentSpeed: 0.48)
        o.nutrition = NutritionSnapshot(dietaryEnergyKcal: 1820, waterMl: 1450, caffeineMg: 85, proteinG: 98)
        o.mindfulness = MindfulnessSnapshot(todayMinutes: 12, sessionsToday: 2)
        o.audio = AudioSnapshot(headphoneDBA: 72, environmentalDBA: 58)

        // sparkline mocks
        let now = Date()
        o.stepsLast7 = (0..<7).map { i in
            let d = Calendar.current.date(byAdding: .day, value: -i, to: now)!
            return MetricPoint(date: d, value: Double(5000 + Int.random(in: 0...8000)))
        }.reversed()
        o.activeEnergyLast7 = (0..<7).map { i in
            let d = Calendar.current.date(byAdding: .day, value: -i, to: now)!
            return MetricPoint(date: d, value: Double(200 + Int.random(in: 0...500)))
        }.reversed()
        o.restingHRLast14 = (0..<14).map { i in
            let d = Calendar.current.date(byAdding: .day, value: -i, to: now)!
            return MetricPoint(date: d, value: Double(55 + Int.random(in: 0...8)))
        }.reversed()
        o.weightLast30 = (0..<30).map { i in
            let d = Calendar.current.date(byAdding: .day, value: -i, to: now)!
            return MetricPoint(date: d, value: 73 + Double.random(in: -1...1))
        }.reversed()
        o.hrvLast14 = (0..<14).map { i in
            let d = Calendar.current.date(byAdding: .day, value: -i, to: now)!
            return MetricPoint(date: d, value: Double(35 + Int.random(in: 0...40)))
        }.reversed()

        vm.overview = o
        return vm
    }
}
