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
