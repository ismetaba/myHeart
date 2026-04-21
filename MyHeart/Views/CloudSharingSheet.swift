import SwiftUI
import CloudKit
import UIKit

/// SwiftUI wrapper around `UICloudSharingController`.
///
/// Uses the **preparation-handler** initializer (Apple's recommended path)
/// instead of `init(share:container:)`. The controller calls our prep
/// handler at the right lifecycle moment and we atomically save the root
/// record + CKShare together — avoiding the classic CloudKit error:
///
///   "An added share is being saved without its rootRecord being saved in
///   the same operation."
///
/// …and the follow-on:
///
///   "You cannot get the URL of a share until it's been saved to the server."
struct CloudSharingSheet: UIViewControllerRepresentable {
    /// Async preparation. Runs when the controller is about to present.
    /// Returns the saved CKShare + its CKContainer.
    let prepare: () async throws -> (CKShare, CKContainer)
    var onEnd: () -> Void = {}

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController { (controller, completion: @escaping (CKShare?, CKContainer?, Error?) -> Void) in
            Task {
                do {
                    let (share, container) = try await prepare()
                    await MainActor.run {
                        completion(share, container, nil)
                    }
                } catch {
                    await MainActor.run {
                        completion(nil, nil, error)
                    }
                }
            }
        }
        controller.availablePermissions = [.allowReadOnly, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onEnd: onEnd) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onEnd: () -> Void
        init(onEnd: @escaping () -> Void) { self.onEnd = onEnd }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            print("CloudSharing save failed: \(error.localizedDescription)")
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            (csc.share?[CKShare.SystemFieldKey.title] as? String) ?? "Heart Rate"
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            Task { @MainActor in
                try? await LiveSharingService.shared.stopSharing()
                onEnd()
            }
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Task { @MainActor in
                await LiveSharingService.shared.loadSharingStatePublic()
                onEnd()
            }
        }
    }
}
