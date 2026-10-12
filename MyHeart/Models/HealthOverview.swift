import Foundation

/// Top-level snapshot of "everything health" for the home screen.
/// Any sub-struct can be nil when the device has no data (no Apple Watch,
/// permission denied, brand new install, etc.) — the UI handles that
/// gracefully.
struct HealthOverview: Hashable {
    var generatedAt: Date = Date()
    var activity: ActivitySnapshot = .empty
    var heart: HeartSnapshot = .empty
    var sleep: SleepSummary? = nil
    var body: BodySnapshot = .empty
    var respiratory: RespiratorySnapshot = .empty
    var mobility: MobilitySnapshot = .empty
    var nutrition: NutritionSnapshot = .empty
    var mindfulness: MindfulnessSnapshot = .empty
    var audio: AudioSnapshot = .empty

    /// Trend mini-series used for inline sparklines on each card.
    var stepsLast7: [MetricPoint] = []
    var activeEnergyLast7: [MetricPoint] = []
    var restingHRLast14: [MetricPoint] = []
    var weightLast30: [MetricPoint] = []
    var hrvLast14: [MetricPoint] = []

    static let empty = HealthOverview()

    /// Fixed stand-in drawn redacted until the first refresh finishes, so the
    /// skeleton has realistic text widths. Goals and series stay empty because
    /// `.redacted` doesn't mask shapes or chart marks — they'd draw in color.
    static let placeholder: HealthOverview = {
        var o = HealthOverview()
        o.activity = ActivitySnapshot(
            steps: 8000, distanceKm: 5.6, flightsClimbed: 10,
            activeEnergyKcal: 400, exerciseMinutes: 30, standHours: 8
        )
        o.heart = HeartSnapshot(latestBPM: 70, restingBPM: 58, hrvMs: 45, walkingHRAvg: 100)
        o.sleep = SleepSummary(
            night: Date(), inBed: 8 * 3600, asleep: 7.5 * 3600,
            core: 4 * 3600, deep: 3600, rem: 2.5 * 3600, awake: 0.5 * 3600,
            bedtime: nil, wakeTime: nil
        )
        return o
    }()

    /// Average of the finished days in a daily series. Today is still in
    /// progress, and a zero day is a day Health has nothing for (the fetcher
    /// fills gaps with 0) — both would drag the average down.
    static func completedDayAverage(_ points: [MetricPoint], calendar: Calendar = .current) -> Double? {
        let done = points.filter { !calendar.isDateInToday($0.date) && $0.value > 0 }
        guard !done.isEmpty else { return nil }
        return done.reduce(0) { $0 + $1.value } / Double(done.count)
    }

    /// Cumulative series report 0 for empty days, so "all zero" means "nothing
    /// recorded", not a week of zero steps.
    static func hasData(_ points: [MetricPoint]) -> Bool {
        points.contains { $0.value != 0 }
    }

    /// "Most recent" samples can be weeks old; past a day the UI dims them and
    /// shows their date so they aren't read as today's.
    static func isStale(_ sampleDate: Date?, now: Date = Date()) -> Bool {
        guard let sampleDate else { return false }
        return now.timeIntervalSince(sampleDate) > 86_400
    }
}

// MARK: - Activity

struct ActivitySnapshot: Hashable {
    /// Today's cumulative values.
    var steps: Int?
    var distanceKm: Double?
    var flightsClimbed: Int?
    var activeEnergyKcal: Double?
    var basalEnergyKcal: Double?
    var exerciseMinutes: Int?
    var standHours: Int?

    /// Goals from the Activity Ring summary, when available.
    var moveGoalKcal: Double?
    var exerciseGoalMinutes: Double?
    var standGoalHours: Double?

    static let empty = ActivitySnapshot()

    var hasAny: Bool {
        steps != nil || activeEnergyKcal != nil || exerciseMinutes != nil || standHours != nil || distanceKm != nil
            || flightsClimbed != nil || basalEnergyKcal != nil
    }

    /// A summary can exist with a zero goal (nothing set up), which would
    /// still leave every ring empty.
    var hasGoals: Bool {
        [moveGoalKcal, exerciseGoalMinutes, standGoalHours].contains { ($0 ?? 0) > 0 }
    }

    var totalEnergyKcal: Double? {
        switch (activeEnergyKcal, basalEnergyKcal) {
        case let (a?, b?): return a + b
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}

// MARK: - Heart

/// The `…At` dates are when the most recent sample was taken — these can be
/// days or months old, so the UI flags them instead of implying "today".
struct HeartSnapshot: Hashable {
    var latestBPM: Double?
    var latestBPMAt: Date?
    var restingBPM: Double?
    var restingAt: Date?
    var hrvMs: Double?
    var hrvAt: Date?
    var walkingHRAvg: Double?
    var walkingHRAt: Date?
    var vo2Max: Double?
    var vo2At: Date?

    static let empty = HeartSnapshot()

    var hasAny: Bool {
        latestBPM != nil || restingBPM != nil || hrvMs != nil || walkingHRAvg != nil || vo2Max != nil
    }
}

// MARK: - Body

struct BodySnapshot: Hashable {
    var weightKg: Double?
    var weightAt: Date?
    var heightCm: Double?
    var bmi: Double?
    var bodyFatPercent: Double?
    var leanBodyMassKg: Double?

    static let empty = BodySnapshot()

    var hasAny: Bool {
        weightKg != nil || heightCm != nil || bmi != nil || bodyFatPercent != nil
    }
}

// MARK: - Respiratory

struct RespiratorySnapshot: Hashable {
    var respiratoryRate: Double?      // breaths per min (latest sample avg)
    var respiratoryRateAt: Date?
    var oxygenSaturation: Double?     // 0...1 percent (latest sample avg)
    var oxygenSaturationAt: Date?
    static let empty = RespiratorySnapshot()
    var hasAny: Bool { respiratoryRate != nil || oxygenSaturation != nil }
}

// MARK: - Mobility

struct MobilitySnapshot: Hashable {
    var walkingSpeed: Double?             // m/s
    var walkingStepLength: Double?        // m (stored in cm, returned in m here)
    var walkingAsymmetryPercent: Double?  // 0...1
    var walkingDoubleSupportPercent: Double?
    var stairAscentSpeed: Double?         // m/s
    var stairDescentSpeed: Double?        // m/s

    /// Sample dates for the values shown on the overview.
    var walkingSpeedAt: Date?
    var walkingStepLengthAt: Date?
    var walkingAsymmetryAt: Date?
    var stairAscentSpeedAt: Date?

    static let empty = MobilitySnapshot()

    var hasAny: Bool {
        walkingSpeed != nil || walkingStepLength != nil || walkingAsymmetryPercent != nil
            || stairAscentSpeed != nil || stairDescentSpeed != nil
    }
}

// MARK: - Nutrition

struct NutritionSnapshot: Hashable {
    var dietaryEnergyKcal: Double?
    var waterMl: Double?
    var caffeineMg: Double?
    var proteinG: Double?
    static let empty = NutritionSnapshot()
    var hasAny: Bool { dietaryEnergyKcal != nil || waterMl != nil || caffeineMg != nil || proteinG != nil }
}

// MARK: - Mindfulness

struct MindfulnessSnapshot: Hashable {
    var todayMinutes: Double = 0
    var sessionsToday: Int = 0
    static let empty = MindfulnessSnapshot()
    var hasAny: Bool { todayMinutes > 0 }
}

// MARK: - Audio

struct AudioSnapshot: Hashable {
    var headphoneDBA: Double?
    var environmentalDBA: Double?
    static let empty = AudioSnapshot()
    var hasAny: Bool { headphoneDBA != nil || environmentalDBA != nil }
}

// MARK: - Formatting

/// A formatted number and its unit, kept apart so tiles can draw the unit
/// smaller and VoiceOver can spell it out.
struct FormattedMeasure: Hashable {
    let value: String
    let unit: String

    static let missing = FormattedMeasure(value: HealthFormat.missing, unit: "")

    /// "6.30 km" — for subtitles and other single-string spots.
    var text: String {
        unit.isEmpty || value == HealthFormat.missing ? value : "\(value) \(unit)"
    }
}

/// All numbers go through the user's locale (grouping, decimal separator).
enum HealthFormat {
    /// Shown for a value Health has no sample for.
    static let missing = "—"

    static func number(_ v: Double?, fraction: Int = 0) -> String {
        guard let v else { return missing }
        return v.formatted(
            .number
                .precision(.fractionLength(fraction))
                .rounded(rule: .toNearestOrAwayFromZero)
        )
    }

    static func steps(_ v: Int?) -> String {
        guard let v else { return missing }
        return NumberFormatter.localizedString(from: NSNumber(value: v), number: .decimal)
    }

    static func int(_ v: Double?) -> String {
        number(v)
    }

    static func one(_ v: Double?, suffix: String = "") -> String {
        guard let v else { return missing }
        return number(v, fraction: 1) + suffix
    }

    static func kcal(_ v: Double?) -> String {
        guard let v else { return missing }
        return "\(number(v)) kcal"
    }

    static func minutes(_ v: Double?) -> String {
        guard let v else { return missing }
        let h = Int(v) / 60
        let m = Int(v) % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func percent(_ v: Double?) -> String {
        guard let v else { return missing }
        return v.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "7h 30m", like the rest of the app. An exact zero reads "0m", not "<1m".
    static func duration(_ seconds: TimeInterval) -> String {
        Int(seconds.rounded()) == 0 ? "0m" : DurationFormat.compact(seconds)
    }

    /// "7 hours, 30 minutes" for VoiceOver, matching what `duration` shows.
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let shown = (total / 3600) * 3600 + ((total % 3600) / 60) * 60
        return Duration.seconds(shown).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    // MARK: Units

    /// US users get miles, pounds and feet. This follows the region only —
    /// Health's own unit settings would need an extra HealthKit fetch at launch.
    static var usesUSUnits: Bool { Locale.current.measurementSystem == .us }

    static func distance(_ km: Double?) -> FormattedMeasure {
        guard let km else { return .missing }
        if usesUSUnits { return FormattedMeasure(value: number(km * 0.621_371, fraction: 2), unit: "mi") }
        if km < 1 { return FormattedMeasure(value: number(km * 1000), unit: "m") }
        return FormattedMeasure(value: number(km, fraction: 2), unit: "km")
    }

    static var massUnit: String { usesUSUnits ? "lb" : "kg" }

    /// Body mass in the unit `massUnit` names (for chart values).
    static func massInPreferredUnit(_ kg: Double) -> Double {
        usesUSUnits ? kg * 2.204_623 : kg
    }

    static func mass(_ kg: Double?) -> FormattedMeasure {
        guard let kg else { return .missing }
        return FormattedMeasure(value: number(massInPreferredUnit(kg), fraction: 1), unit: massUnit)
    }

    static func height(_ cm: Double?) -> FormattedMeasure {
        guard let cm else { return .missing }
        if usesUSUnits {
            let inches = Int((cm / 2.54).rounded())
            return FormattedMeasure(value: "\(inches / 12)′\(inches % 12)″", unit: "")
        }
        return FormattedMeasure(value: number(cm), unit: "cm")
    }

    static func stepLength(_ meters: Double?) -> FormattedMeasure {
        guard let meters else { return .missing }
        if usesUSUnits { return FormattedMeasure(value: number(meters * 39.370_1), unit: "in") }
        return FormattedMeasure(value: number(meters * 100), unit: "cm")
    }

    /// km/h or mph, as Health shows walking speed, rather than m/s.
    static func walkingSpeed(_ metersPerSecond: Double?) -> FormattedMeasure {
        guard let v = metersPerSecond else { return .missing }
        if usesUSUnits { return FormattedMeasure(value: number(v * 2.236_94, fraction: 1), unit: "mph") }
        return FormattedMeasure(value: number(v * 3.6, fraction: 1), unit: "km/h")
    }

    static func stairSpeed(_ metersPerSecond: Double?) -> FormattedMeasure {
        guard let v = metersPerSecond else { return .missing }
        if usesUSUnits { return FormattedMeasure(value: number(v * 3.280_84, fraction: 2), unit: "ft/s") }
        return FormattedMeasure(value: number(v, fraction: 2), unit: "m/s")
    }

    // MARK: VoiceOver

    /// What VoiceOver should say for a tile value: "No data" instead of an
    /// em dash, and units as words instead of letter by letter.
    static func spoken(_ value: String, unit: String) -> String {
        guard value != missing else { return "No data" }
        let spokenValue = value
            .replacingOccurrences(of: "′", with: " feet ")
            .replacingOccurrences(of: "″", with: " inches")
        let words = spokenUnit(unit)
        return words.isEmpty ? spokenValue : "\(spokenValue) \(words)"
    }

    static func spokenUnit(_ unit: String) -> String {
        switch unit {
        case "bpm":       return "beats per minute"
        case "ms":        return "milliseconds"
        case "dBA":       return "decibels"
        case "br/min":    return "breaths per minute"
        case "mL/kg/min": return "milliliters per kilogram per minute"
        case "m/s":       return "meters per second"
        case "ft/s":      return "feet per second"
        case "km/h":      return "kilometers per hour"
        case "mph":       return "miles per hour"
        case "kcal":      return "kilocalories"
        case "mL":        return "milliliters"
        case "mg":        return "milligrams"
        case "g":         return "grams"
        case "kg":        return "kilograms"
        case "lb":        return "pounds"
        case "cm":        return "centimeters"
        case "in":        return "inches"
        case "km":        return "kilometers"
        case "mi":        return "miles"
        case "m":         return "meters"
        case "min":       return "minutes"
        case "hr":        return "hours"
        default:          return unit
        }
    }
}
