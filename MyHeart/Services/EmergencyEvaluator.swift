import Foundation

/// Pure logic for deciding whether a given heart-rate state should be
/// flagged as an emergency. Kept free of CloudKit / HealthKit so it's
/// trivial to unit-test and reuse.
enum EmergencyEvaluator {
    /// Parameters describing how sustained "elevated" must be before we
    /// escalate it from "elevated" to "sustainedHigh" emergency.
    struct Thresholds: Hashable {
        var criticalHighBPM: Int       // acute spike threshold
        var criticalLowBPM: Int        // dangerous low threshold
        var sustainedHighBPM: Int      // above this for sustainedMinutes triggers sustainedHigh
        var sustainedMinutes: Int      // ≥ this many minutes continuously above sustainedHighBPM

        static let defaults = Thresholds(
            criticalHighBPM: 160,
            criticalLowBPM: 40,
            sustainedHighBPM: 120,
            sustainedMinutes: 10
        )
    }

    /// The evaluator sees the current sample plus a short recent history
    /// (assumed to be sorted ascending by date). The history is only used
    /// for the "sustained" check.
    static func evaluate(
        currentBPM: Int,
        recent: [HeartRateSample],
        thresholds: Thresholds = .defaults,
        now: Date = Date()
    ) -> (kind: EmergencyKind?, since: Date?) {
        // Critical high spike
        if currentBPM >= thresholds.criticalHighBPM {
            let since = firstMomentAbove(samples: recent, bpm: thresholds.sustainedHighBPM, now: now) ?? now
            return (.high, since)
        }

        // Critical low
        if currentBPM > 0 && currentBPM <= thresholds.criticalLowBPM {
            return (.low, now)
        }

        // Sustained high over N minutes
        if currentBPM >= thresholds.sustainedHighBPM {
            if let since = firstMomentAbove(samples: recent, bpm: thresholds.sustainedHighBPM, now: now),
               now.timeIntervalSince(since) >= TimeInterval(thresholds.sustainedMinutes * 60) {
                return (.sustainedHigh, since)
            }
        }

        return (nil, nil)
    }

    /// Walks `samples` from newest to oldest and returns the timestamp at
    /// which the value first fell below `bpm`. If every sample is above
    /// `bpm`, returns the oldest sample's date. Used to compute "since".
    private static func firstMomentAbove(samples: [HeartRateSample], bpm: Int, now: Date) -> Date? {
        guard !samples.isEmpty else { return nil }
        let desc = samples.sorted { $0.date > $1.date }
        var boundary: Date? = nil
        for s in desc {
            if Int(s.bpm.rounded()) >= bpm {
                boundary = s.date
            } else {
                break
            }
        }
        return boundary
    }
}
