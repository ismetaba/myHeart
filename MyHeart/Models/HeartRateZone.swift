import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Five-zone heart rate model derived from a user's max HR.
/// Thresholds follow a common fitness convention (% of max HR).
enum HeartRateZone: String, CaseIterable, Identifiable, Hashable {
    case resting     // < 50%
    case warmUp      // 50–60%
    case fatBurn     // 60–70%
    case cardio      // 70–85%
    case peak        // ≥ 85%

    var id: String { rawValue }

    /// Classify a BPM value into a zone given the user's max heart rate.
    init(bpm: Double, maxHR: Double) {
        let pct = maxHR > 0 ? bpm / maxHR : 0
        switch pct {
        case ..<0.50:  self = .resting
        case 0.50..<0.60: self = .warmUp
        case 0.60..<0.70: self = .fatBurn
        case 0.70..<0.85: self = .cardio
        default:          self = .peak
        }
    }

    var label: String {
        switch self {
        case .resting: return "Resting"
        case .warmUp:  return "Warm Up"
        case .fatBurn: return "Fat Burn"
        case .cardio:  return "Cardio"
        case .peak:    return "Peak"
        }
    }

    /// Lower bound as fraction of max HR (inclusive).
    var lowerFraction: Double {
        switch self {
        case .resting: return 0.00
        case .warmUp:  return 0.50
        case .fatBurn: return 0.60
        case .cardio:  return 0.70
        case .peak:    return 0.85
        }
    }

    /// Upper bound as fraction of max HR (exclusive, except `peak`).
    var upperFraction: Double {
        switch self {
        case .resting: return 0.50
        case .warmUp:  return 0.60
        case .fatBurn: return 0.70
        case .cardio:  return 0.85
        case .peak:    return 1.00
        }
    }

    func range(maxHR: Double) -> ClosedRange<Int> {
        let lo = Int((lowerFraction * maxHR).rounded())
        let hi = Int((upperFraction * maxHR).rounded())
        return lo...max(lo + 1, hi)
    }

    var color: Color {
        switch self {
        case .resting: return Color(red: 0.52, green: 0.60, blue: 0.72)   // cool gray-blue
        case .warmUp:  return Color(red: 0.30, green: 0.67, blue: 0.85)   // sky blue
        case .fatBurn: return Color(red: 0.35, green: 0.78, blue: 0.45)   // green
        case .cardio:  return Color(red: 0.98, green: 0.64, blue: 0.24)   // orange
        case .peak:    return Color(red: 0.92, green: 0.26, blue: 0.38)   // red
        }
    }

    #if canImport(UIKit)
    /// UIKit color for PDF rendering. Mirrors `color`.
    var uiColor: UIColor {
        switch self {
        case .resting: return UIColor(red: 0.52, green: 0.60, blue: 0.72, alpha: 1)
        case .warmUp:  return UIColor(red: 0.30, green: 0.67, blue: 0.85, alpha: 1)
        case .fatBurn: return UIColor(red: 0.35, green: 0.78, blue: 0.45, alpha: 1)
        case .cardio:  return UIColor(red: 0.98, green: 0.64, blue: 0.24, alpha: 1)
        case .peak:    return UIColor(red: 0.92, green: 0.26, blue: 0.38, alpha: 1)
        }
    }
    #endif

    var systemImage: String {
        switch self {
        case .resting: return "leaf.fill"
        case .warmUp:  return "figure.walk"
        case .fatBurn: return "flame.fill"
        case .cardio:  return "bolt.heart.fill"
        case .peak:    return "flame.circle.fill"
        }
    }

    var short: String {
        switch self {
        case .resting: return "Rest"
        case .warmUp:  return "Warm"
        case .fatBurn: return "Fat"
        case .cardio:  return "Card"
        case .peak:    return "Peak"
        }
    }
}

/// Time-in-zone results for one range of samples.
struct ZoneBreakdown: Hashable {
    /// Duration per zone, in seconds.
    let durations: [HeartRateZone: TimeInterval]
    /// Sample count per zone (useful for sparse data).
    let counts: [HeartRateZone: Int]
    /// Total duration counted (sum of clipped gaps), in seconds.
    let totalDuration: TimeInterval

    static let empty = ZoneBreakdown(durations: [:], counts: [:], totalDuration: 0)

    func duration(_ zone: HeartRateZone) -> TimeInterval { durations[zone] ?? 0 }
    func count(_ zone: HeartRateZone) -> Int { counts[zone] ?? 0 }

    func fraction(_ zone: HeartRateZone) -> Double {
        guard totalDuration > 0 else { return 0 }
        return duration(zone) / totalDuration
    }

    var dominantZone: HeartRateZone? {
        HeartRateZone.allCases.max { duration($0) < duration($1) }
    }
}

enum HeartRateZoneAnalyzer {
    /// Time-in-zone using a gap-clipping approach:
    /// - Each sample represents the time until the next sample, clipped to `maxGap`.
    /// - The last sample contributes `finalTail` seconds.
    /// This avoids a single sample with a long gap dominating the result while still
    /// giving real-time estimates (unlike a pure sample-count histogram).
    static func breakdown(
        samples: [HeartRateSample],
        maxHR: Double,
        maxGap: TimeInterval = 300,
        finalTail: TimeInterval = 60
    ) -> ZoneBreakdown {
        guard !samples.isEmpty else { return .empty }
        let sorted = samples.sorted { $0.date < $1.date }
        var durations: [HeartRateZone: TimeInterval] = [:]
        var counts: [HeartRateZone: Int] = [:]
        var total: TimeInterval = 0

        for i in 0..<sorted.count {
            let s = sorted[i]
            let zone = HeartRateZone(bpm: s.bpm, maxHR: maxHR)
            counts[zone, default: 0] += 1
            let dt: TimeInterval
            if i + 1 < sorted.count {
                let gap = sorted[i + 1].date.timeIntervalSince(s.date)
                dt = min(max(gap, 0), maxGap)
            } else {
                dt = finalTail
            }
            durations[zone, default: 0] += dt
            total += dt
        }
        return ZoneBreakdown(durations: durations, counts: counts, totalDuration: total)
    }
}

/// Human-friendly duration formatting.
enum DurationFormat {
    static func compact(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        return String(format: "%d:%02d", h, m)
    }
}
