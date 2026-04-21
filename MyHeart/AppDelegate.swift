import UIKit
import CloudKit

/// Minimal AppDelegate used only to handle the CloudKit share-accept callback.
/// SwiftUI doesn't expose this hook directly, so we use `@UIApplicationDelegateAdaptor`
/// from the App entry point to bridge.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task { @MainActor in
            await LiveSharingService.shared.accept(shareMetadata: cloudKitShareMetadata)
        }
    }
}
