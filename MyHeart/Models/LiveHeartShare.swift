import Foundation
import CloudKit

/// CloudKit record-type / key constants used by the live-sharing feature.
/// Kept in one place so the record schema stays consistent between reader
/// and writer code paths.
enum CloudKitConfig {
    /// iCloud container identifier. Matches the entry in the app entitlements.
    static let containerIdentifier = "iCloud.com.myheart.MyHeart"

    /// Single custom zone used for shared records. Default zone records can't
    /// be shared with CKShare, so we use a dedicated custom zone.
    static let zoneName = "MyHeartSharing"

    /// Stable record name for the current user's single live-status record.
    /// Because the record lives in a user-private zone, this name is unique
    /// per account.
    static let liveStatusRecordName = "LiveHeartStatus-root"

    enum RecordType {
        static let liveHeartStatus = "LiveHeartStatus"
    }

    /// Keys on the `LiveHeartStatus` record.
    enum Key {
        static let currentBPM      = "currentBPM"       // Int64
        static let zoneRaw         = "zoneRaw"          // String (HeartRateZone.rawValue)
        static let restingBPM      = "restingBPM"       // Int64?
        static let hrvMs           = "hrvMs"            // Double?
        static let updatedAt       = "updatedAt"        // Date
        static let isElevated      = "isElevated"       // Int64 (0/1)
        static let elevatedThresh  = "elevatedThreshold"// Int64
        static let displayName     = "displayName"      // String
        static let deviceName      = "deviceName"       // String?
        static let maxHR           = "maxHR"            // Int64 (for zone decoding on watcher)
        static let note            = "note"             // String? (optional user note, e.g. "Resting at home")
        static let source          = "source"           // String? (Apple Watch model / iPhone name)

        // Trend (last 24h)
        static let trendHourlyBPM  = "trendHourlyBPM"   // [Int64] — 24 values, oldest→newest
        static let trendUpdatedAt  = "trendUpdatedAt"   // Date

        // Emergency flags
        static let isEmergency     = "isEmergency"      // Int64 (0/1)
        static let emergencyKind   = "emergencyKind"    // String? ("high" / "low" / "sustainedHigh")
        static let emergencySince  = "emergencySince"   // Date?
    }

    /// APNs-level subscription IDs managed by the watcher.
    enum SubscriptionID {
        static let sharedDBChanges = "myheart.shared-db-changes"
    }

    /// BGTaskScheduler identifiers — must match `BGTaskSchedulerPermittedIdentifiers`
    /// in Info.plist.
    enum BackgroundTask {
        static let familyRefresh = "com.myheart.family-refresh"
    }

    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    static var liveStatusRecordID: CKRecord.ID {
        CKRecord.ID(recordName: liveStatusRecordName, zoneID: zoneID)
    }
}

/// Lightweight, value-type representation of the live-heart record.
/// Decoupled from `CKRecord` so UI code doesn't depend on CloudKit types.
struct LiveHeartStatus: Hashable, Identifiable {
    var id: String                  // record name
    var ownerID: String?            // CKShare participant ID when followed
    var currentBPM: Int
    var zoneRaw: String
    var restingBPM: Int?
    var hrvMs: Double?
    var updatedAt: Date
    var isElevated: Bool
    var elevatedThreshold: Int
    var displayName: String
    var deviceName: String?
    var maxHR: Int
    var note: String?

    // Trend (hourly averages over the last 24h, oldest→newest, zeros for gaps)
    var trendHourlyBPM: [Int] = []
    var trendUpdatedAt: Date?

    // Emergency
    var isEmergency: Bool = false
    var emergencyKind: EmergencyKind? = nil
    var emergencySince: Date? = nil

    var zone: HeartRateZone {
        HeartRateZone(rawValue: zoneRaw) ?? HeartRateZone(bpm: Double(currentBPM), maxHR: Double(maxHR))
    }

    /// Seconds since last update. Handy for "X min ago" UI + stale data checks.
    var secondsSinceUpdate: TimeInterval {
        Date().timeIntervalSince(updatedAt)
    }

    var isStale: Bool {
        secondsSinceUpdate > 300  // 5 min
    }
}

/// Kind of emergency flagged on a live heart record. Watchers use this to
/// choose which message/banner to show.
enum EmergencyKind: String, Hashable, Codable {
    case high           // Acute high (single spike ≥ criticalHighBPM)
    case sustainedHigh  // Sustained high (multiple samples above threshold)
    case low            // Dangerously low HR

    var label: String {
        switch self {
        case .high:          return "Heart rate critically high"
        case .sustainedHigh: return "Elevated heart rate for an extended period"
        case .low:           return "Heart rate critically low"
        }
    }

    var systemImage: String {
        switch self {
        case .high, .sustainedHigh: return "exclamationmark.triangle.fill"
        case .low:                  return "arrow.down.heart.fill"
        }
    }
}

extension LiveHeartStatus {
    init?(record: CKRecord) {
        guard
            let bpm = record[CloudKitConfig.Key.currentBPM] as? Int64,
            let zoneRaw = record[CloudKitConfig.Key.zoneRaw] as? String,
            let updatedAt = record[CloudKitConfig.Key.updatedAt] as? Date,
            let displayName = record[CloudKitConfig.Key.displayName] as? String,
            let maxHR = record[CloudKitConfig.Key.maxHR] as? Int64
        else { return nil }

        self.id = record.recordID.recordName
        self.ownerID = record.creatorUserRecordID?.recordName
        self.currentBPM = Int(bpm)
        self.zoneRaw = zoneRaw
        self.restingBPM = (record[CloudKitConfig.Key.restingBPM] as? Int64).map(Int.init)
        self.hrvMs = record[CloudKitConfig.Key.hrvMs] as? Double
        self.updatedAt = updatedAt
        self.isElevated = ((record[CloudKitConfig.Key.isElevated] as? Int64) ?? 0) != 0
        self.elevatedThreshold = Int((record[CloudKitConfig.Key.elevatedThresh] as? Int64) ?? 100)
        self.displayName = displayName
        self.deviceName = record[CloudKitConfig.Key.deviceName] as? String
        self.maxHR = Int(maxHR)
        self.note = record[CloudKitConfig.Key.note] as? String

        // Trend
        let rawTrend = (record[CloudKitConfig.Key.trendHourlyBPM] as? [Int64]) ?? []
        self.trendHourlyBPM = rawTrend.map(Int.init)
        self.trendUpdatedAt = record[CloudKitConfig.Key.trendUpdatedAt] as? Date

        // Emergency
        self.isEmergency = ((record[CloudKitConfig.Key.isEmergency] as? Int64) ?? 0) != 0
        if let rawKind = record[CloudKitConfig.Key.emergencyKind] as? String {
            self.emergencyKind = EmergencyKind(rawValue: rawKind)
        }
        self.emergencySince = record[CloudKitConfig.Key.emergencySince] as? Date
    }

    /// Apply this status onto a CKRecord. Returns the same record for chaining.
    @discardableResult
    func apply(to record: CKRecord) -> CKRecord {
        record[CloudKitConfig.Key.currentBPM]       = Int64(currentBPM)
        record[CloudKitConfig.Key.zoneRaw]          = zoneRaw
        if let restingBPM { record[CloudKitConfig.Key.restingBPM] = Int64(restingBPM) }
        else              { record[CloudKitConfig.Key.restingBPM] = nil }
        record[CloudKitConfig.Key.hrvMs]            = hrvMs
        record[CloudKitConfig.Key.updatedAt]        = updatedAt
        record[CloudKitConfig.Key.isElevated]       = Int64(isElevated ? 1 : 0)
        record[CloudKitConfig.Key.elevatedThresh]   = Int64(elevatedThreshold)
        record[CloudKitConfig.Key.displayName]      = displayName
        record[CloudKitConfig.Key.deviceName]       = deviceName
        record[CloudKitConfig.Key.maxHR]            = Int64(maxHR)
        record[CloudKitConfig.Key.note]             = note

        // Trend — only overwrite if we have one (preserves prior trend on
        // status writes that don't recompute it).
        if !trendHourlyBPM.isEmpty {
            record[CloudKitConfig.Key.trendHourlyBPM] = trendHourlyBPM.map { Int64($0) }
            record[CloudKitConfig.Key.trendUpdatedAt] = trendUpdatedAt
        }

        // Emergency
        record[CloudKitConfig.Key.isEmergency]    = Int64(isEmergency ? 1 : 0)
        record[CloudKitConfig.Key.emergencyKind]  = emergencyKind?.rawValue
        record[CloudKitConfig.Key.emergencySince] = emergencySince
        return record
    }
}

/// Represents one person the current user follows. Backed by a shared
/// `LiveHeartStatus` record living in the shared database.
struct FollowedPerson: Hashable, Identifiable {
    var id: String              // shared record zone name — stable per sharer
    var zoneID: CKRecordZone.ID
    var recordID: CKRecord.ID
    var status: LiveHeartStatus
    var lastFetchedAt: Date
    var alertThresholdBPM: Int?     // local, not shared
    var isPinned: Bool = false      // local favorite
}
