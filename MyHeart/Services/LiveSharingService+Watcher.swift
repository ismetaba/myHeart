import Foundation
import CloudKit

// MARK: - Watcher side

extension LiveSharingService {
    /// Accepts a CKShare when the user taps a share link. Call from
    /// `application(_:userDidAcceptCloudKitShareWith:)`.
    func accept(shareMetadata metadata: CKShare.Metadata) async {
        print("[Sharing] accept() starting, root=\(metadata.hierarchicalRootRecordID?.recordName ?? "?")")
        do {
            let op = CKAcceptSharesOperation(shareMetadatas: [metadata])
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                op.acceptSharesResultBlock = { result in
                    switch result {
                    case .success:       cont.resume()
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
                CKContainer(identifier: CloudKitConfig.containerIdentifier).add(op)
            }
            print("[Sharing] accept() succeeded — refreshing followed list")
            await refreshFollowed()
            await ensureSharedDBSubscription()
            print("[Sharing] accept() post-refresh: followed.count=\(followed.count)")
        } catch {
            let wrapped = SharingError.wrap(error)
            print("[Sharing] accept() failed: \(error.localizedDescription)")
            lastPublishError = "Couldn't accept invite: \(wrapped.friendlyMessage)"
        }
    }

    /// Fetches all live-status records the user is following. Each sharer owns
    /// their own custom zone — we enumerate zones in the shared database and
    /// grab the one record per zone.
    func refreshFollowed() async {
        guard accountStatus == .available else { return }

        do {
            let zones = try await sharedCloudDatabase().allRecordZones()
            print("[Sharing] refreshFollowed: sharedDB has \(zones.count) zones: \(zones.map { $0.zoneID.zoneName }.joined(separator: ", "))")
            var results: [FollowedPerson] = []

            for zone in zones where zone.zoneID.zoneName == CloudKitConfig.zoneName {
                let recordID = CKRecord.ID(
                    recordName: CloudKitConfig.liveStatusRecordName,
                    zoneID: zone.zoneID
                )
                do {
                    let record = try await sharedCloudDatabase().record(for: recordID)
                    if let status = LiveHeartStatus(record: record) {
                        print("[Sharing] refreshFollowed: fetched status for zone ownerName=\(zone.zoneID.ownerName) displayName=\(status.displayName)")
                        results.append(FollowedPerson(
                            id: zone.zoneID.ownerName,
                            zoneID: zone.zoneID,
                            recordID: recordID,
                            status: status,
                            lastFetchedAt: Date()
                        ))
                    } else {
                        print("[Sharing] refreshFollowed: record decode returned nil for zone \(zone.zoneID.zoneName):\(zone.zoneID.ownerName)")
                    }
                } catch {
                    print("[Sharing] refreshFollowed: fetch failed for zone \(zone.zoneID.zoneName):\(zone.zoneID.ownerName) — \(error.localizedDescription)")
                }
            }

            self.followed = results.sorted { $0.status.displayName < $1.status.displayName }
            print("[Sharing] refreshFollowed done, followed.count=\(self.followed.count)")
        } catch {
            print("[Sharing] refreshFollowed outer failure: \(error.localizedDescription)")
            lastPublishError = SharingError.wrap(error).friendlyMessage
        }
    }

    /// Fetches a single followed record (used when a detail view opens).
    func refreshFollowed(person: FollowedPerson) async -> FollowedPerson? {
        do {
            let record = try await sharedCloudDatabase().record(for: person.recordID)
            guard let status = LiveHeartStatus(record: record) else { return nil }
            var updated = person
            updated.status = status
            updated.lastFetchedAt = Date()
            if let idx = followed.firstIndex(where: { $0.id == person.id }) {
                followed[idx] = updated
            }
            return updated
        } catch {
            return nil
        }
    }

    /// Accept a share by URL — used by the "Paste Invite Link" fallback when
    /// the automatic iOS share-open flow didn't fire for some reason.
    func acceptByURL(_ url: URL) async {
        print("[Sharing] acceptByURL start: \(url.absoluteString)")
        do {
            let fetch = CKFetchShareMetadataOperation(shareURLs: [url])
            fetch.shouldFetchRootRecord = true

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
                        cont.resume(throwing: SharingError.unknown("No metadata returned"))
                    }
                }
                CKContainer(identifier: CloudKitConfig.containerIdentifier).add(fetch)
            }
            print("[Sharing] acceptByURL got metadata")
            await accept(shareMetadata: metadata)
        } catch {
            let wrapped = SharingError.wrap(error)
            print("[Sharing] acceptByURL failed: \(error.localizedDescription)")
            lastPublishError = "Couldn't follow that link: \(wrapped.friendlyMessage)"
        }
    }

    /// Stops following a specific person — removes the share participation on
    /// our side. The sharer still has their record; we just can't see it anymore.
    func unfollow(_ person: FollowedPerson) async {
        do {
            // We delete the zone from our shared database to drop the share.
            // The server honors this as "leave the share".
            _ = try await sharedCloudDatabase().deleteRecordZone(withID: person.zoneID)
            followed.removeAll { $0.id == person.id }
        } catch {
            lastPublishError = SharingError.wrap(error).friendlyMessage
        }
    }

    /// Exposes the shared DB without making it public on the main class.
    private func sharedCloudDatabase() -> CKDatabase {
        CKContainer(identifier: CloudKitConfig.containerIdentifier).sharedCloudDatabase
    }
}
