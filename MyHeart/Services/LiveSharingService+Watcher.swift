import Foundation
import CloudKit

// MARK: - Watcher side

extension LiveSharingService {
    /// Accepts a CKShare when the user taps a share link. Called from the app
    /// and scene delegates, and from the "Paste Invite Link" fallback.
    func accept(shareMetadata metadata: CKShare.Metadata) async {
        LiveSharingService.log("accept() starting, root=\(metadata.hierarchicalRootRecordID?.recordName ?? "?")")
        followError = nil
        justFollowedID = nil
        // Whatever happens next (success or an error to explain), the user
        // should land on the Family tab after tapping an invite.
        AppRouter.shared.selectedTab = .family

        // Opening your own invite link would fail with an obscure error.
        if metadata.participantRole == .owner {
            followError = .ownShare
            return
        }

        if accountStatus != .available {
            await refreshAccountStatus()
        }

        // Already accepted (e.g. the link was tapped twice) — just refresh.
        let isNewFollow = metadata.participantStatus != .accepted
        if isNewFollow {
            do {
                try await acceptShare(metadata)
            } catch {
                LiveSharingService.log("accept() failed: \(error.localizedDescription)")
                followError = SharingError.wrap(error)
                return
            }
        }

        LiveSharingService.log("accept() succeeded — refreshing followed list")
        // The shared zone can take a moment to show up in the shared DB.
        let ownerName = metadata.share.recordID.zoneID.ownerName
        for attempt in 0..<3 {
            await refreshFollowed()
            if followed.contains(where: { $0.zoneID.ownerName == ownerName }) {
                // Confirm the new follow (a re-tapped link needs no fanfare)
                // and take the user straight to that person.
                if isNewFollow { justFollowedID = ownerName }
                AppRouter.shared.openFamily(personID: ownerName)
                break
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        await ensureSharedDBSubscription()
        LiveSharingService.log("accept() post-refresh: followed.count=\(followed.count)")
    }

    private func acceptShare(_ metadata: CKShare.Metadata) async throws {
        let op = CKAcceptSharesOperation(shareMetadatas: [metadata])
        op.qualityOfService = .userInitiated
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var perShareError: Error?
            op.perShareResultBlock = { _, result in
                if case .failure(let error) = result { perShareError = error }
            }
            op.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    if let perShareError {
                        cont.resume(throwing: perShareError)
                    } else {
                        cont.resume()
                    }
                case .failure(let error):
                    cont.resume(throwing: perShareError ?? error)
                }
            }
            container.add(op)
        }
    }

    /// Fetches all live-status records the user is following. Each sharer owns
    /// their own custom zone — we enumerate zones in the shared database and
    /// grab the one record per zone.
    ///
    /// A transient failure for one person keeps their last known status
    /// instead of dropping them from the list.
    func refreshFollowed() async {
        guard accountStatus == .available else { return }
        isRefreshingFollowed = true
        defer { isRefreshingFollowed = false }

        do {
            let zones = try await sharedDB.allRecordZones()
                .filter { $0.zoneID.zoneName == CloudKitConfig.zoneName }
            LiveSharingService.log("refreshFollowed: \(zones.count) shared zone(s)")

            let previous = Dictionary(followed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var results: [FollowedPerson] = []

            for zone in zones {
                let ownerName = zone.zoneID.ownerName
                let recordID = CKRecord.ID(
                    recordName: CloudKitConfig.liveStatusRecordName,
                    zoneID: zone.zoneID
                )
                do {
                    let record = try await sharedDB.record(for: recordID)
                    if let status = LiveHeartStatus(record: record) {
                        results.append(FollowedPerson(
                            id: ownerName,
                            zoneID: zone.zoneID,
                            recordID: recordID,
                            status: status,
                            lastFetchedAt: Date()
                        ))
                    } else {
                        LiveSharingService.log("refreshFollowed: couldn't decode record for \(ownerName)")
                    }
                } catch let error as CKError where error.code == .unknownItem {
                    // The sharer stopped sharing; drop them.
                    LiveSharingService.log("refreshFollowed: record gone for \(ownerName)")
                } catch {
                    LiveSharingService.log("refreshFollowed: fetch failed for \(ownerName) — \(error.localizedDescription)")
                    if let old = previous[ownerName] { results.append(old) }
                }
            }

            followed = results.sorted {
                $0.status.displayName.localizedCaseInsensitiveCompare($1.status.displayName) == .orderedAscending
            }
            if followError?.isTransient == true { followError = nil }
        } catch {
            LiveSharingService.log("refreshFollowed failed: \(error.localizedDescription)")
            followError = SharingError.wrap(error)
        }
    }

    /// Outcome of refreshing one followed person, so the detail screen can
    /// tell "they stopped sharing" apart from "we couldn't reach iCloud".
    enum FollowRefreshResult {
        case updated(FollowedPerson)
        /// The sharer stopped sharing (or revoked the link).
        case removed
        case failed(SharingError)
    }

    /// Fetches a single followed record (used while a detail view is open).
    func refreshFollowed(person: FollowedPerson) async -> FollowRefreshResult {
        do {
            let record = try await sharedDB.record(for: person.recordID)
            guard let status = LiveHeartStatus(record: record) else {
                return .failed(.unknown("The latest update couldn't be read."))
            }
            var updated = person
            updated.status = status
            updated.lastFetchedAt = Date()
            if let idx = followed.firstIndex(where: { $0.id == person.id }) {
                followed[idx] = updated
            }
            return .updated(updated)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            // Same signal refreshFollowed() uses to drop someone; keep the
            // list in sync instead of waiting for the next full refresh.
            LiveSharingService.log("refreshFollowed(person:): record gone for \(person.id)")
            followed.removeAll { $0.id == person.id }
            return .removed
        } catch {
            LiveSharingService.log("refreshFollowed(person:) failed: \(error.localizedDescription)")
            return .failed(SharingError.wrap(error))
        }
    }

    /// Accept a share by URL — used by the "Paste Invite Link" fallback when
    /// the automatic iOS share-open flow didn't fire for some reason.
    /// Returns true when the invite was accepted.
    @discardableResult
    func acceptByURL(_ url: URL) async -> Bool {
        LiveSharingService.log("acceptByURL start: \(url.absoluteString)")
        followError = nil
        do {
            let fetch = CKFetchShareMetadataOperation(shareURLs: [url])
            fetch.shouldFetchRootRecord = false
            fetch.qualityOfService = .userInitiated

            let metadata: CKShare.Metadata = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CKShare.Metadata, Error>) in
                var captured: CKShare.Metadata?
                var capturedError: Error?
                fetch.perShareMetadataResultBlock = { _, result in
                    switch result {
                    case .success(let meta): captured = meta
                    case .failure(let e):    capturedError = e
                    }
                }
                fetch.fetchShareMetadataResultBlock = { result in
                    if case .failure(let e) = result, capturedError == nil { capturedError = e }
                    if let meta = captured {
                        cont.resume(returning: meta)
                    } else if let e = capturedError {
                        cont.resume(throwing: e)
                    } else {
                        cont.resume(throwing: SharingError.shareUnavailable)
                    }
                }
                container.add(fetch)
            }
            await accept(shareMetadata: metadata)
            return followError == nil
        } catch {
            LiveSharingService.log("acceptByURL failed: \(error.localizedDescription)")
            followError = SharingError.wrap(error)
            return false
        }
    }

    /// Stops following a specific person. Deleting the shared zone from *our*
    /// shared database is how a participant leaves the shares in it; the
    /// sharer keeps their record.
    @discardableResult
    func unfollow(_ person: FollowedPerson) async -> Bool {
        do {
            _ = try await sharedDB.deleteRecordZone(withID: person.zoneID)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            // Already gone.
        } catch {
            followError = SharingError.wrap(error)
            return false
        }
        followed.removeAll { $0.id == person.id }
        let defaults = UserDefaults.standard
        for kind in AlertKind.allCases {
            defaults.removeObject(forKey: kind.readingKey(person.id))
            defaults.removeObject(forKey: kind.timeKey(person.id))
        }
        return true
    }
}
