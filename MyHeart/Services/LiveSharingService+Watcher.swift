import Foundation
import CloudKit

// MARK: - Watcher side

extension LiveSharingService {
    /// Accepts a CKShare when the user taps a share link. Call from
    /// `application(_:userDidAcceptCloudKitShareWith:)`.
    func accept(shareMetadata metadata: CKShare.Metadata) async {
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
            await refreshFollowed()
            await ensureSharedDBSubscription()
        } catch {
            lastPublishError = "Couldn't accept invite: \(SharingError.wrap(error).friendlyMessage)"
        }
    }

    /// Fetches all live-status records the user is following. Each sharer owns
    /// their own custom zone — we enumerate zones in the shared database and
    /// grab the one record per zone.
    func refreshFollowed() async {
        guard accountStatus == .available else { return }

        do {
            let zones = try await sharedCloudDatabase().allRecordZones()
            var results: [FollowedPerson] = []

            for zone in zones where zone.zoneID.zoneName == CloudKitConfig.zoneName {
                // The record name is well-known; fetch directly.
                let recordID = CKRecord.ID(
                    recordName: CloudKitConfig.liveStatusRecordName,
                    zoneID: zone.zoneID
                )
                if let record = try? await sharedCloudDatabase().record(for: recordID),
                   let status = LiveHeartStatus(record: record) {
                    results.append(FollowedPerson(
                        id: zone.zoneID.ownerName,
                        zoneID: zone.zoneID,
                        recordID: recordID,
                        status: status,
                        lastFetchedAt: Date()
                    ))
                }
            }

            self.followed = results.sorted { $0.status.displayName < $1.status.displayName }
        } catch {
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
