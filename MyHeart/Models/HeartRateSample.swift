import Foundation

struct HeartRateSample: Identifiable, Hashable {
    let id: UUID
    let bpm: Double
    let date: Date
    let source: String

    init(id: UUID = UUID(), bpm: Double, date: Date, source: String) {
        self.id = id
        self.bpm = bpm
        self.date = date
        self.source = source
    }
}

struct HeartRateSummary: Hashable {
    let latest: HeartRateSample?
    let restingBPM: Double?
    let averageBPM: Double?
    let minBPM: Double?
    let maxBPM: Double?
    let hrvSDNN: Double?
    let sampleCount: Int
    let rangeStart: Date
    let rangeEnd: Date

    static let empty = HeartRateSummary(
        latest: nil, restingBPM: nil, averageBPM: nil,
        minBPM: nil, maxBPM: nil, hrvSDNN: nil,
        sampleCount: 0,
        rangeStart: Date(), rangeEnd: Date()
    )
}

struct DailyHeartRateStats: Identifiable, Hashable {
    let id: UUID
    let day: Date              // start of day
    let minBPM: Double?
    let avgBPM: Double?
    let maxBPM: Double?
    let restingBPM: Double?
    let sampleCount: Int

    init(
        id: UUID = UUID(),
        day: Date,
        minBPM: Double?,
        avgBPM: Double?,
        maxBPM: Double?,
        restingBPM: Double?,
        sampleCount: Int
    ) {
        self.id = id
        self.day = day
        self.minBPM = minBPM
        self.avgBPM = avgBPM
        self.maxBPM = maxBPM
        self.restingBPM = restingBPM
        self.sampleCount = sampleCount
    }
}

/// One time bucket of heart-rate samples — used to draw long ranges without
/// handing tens of thousands of marks to Swift Charts / the PDF renderer.
struct HeartRateBucket: Identifiable, Hashable {
    var id: Date { start }
    let start: Date
    let end: Date
    let minBPM: Double
    let avgBPM: Double
    let maxBPM: Double
    let count: Int

    var mid: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }

    /// Splits `[start, end)` into `maxBuckets` equal slices and aggregates the
    /// samples falling into each one. Empty slices are omitted.
    static func make(
        from samples: [HeartRateSample],
        start: Date,
        end: Date,
        maxBuckets: Int
    ) -> [HeartRateBucket] {
        guard !samples.isEmpty, maxBuckets > 0, end > start else { return [] }
        let span = end.timeIntervalSince(start)
        let width = span / Double(maxBuckets)

        var mins = [Double](repeating: .greatestFiniteMagnitude, count: maxBuckets)
        var maxs = [Double](repeating: -.greatestFiniteMagnitude, count: maxBuckets)
        var sums = [Double](repeating: 0, count: maxBuckets)
        var counts = [Int](repeating: 0, count: maxBuckets)

        for sample in samples {
            let offset = sample.date.timeIntervalSince(start)
            guard offset >= 0, offset <= span else { continue }
            let index = min(maxBuckets - 1, Int(offset / width))
            mins[index] = min(mins[index], sample.bpm)
            maxs[index] = max(maxs[index], sample.bpm)
            sums[index] += sample.bpm
            counts[index] += 1
        }

        var buckets: [HeartRateBucket] = []
        buckets.reserveCapacity(maxBuckets)
        for index in 0..<maxBuckets where counts[index] > 0 {
            let bucketStart = start.addingTimeInterval(Double(index) * width)
            buckets.append(HeartRateBucket(
                start: bucketStart,
                end: bucketStart.addingTimeInterval(width),
                minBPM: mins[index],
                avgBPM: sums[index] / Double(counts[index]),
                maxBPM: maxs[index],
                count: counts[index]
            ))
        }
        return buckets
    }
}
