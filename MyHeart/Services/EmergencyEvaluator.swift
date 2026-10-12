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
    /// (any order). `now` must be the time of the current sample — not the
    /// wall clock — otherwise a single reading that synced a few minutes late
    /// would look like it had been "sustained" for that long.
    static func evaluate(
        currentBPM: Int,
        recent: [HeartRateSample],
        thresholds: Thresholds = .defaults,
        now: Date = Date()
    ) -> (kind: EmergencyKind?, since: Date?) {
        let history = recent.filter { $0.date <= now }

        // Critical high spike
        if currentBPM >= thresholds.criticalHighBPM {
            let since = startOfRun(in: history) { $0 >= thresholds.sustainedHighBPM } ?? now
            return (.high, since)
        }

        // Critical low
        if currentBPM > 0 && currentBPM <= thresholds.criticalLowBPM {
            let since = startOfRun(in: history) { $0 > 0 && $0 <= thresholds.criticalLowBPM } ?? now
            return (.low, since)
        }

        // Sustained high over N minutes
        if currentBPM >= thresholds.sustainedHighBPM {
            if let since = startOfRun(in: history, where: { $0 >= thresholds.sustainedHighBPM }),
               now.timeIntervalSince(since) >= TimeInterval(thresholds.sustainedMinutes * 60) {
                return (.sustainedHigh, since)
            }
        }

        return (nil, nil)
    }

    /// Walks `samples` from newest to oldest while `matches` holds and returns
    /// the date of the oldest sample in that unbroken run (nil if the newest
    /// sample doesn't match). Used to compute "since".
    private static func startOfRun(in samples: [HeartRateSample], where matches: (Int) -> Bool) -> Date? {
        var boundary: Date? = nil
        for s in samples.sorted(by: { $0.date > $1.date }) {
            guard matches(Int(s.bpm.rounded())) else { break }
            boundary = s.date
        }
        return boundary
    }
}
