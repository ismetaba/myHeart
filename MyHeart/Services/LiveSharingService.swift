import Foundation
import CloudKit
import UIKit

/// Subject-side + watcher-side operations for the live heart sharing feature.
///
/// **Design notes**
/// - Single CKRecord per user in their *private* database's custom
///   "MyHeartSharing" zone. Updates mutate the same record (low quota, low noise).
/// - Sharing is done via `CKShare` on that record. Each invited family member
///   becomes a `CKShare.Participant` and gets read access to the shared record
///   through their own *shared* database — the canonical Apple pattern.
/// - Writes are throttled (min 30s interval) and coalesced: we keep the newest
///   pending status and only flush when the throttle window opens or when the
///   change is "significant" (zone change, >10 BPM delta).
/// - All CloudKit errors are mapped to a small `SharingError` enum so the UI
///   can render user-friendly messages instead of CKError codes.
@MainActor
final class LiveSharingService: ObservableObject {
    static let shared = LiveSharingService()

    // MARK: - Published state
    //
    // These are write-gated by convention (only service code mutates them),
    // but we don't use `private(set)` because the watcher-side extension
    // lives in a separate file and needs write access.

    @Published var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published var sharingEnabled: Bool = false
    @Published var currentShareURL: URL?
    @Published var participantCount: Int = 0
    @Published var lastPublishedStatus: LiveHeartStatus?
    @Published var lastPublishError: String?
    @Published var followed: [FollowedPerson] = []
    @Published var isWorking: Bool = false

    // MARK: - Internals

    private let container: CKContainer
    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var sharedDB: CKDatabase  { container.sharedCloudDatabase }

    /// Throttle state for publishes.
    private var lastPublishAt: Date = .distantPast
    private var pendingStatus: LiveHeartStatus?
    private var flushTask: Task<Void, Never>?

    /// Minimum seconds between CloudKit writes.
    private let throttleInterval: TimeInterval = 30

    /// Significant delta in BPM that forces an immediate publish.
    private let significantBPMDelta: Int = 10

    private init(container: CKContainer = CKContainer(identifier: CloudKitConfig.containerIdentifier)) {
        self.container = container
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        await refreshAccountStatus()
        guard accountStatus == .available else { return }
        await ensureZoneExists()
        await loadSharingState()
        await refreshFollowed()
        await ensureSharedDBSubscription()
    }

    func refreshAccountStatus() async {
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            accountStatus = .couldNotDetermine
        }
    }

    // MARK: - Zone

    /// Ensures the custom zone exists before we try to write records in it.
    private func ensureZoneExists() async {
        do {
            let zone = CKRecordZone(zoneID: CloudKitConfig.zoneID)
            _ = try await privateDB.save(zone)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Already exists — fine.
        } catch {
            lastPublishError = SharingError.wrap(error).friendlyMessage
        }
    }

    // MARK: - Sharing state

    /// Public entry for re-reading sharing state after an external change
    /// (e.g. the UICloudSharingController added/removed a participant).
    func loadSharingStatePublic() async {
        await loadSharingState()
    }

    /// Whether we already have a live-status record + active share.
    /// A share without a populated URL is treated as "not active" — we don't
    /// want to flip the UI into the active state and then be stuck showing
    /// "Preparing invite link…" forever.
    private func loadSharingState() async {
        do {
            let record = try await privateDB.record(for: CloudKitConfig.liveStatusRecordID)
            let share = record.share != nil ? try? await fetchShare(for: record) : nil
            let hasUsableShare = (share?.url != nil)
            sharingEnabled = hasUsableShare
            currentShareURL = share?.url
            participantCount = max(0, (share?.participants.count ?? 0) - 1)  // minus self
            if let status = LiveHeartStatus(record: record) {
                lastPublishedStatus = status
            }
        } catch let error as CKError where error.code == .unknownItem {
            sharingEnabled = false
            currentShareURL = nil
            participantCount = 0
            lastPublishedStatus = nil
        } catch {
            lastPublishError = SharingError.wrap(error).friendlyMessage
        }
    }

    private func fetchShare(for record: CKRecord) async throws -> CKShare? {
        guard let reference = record.share else { return nil }
        let shareRecord = try await privateDB.record(for: reference.recordID)
        return shareRecord as? CKShare
    }

    // MARK: - Enable / share creation

    /// Ensures the user has a `LiveHeartStatus` CKRecord + a CKShare on it.
    /// Returns the server-saved CKShare (which has a live `.url`) and the
    /// container. Pulls the share out of `modifyRecords(saving:deleting:)`'s
    /// per-record save results, which is the reliable way to get server-side
    /// system fields like `url` populated.
    func prepareShareForSheet(from status: LiveHeartStatus) async throws -> (CKShare, CKContainer) {
        guard accountStatus == .available else { throw SharingError.notSignedIn }
        isWorking = true
        defer { isWorking = false }

        await ensureZoneExists()

        // --- Fetch-or-create the root record ---
        let record: CKRecord
        do {
            record = try await privateDB.record(for: CloudKitConfig.liveStatusRecordID)
            status.apply(to: record)
            LiveSharingService.log("fetched existing record, share ref: \(record.share?.recordID.recordName ?? "nil")")
        } catch let error as CKError where error.code == .unknownItem {
            LiveSharingService.log("no existing record, creating new")
            record = CKRecord(
                recordType: CloudKitConfig.RecordType.liveHeartStatus,
                recordID: CloudKitConfig.liveStatusRecordID
            )
            status.apply(to: record)
        }

        // --- Reuse existing share if it still has a server URL ---
        if let existingShareRef = record.share {
            do {
                let rec = try await privateDB.record(for: existingShareRef.recordID)
                if let existingShare = rec as? CKShare, existingShare.url != nil {
                    LiveSharingService.log("reusing existing share url=\(existingShare.url!.absoluteString)")
                    self.sharingEnabled = true
                    self.currentShareURL = existingShare.url
                    self.lastPublishedStatus = status
                    return (existingShare, container)
                }
            } catch {
                LiveSharingService.log("existing share fetch failed, will create fresh: \(error.localizedDescription)")
            }
        }

        // --- Create a fresh share bound to the record ---
        let share = CKShare(rootRecord: record)
        share[CKShare.SystemFieldKey.title] = "\(status.displayName)'s Heart Rate" as CKRecordValue
        share.publicPermission = .none   // only invited participants

        LiveSharingService.log("saving record + share atomically")
        let result: (saveResults: [CKRecord.ID: Result<CKRecord, Error>],
                     deleteResults: [CKRecord.ID: Result<Void, Error>])
        do {
            // Wrap in a 25s timeout so the UI never stays stuck on "Preparing…"
            // if CloudKit is unreachable or the container isn't provisioned.
            result = try await withThrowingTimeout(seconds: 25) {
                try await self.privateDB.modifyRecords(
                    saving: [record, share],
                    deleting: [],
                    savePolicy: .allKeys,
                    atomically: true
                )
            }
        } catch is CancellationError {
            let msg = "Save timed out after 25s. Check iCloud sign-in and network, then try again."
            LiveSharingService.log(msg)
            self.lastPublishError = msg
            throw SharingError.unknown(msg)
        } catch {
            let wrapped = SharingError.wrap(error)
            LiveSharingService.log("modifyRecords threw: \(error.localizedDescription) (\(type(of: error)))")
            self.lastPublishError = wrapped.friendlyMessage
            throw wrapped
        }

        // Log every per-record outcome — this is usually where CloudKit
        // partial-failure surprises hide.
        for (id, res) in result.saveResults {
            switch res {
            case .success(let r):
                LiveSharingService.log("saved \(id.recordName) (\(type(of: r)))")
            case .failure(let e):
                LiveSharingService.log("save failed \(id.recordName): \(e.localizedDescription)")
            }
        }

        switch result.saveResults[share.recordID] {
        case .success(let savedRecord):
            guard let savedShare = savedRecord as? CKShare else {
                let msg = "Saved record for share wasn't a CKShare (got \(type(of: savedRecord)))"
                self.lastPublishError = msg
                throw SharingError.unknown(msg)
            }
            guard let savedURL = savedShare.url else {
                let msg = "Share saved but URL hasn't populated yet. Try again in a moment."
                self.lastPublishError = msg
                throw SharingError.unknown(msg)
            }
            LiveSharingService.log("saved share url=\(savedURL.absoluteString)")

            self.sharingEnabled = true
            self.currentShareURL = savedURL
            self.lastPublishedStatus = status
            self.lastPublishError = nil
            return (savedShare, container)

        case .failure(let error):
            let wrapped = SharingError.wrap(error)
            self.lastPublishError = wrapped.friendlyMessage
            throw wrapped
        case .none:
            let msg = "Share was not included in the save results"
            self.lastPublishError = msg
            throw SharingError.unknown(msg)
        }
    }

    /// Races an async operation against a deadline. Throws `CancellationError`
    /// on timeout. The underlying task is cancelled too, so CloudKit stops
    /// reference-counting it.
    private func withThrowingTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Log helper — prefixed so it's grep-able in Xcode console.
    private static func log(_ msg: @autoclosure () -> String) {
        #if DEBUG
        print("[Sharing] \(msg())")
        #endif
    }

    // MARK: - Stop sharing

    /// Deletes the share (and optionally the record). Existing watchers lose access.
    func stopSharing(deleteRecord: Bool = false) async throws {
        guard accountStatus == .available else { throw SharingError.notSignedIn }
        isWorking = true
        defer { isWorking = false }

        do {
            let record = try await privateDB.record(for: CloudKitConfig.liveStatusRecordID)
            if let shareRef = record.share {
                _ = try await privateDB.deleteRecord(withID: shareRef.recordID)
            }
            if deleteRecord {
                _ = try await privateDB.deleteRecord(withID: record.recordID)
            }
            sharingEnabled = false
            currentShareURL = nil
            participantCount = 0
            if deleteRecord { lastPublishedStatus = nil }
        } catch let error as CKError where error.code == .unknownItem {
            sharingEnabled = false
            currentShareURL = nil
            participantCount = 0
        } catch {
            throw SharingError.wrap(error)
        }
    }

    // MARK: - Publishing (throttled)

    /// Public entry point used by HeartRateViewModel when new data is available.
    /// Coalesces rapid calls: only the most recent status survives until the
    /// throttle window opens.
    func publish(_ status: LiveHeartStatus) {
        guard sharingEnabled, accountStatus == .available else {
            pendingStatus = status  // keep latest just in case we enable later
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastPublishAt)
        let isSignificant = isSignificantChange(status)

        if elapsed >= throttleInterval || isSignificant {
            pendingStatus = status
            flushNow()
        } else {
            // Coalesce: keep latest and schedule a flush at the throttle boundary.
            pendingStatus = status
            scheduleFlush(after: throttleInterval - elapsed)
        }
    }

    private func isSignificantChange(_ new: LiveHeartStatus) -> Bool {
        guard let last = lastPublishedStatus else { return true }
        if new.zoneRaw != last.zoneRaw { return true }
        if abs(new.currentBPM - last.currentBPM) >= significantBPMDelta { return true }
        if new.isElevated != last.isElevated { return true }
        // Emergency transitions always bypass the throttle — safety over quota.
        if new.isEmergency != last.isEmergency { return true }
        if new.emergencyKind != last.emergencyKind { return true }
        return false
    }

    private func scheduleFlush(after delay: TimeInterval) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.flushNow()
        }
    }

    private func flushNow() {
        Task { @MainActor in await self.flushNowAsync() }
    }

    private func flushNowAsync() async {
        guard let status = pendingStatus, sharingEnabled else { return }
        pendingStatus = nil
        do {
            try await writeStatus(status)
            lastPublishAt = Date()
            lastPublishedStatus = status
            lastPublishError = nil
        } catch {
            lastPublishError = SharingError.wrap(error).friendlyMessage
        }
    }

    private func writeStatus(_ status: LiveHeartStatus) async throws {
        let record: CKRecord
        do {
            record = try await privateDB.record(for: CloudKitConfig.liveStatusRecordID)
            status.apply(to: record)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(
                recordType: CloudKitConfig.RecordType.liveHeartStatus,
                recordID: CloudKitConfig.liveStatusRecordID
            )
            status.apply(to: record)
        }
        _ = try await privateDB.save(record)
    }
}
