import SwiftUI
import CloudKit
import UIKit

/// Wraps `UICloudSharingController` so it can be presented from SwiftUI.
/// The controller handles the entire invite UX — messages/mail/link/copy —
/// consistent with every other Apple app that uses CKShare.
struct CloudSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    var onEnd: () -> Void = {}

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
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
            // The controller shows its own alert; we just log.
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
            onEnd()
        }
    }
}
