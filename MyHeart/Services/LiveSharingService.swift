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
/// - Writes are throttled (min 30s interval), coalesced and serialized: we
///   keep the newest pending status, only one save is in flight at a time,
///   and "significant" changes (zone change, >10 BPM delta, emergency
///   transitions) bypass the throttle.
/// - The last saved CKRecord is cached so each update is a single round trip;
///   a `serverRecordChanged` conflict (another of the user's devices wrote
///   first) is rebased onto the server copy and retried once.
/// - All CloudKit errors are mapped to `SharingError` so the UI can render
///   user-friendly messages instead of CKError codes.
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
    /// Problems with *my* sharing (enable, publish, stop).
    @Published var lastError: SharingError?
    /// Problems on the follower side (accepting invites, refreshing, unfollowing).
    @Published var followError: SharingError?
    @Published var followed: [FollowedPerson] = []
    @Published var isWorking: Bool = false
    @Published var isRefreshingFollowed: Bool = false

    // MARK: - Internals

    let container: CKContainer
    var privateDB: CKDatabase { container.privateCloudDatabase }
    var sharedDB: CKDatabase { container.sharedCloudDatabase }

    /// Set once the sharing state was read from iCloud for the current account.
    private var didLoadSharingState = false
    private var zoneConfirmed = false
    private var bootstrapTask: Task<Void, Never>?
    private var hasBootstrapped = false
    private var accountObserver: NSObjectProtocol?

    /// Last record returned by the server; reused for the next write.
    private var cachedRecord: CKRecord?

    /// Throttle / coalescing state for publishes.
    private var lastPublishAt: Date = .distantPast
    private var pendingStatus: LiveHeartStatus?
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false

    /// Minimum seconds between CloudKit writes.
    private let throttleInterval: TimeInterval = 30

    /// Significant delta in BPM that forces an immediate publish.
    private let significantBPMDelta: Int = 10

    private init(container: CKContainer = CKContainer(identifier: CloudKitConfig.containerIdentifier)) {
        self.container = container
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.handleAccountChange() }
        }
    }

    // MARK: - Bootstrap

    /// Loads account status, my sharing state and the people I follow.
    /// Concurrent callers share one run.
    func bootstrap() async {
        if let running = bootstrapTask {
            await running.value
            return
        }
        let task = Task { @MainActor in
            await self.performBootstrap()
            // Cleared inside the task so anyone awaiting it can immediately
            // start a fresh bootstrap afterwards.
            self.bootstrapTask = nil
            self.hasBootstrapped = true
        }
        bootstrapTask = task
        await task.value
    }

    /// Cheap catch-up when the app returns to the foreground: re-read my share
    /// (participants may have joined) and the people I follow.
    func refreshOnForeground() async {
        guard hasBootstrapped, bootstrapTask == nil else { return }
        await refreshAccountStatus()
        guard accountStatus == .available else { return }
        await loadSharingState()
        await refreshFollowed()
        await evaluateAlerts()
    }

    private func performBootstrap() async {
        await refreshAccountStatus()
        switch accountStatus {
        case .available:
            break
        case .noAccount, .restricted:
            resetForSignedOutAccount()
            return
        default:
            return
        }
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

    /// Lightweight readiness check used by background publishes: makes sure we
    /// know the account status and whether a share exists, without the full
    /// bootstrap (followed list, subscriptions).
    func prepareForPublishing() async {
        if accountStatus != .available {
            await refreshAccountStatus()
        }
        guard accountStatus == .available, !didLoadSharingState else { return }
        await loadSharingState()
    }

    private func handleAccountChange() async {
        let previousStatus = accountStatus
        // Anything cached from the server may belong to another Apple ID now.
        zoneConfirmed = false
        didLoadSharingState = false
        cachedRecord = nil
        await refreshAccountStatus()

        let signedOut = accountStatus == .noAccount || accountStatus == .restricted
        let signedBackIn = accountStatus == .available
            && (previousStatus == .noAccount || previousStatus == .restricted)
        if signedOut || signedBackIn {
            LiveSharingService.log("iCloud account changed — starting from a clean slate")
            flushTask?.cancel()
            flushTask = nil
            pendingStatus = nil
            lastPublishedStatus = nil
            sharingEnabled = false
            currentShareURL = nil
            participantCount = 0
            followed = []
            lastError = nil
            followError = nil
        }
        // iOS also posts this notification on some launches; re-reading
        // everything is harmless. Wait for a running bootstrap so the reload
        // actually happens with the new account.
        if let running = bootstrapTask {
            await running.value
        }
        await bootstrap()
    }

    private func resetForSignedOutAccount() {
        didLoadSharingState = false
        zoneConfirmed = false
        cachedRecord = nil
        pendingStatus = nil
        sharingEnabled = false
        currentShareURL = nil
        participantCount = 0
        followed = []
    }

    // MARK: - Zone

    /// Ensures the custom zone exists before we try to write records in it.
    /// Saving an existing zone is a no-op on the server.
    private func ensureZoneExists() async {
        guard !zoneConfirmed else { return }
        do {
            _ = try await privateDB.save(CKRecordZone(zoneID: CloudKitConfig.zoneID))
            zoneConfirmed = true
        } catch let error as CKError where error.code == .serverRecordChanged {
            zoneConfirmed = true
        } catch {
            lastError = SharingError.wrap(error)
        }
    }

    // MARK: - Sharing state

    /// Re-reads whether a live-status record + usable share exist.
    /// A share without a populated URL is treated as "not active" — we don't
    /// want to flip the UI into the active state and then be stuck showing
    /// "Preparing invite link…" forever.
    func loadSharingState() async {
        guard accountStatus == .available else { return }
        do {
            let record = try await privateDB.record(for: CloudKitConfig.liveStatusRecordID)
            cachedRecord = record
            if record.share != nil {
                do {
                    applyShareState(try await fetchShare(for: record))
                } catch let error as CKError where error.code == .unknownItem {
                    applyShareState(nil)  // the share was deleted
                } catch {
                    // A network blip must not flip sharing "off"; keep the
                    // current state and try again on the next load.
                    lastError = SharingError.wrap(error)
                    return
                }
            } else {
                applyShareState(nil)
            }
            if let status = LiveHeartStatus(record: record) {
                lastPublishedStatus = status
            }
            didLoadSharingState = true
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            cachedRecord = nil
            applyShareState(nil)
            lastPublishedStatus = nil
            didLoadSharingState = true
        } catch {
            lastError = SharingError.wrap(error)
            return
        }

        // Anything computed before we knew sharing was on can go out now.
        if sharingEnabled, pendingStatus != nil {
            await flush()
        }
    }

    private func applyShareState(_ share: CKShare?) {
        let url = share?.url
        sharingEnabled = url != nil
        currentShareURL = url
        let others = share?.participants.filter { $0.role != .owner } ?? []
        participantCount = others.filter { $0.acceptanceStatus == .accepted }.count
    }

    private func fetchShare(for record: CKRecord) async throws -> CKShare? {
        guard let reference = record.share else { return nil }
        let shareRecord = try await privateDB.record(for: reference.recordID)
        return shareRecord as? CKShare
    }

    // MARK: - Enable / share creation

    /// Ensures the user has a `LiveHeartStatus` CKRecord + a CKShare on it and
    /// returns the invite URL. Pulls the share out of
    /// `modifyRecords(saving:deleting:)`'s per-record save results, which is
    /// the reliable way to get server-side system fields like `url` populated.
    @discardableResult
    func startSharing(with status: LiveHeartStatus) async throws -> URL {
        guard accountStatus == .available else { throw fail(.notSignedIn) }
        isWorking = true
        defer { isWorking = false }
        lastError = nil

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
        } catch {
            throw fail(SharingError.wrap(error))
        }

        // --- Reuse existing share if it still has a server URL ---
        // Upgrade its publicPermission to .readOnly if needed: sharing the URL
        // via Messages / Mail / AirDrop delivers the invite to arbitrary
        // Apple IDs, and with `.none` those recipients see "Item Unavailable"
        // because they aren't explicit participants.
        if let existingShareRef = record.share {
            do {
                let rec = try await privateDB.record(for: existingShareRef.recordID)
                if let existingShare = rec as? CKShare, let url = existingShare.url {
                    var shareToReport = existingShare
                    if existingShare.publicPermission != .readOnly {
                        LiveSharingService.log("upgrading existing share publicPermission → readOnly")
                        existingShare.publicPermission = .readOnly
                        if let saved = try await privateDB.save(existingShare) as? CKShare {
                            shareToReport = saved
                        }
                    }
                    // Push the fresh status onto the record too.
                    cachedRecord = try? await privateDB.save(record)
                    LiveSharingService.log("reusing existing share url=\(url.absoluteString)")
                    applyShareState(shareToReport)
                    lastPublishedStatus = status
                    lastPublishAt = Date()
                    didLoadSharingState = true
                    return url
                }
            } catch {
                LiveSharingService.log("existing share fetch failed, will create fresh: \(error.localizedDescription)")
            }
        }

        // --- Create a fresh share bound to the record ---
        let share = CKShare(rootRecord: record)
        share[CKShare.SystemFieldKey.title] = "\(status.displayName)'s Heart Rate" as CKRecordValue
        share.publicPermission = .readOnly   // anyone with the link can view

        LiveSharingService.log("saving record + share atomically")
        let result: (saveResults: [CKRecord.ID: Result<CKRecord, Error>],
                     deleteResults: [CKRecord.ID: Result<Void, Error>])
        do {
            // Wrap in a timeout so the UI never stays stuck on "Preparing…"
            // if CloudKit is unreachable or the container isn't provisioned.
            result = try await withThrowingTimeout(seconds: 25) {
                try await self.privateDB.modifyRecords(
                    saving: [record, share],
                    deleting: [],
                    savePolicy: .allKeys,
                    atomically: true
                )
            }
        } catch is TimeoutError {
            throw fail(.unknown("Saving to iCloud timed out. Check your iCloud sign-in and network, then try again."))
        } catch {
            LiveSharingService.log("modifyRecords threw: \(error.localizedDescription) (\(type(of: error)))")
            throw fail(SharingError.wrap(error))
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
                throw fail(.unknown("iCloud returned an unexpected record for the share. Please try again."))
            }
            guard let savedURL = savedShare.url else {
                throw fail(.unknown("The invite link isn't ready yet. Try again in a moment."))
            }
            LiveSharingService.log("saved share url=\(savedURL.absoluteString)")

            if case .success(let savedRoot)? = result.saveResults[record.recordID] {
                cachedRecord = savedRoot
            } else {
                cachedRecord = nil
            }
            applyShareState(savedShare)
            lastPublishedStatus = status
            lastPublishAt = Date()
            lastError = nil
            didLoadSharingState = true
            return savedURL

        case .failure(let error):
            throw fail(SharingError.wrap(error))
        case .none:
            throw fail(.unknown("iCloud didn't confirm the share. Please try again."))
        }
    }

    /// Records the error for the UI and returns it for `throw`.
    private func fail(_ error: SharingError) -> SharingError {
        lastError = error
        return error
    }

    private struct TimeoutError: Error {}

    /// Carries a CloudKit result (CKRecord is only `Sendable` on iOS 17+)
    /// out of the timeout task group. The value is handed over exactly once.
    private struct UncheckedSendable<Value>: @unchecked Sendable {
        let value: Value
    }

    /// Races an async operation against a deadline. Throws `TimeoutError` on
    /// timeout and cancels the underlying operation.
    private func withThrowingTimeout<T>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: UncheckedSendable<T>.self) { group in
            group.addTask { UncheckedSendable(value: try await operation()) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TimeoutError() }
            return result.value
        }
    }

    /// Log helper — prefixed so it's grep-able in the Xcode console.
    static func log(_ msg: @autoclosure () -> String) {
        #if DEBUG
        print("[Sharing] \(msg())")
        #endif
    }

    // MARK: - Stop sharing

    /// Deletes the share. Existing watchers lose access immediately.
    func stopSharing() async throws {
        guard accountStatus == .available else { throw fail(.notSignedIn) }
        isWorking = true
        defer { isWorking = false }

        flushTask?.cancel()
        flushTask = nil
        pendingStatus = nil

        do {
            let record = try await privateDB.record(for: CloudKitConfig.liveStatusRecordID)
            if let shareRef = record.share {
                do {
                    _ = try await privateDB.deleteRecord(withID: shareRef.recordID)
                } catch let error as CKError where error.code == .unknownItem {
                    // Already gone.
                }
            }
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            // Nothing was shared.
        } catch {
            throw fail(SharingError.wrap(error))
        }
        markSharingStopped()
        lastError = nil
    }

    private func markSharingStopped() {
        cachedRecord = nil
        pendingStatus = nil
        sharingEnabled = false
        currentShareURL = nil
        participantCount = 0
    }

    // MARK: - Publishing (throttled)

    /// Hands a new status to the service. Identical statuses are dropped,
    /// rapid calls are coalesced (only the newest survives until the throttle
    /// window opens) and `immediate` / significant changes flush right away.
    func publish(_ status: LiveHeartStatus, immediate: Bool = false) async {
        guard sharingEnabled, accountStatus == .available else {
            pendingStatus = status  // keep the latest in case sharing turns on
            return
        }
        if pendingStatus == nil, let last = lastPublishedStatus, last == status {
            return  // nothing new
        }

        let significant = isSignificantChange(status)
        pendingStatus = status
        let elapsed = Date().timeIntervalSince(lastPublishAt)

        if immediate || significant || elapsed >= throttleInterval {
            flushTask?.cancel()
            flushTask = nil
            await flush()
        } else if flushTask == nil {
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
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            await self.flush()
        }
    }

    /// Writes pending statuses one at a time. If a newer status arrives while
    /// a save is in flight, the loop picks it up when the save finishes.
    private func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while sharingEnabled, let status = pendingStatus {
            pendingStatus = nil
            do {
                try await writeStatus(status)
                lastPublishAt = Date()
                lastPublishedStatus = status
                lastError = nil
            } catch {
                handleWriteError(error, status: status)
                return
            }
        }
    }

    private func handleWriteError(_ error: Error, status: LiveHeartStatus) {
        let wrapped = SharingError.wrap(error)
        let code = (error as? CKError)?.code
        LiveSharingService.log("publish failed: \(error.localizedDescription)")

        if code == .zoneNotFound || code == .userDeletedZone || wrapped == .shareUnavailable {
            // The record / zone (and with it the share) was deleted elsewhere.
            markSharingStopped()
            return
        }
        if wrapped.isTransient {
            // Keep the newest status and retry when iCloud says it's OK.
            if pendingStatus == nil { pendingStatus = status }
            let retryAfter = (error as? CKError)?.retryAfterSeconds ?? throttleInterval
            scheduleFlush(after: retryAfter)
            if wrapped == .conflict { return }  // resolves itself, don't alarm the user
        }
        lastError = wrapped
    }

    private func writeStatus(_ status: LiveHeartStatus) async throws {
        let record: CKRecord
        if let cachedRecord {
            record = cachedRecord
        } else {
            do {
                record = try await privateDB.record(for: CloudKitConfig.liveStatusRecordID)
            } catch let error as CKError where error.code == .unknownItem {
                // The shared root record is gone, so the share is too.
                throw SharingError.shareUnavailable
            }
        }
        status.apply(to: record)

        do {
            cachedRecord = try await privateDB.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Another of my devices wrote first — rebase onto the server copy once.
            cachedRecord = nil
            guard let serverRecord = error.serverRecord else { throw error }
            status.apply(to: serverRecord)
            cachedRecord = try await privateDB.save(serverRecord)
        } catch {
            cachedRecord = nil
            throw error
        }
    }
}
