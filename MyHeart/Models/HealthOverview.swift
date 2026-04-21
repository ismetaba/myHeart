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

struct HeartSnapshot: Hashable {
    var latestBPM: Double?
    var latestBPMAt: Date?
    var restingBPM: Double?
    var hrvMs: Double?
    var walkingHRAvg: Double?
    var vo2Max: Double?

    static let empty = HeartSnapshot()

    var hasAny: Bool {
        latestBPM != nil || restingBPM != nil || hrvMs != nil || vo2Max != nil
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
    var oxygenSaturation: Double?     // 0...1 percent (latest sample avg)
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

enum HealthFormat {
    static func steps(_ v: Int?) -> String {
        guard let v else { return "—" }
        return NumberFormatter.localizedString(from: NSNumber(value: v), number: .decimal)
    }

    static func int(_ v: Double?) -> String {
        v.map { String(Int($0.rounded())) } ?? "—"
    }

    static func one(_ v: Double?, suffix: String = "") -> String {
        guard let v else { return "—" }
        return String(format: "%.1f%@", v, suffix)
    }

    static func kcal(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded())) kcal"
    }

    static func km(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v < 1 { return String(format: "%.0f m", v * 1000) }
        return String(format: "%.2f km", v)
    }

    static func minutes(_ v: Double?) -> String {
        guard let v else { return "—" }
        let h = Int(v) / 60
        let m = Int(v) % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int((v * 100).rounded()))%"
    }

    static func kg(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f kg", v)
    }
}
