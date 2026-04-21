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
    private func loadSharingState() async {
        do {
            let record = try await privateDB.record(for: CloudKitConfig.liveStatusRecordID)
            let share = record.share != nil ? try? await fetchShare(for: record) : nil
            sharingEnabled = share != nil
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

    /// Called from inside `UICloudSharingController`'s preparation handler.
    /// Returns the CKShare + container that the controller should present
    /// the invite sheet for, after synchronously saving root record + share
    /// together in a single atomic operation. (CloudKit requires that a
    /// new share and its root record be saved together — otherwise it
    /// throws "An added share is being saved without its rootRecord".)
    func prepareShareForSheet(from status: LiveHeartStatus) async throws -> (CKShare, CKContainer) {
        guard accountStatus == .available else { throw SharingError.notSignedIn }
        isWorking = true
        defer { isWorking = false }

        await ensureZoneExists()

        // Fetch-or-create the root record. We always save a fresh set of fields
        // so the record *is* modified inside the save operation — avoids any
        // CloudKit optimizer deciding to skip the record write.
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

        // If a share already exists for this record, reuse it — don't try to
        // create a second share (that's a CKError).
        if let existingShareRef = record.share,
           let existingShare = try? await privateDB.record(for: existingShareRef.recordID) as? CKShare {
            self.sharingEnabled = true
            self.currentShareURL = existingShare.url
            self.lastPublishedStatus = status
            return (existingShare, container)
        }

        // New share. CKShare(rootRecord:) sets record.share → share for us;
        // we save both in one CKModifyRecordsOperation.
        let share = CKShare(rootRecord: record)
        share[CKShare.SystemFieldKey.title] = "\(status.displayName)'s Heart Rate" as CKRecordValue
        share[CKShare.SystemFieldKey.shareType] = "com.myheart.LiveHeartShare" as CKRecordValue
        share.publicPermission = .none   // only invited participants

        let saveOp = CKModifyRecordsOperation(recordsToSave: [record, share], recordIDsToDelete: nil)
        // `.allKeys` forces a write even when the local change tag matches the
        // server — CloudKit occasionally wants the root record present in the
        // same op as a new share, and this avoids any short-circuit skipping it.
        saveOp.savePolicy = .allKeys
        saveOp.qualityOfService = .userInitiated

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            saveOp.modifyRecordsResultBlock = { result in
                switch result {
                case .success:       cont.resume()
                case .failure(let e): cont.resume(throwing: SharingError.wrap(e))
                }
            }
            privateDB.add(saveOp)
        }

        self.sharingEnabled = true
        self.currentShareURL = share.url
        self.lastPublishedStatus = status
        return (share, container)
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
