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

    /// Creates the live-status record + a CKShare if needed, and returns the
    /// record + share so the caller can present `UICloudSharingController`.
    func prepareShare(from status: LiveHeartStatus) async throws -> (CKRecord, CKShare) {
        guard accountStatus == .available else { throw SharingError.notSignedIn }
        isWorking = true
        defer { isWorking = false }

        // Ensure zone
        await ensureZoneExists()

        // Fetch-or-create the record
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

        // Check for existing share
        if let existing = try await fetchShare(for: record) {
            return (record, existing)
        }

        // Create a new share
        let share = CKShare(rootRecord: record)
        share[CKShare.SystemFieldKey.title] = "\(status.displayName)'s Heart Rate" as CKRecordValue
        share[CKShare.SystemFieldKey.shareType] = "com.myheart.LiveHeartShare" as CKRecordValue
        share.publicPermission = .none   // only invited participants

        let saveOp = CKModifyRecordsOperation(recordsToSave: [record, share], recordIDsToDelete: nil)
        saveOp.savePolicy = .ifServerRecordUnchanged
        return try await withCheckedThrowingContinuation { cont in
            saveOp.modifyRecordsResultBlock = { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.sharingEnabled = true
                        self.currentShareURL = share.url
                        self.lastPublishedStatus = status
                        cont.resume(returning: (record, share))
                    case .failure(let error):
                        cont.resume(throwing: SharingError.wrap(error))
                    }
                }
            }
            privateDB.add(saveOp)
        }
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
