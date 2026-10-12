import Foundation
import CloudKit

/// User-facing wrapper around CloudKit errors. The raw CKError codes are
/// numeric and obscure; this maps the common ones to human strings and
/// flags which cases the UI can safely retry.
enum SharingError: LocalizedError, Equatable {
    case notSignedIn
    case networkUnavailable
    case quotaExceeded
    case rateLimited
    case permissionDenied
    case needsVerification
    case conflict
    /// The invite link points at a share that was revoked or never existed.
    case shareUnavailable
    /// The user opened their own invite link.
    case ownShare
    /// The iCloud container hasn't been provisioned on Apple's servers yet —
    /// typically because Xcode's CloudKit capability wasn't enabled with a
    /// real development team, or the container is newly created and
    /// not yet ready. User-actionable.
    case containerNotConfigured
    case unknown(String)

    static func wrap(_ error: Error) -> SharingError {
        if let sharing = error as? SharingError { return sharing }
        guard let ck = error as? CKError else {
            return unexpected(error.localizedDescription)
        }

        // Batch operations report the real cause per item.
        if ck.code == .partialFailure,
           let first = ck.partialErrorsByItemID?.values.first {
            return wrap(first)
        }

        // The "couldn't get container configuration" error doesn't map
        // cleanly to a single CKError code across iOS versions — peek at
        // the message too.
        let description = ck.localizedDescription.lowercased()
        if description.contains("container configuration")
            || description.contains("container not found")
            || (description.contains("couldn't get") && description.contains("container")) {
            return .containerNotConfigured
        }

        switch ck.code {
        case .notAuthenticated:               return .notSignedIn
        case .missingEntitlement,
             .badContainer:                   return .containerNotConfigured
        case .networkUnavailable,
             .networkFailure,
             .serverResponseLost:             return .networkUnavailable
        case .quotaExceeded:                  return .quotaExceeded
        case .requestRateLimited,
             .zoneBusy,
             .serviceUnavailable:             return .rateLimited
        case .permissionFailure:              return .permissionDenied
        case .participantMayNeedVerification: return .needsVerification
        case .serverRecordChanged:            return .conflict
        case .unknownItem:                    return .shareUnavailable
        default:
            return unexpected(ck.localizedDescription)
        }
    }

    /// Raw CloudKit wording is useful while developing but meaningless to
    /// family members, so release builds show a plain sentence instead.
    private static func unexpected(_ detail: String) -> SharingError {
        LiveSharingService.log("unexpected iCloud error: \(detail)")
        #if DEBUG
        return .unknown(detail)
        #else
        return .unknown("Something went wrong with iCloud. Please try again.")
        #endif
    }

    /// Short sentence for inline error UI.
    var friendlyMessage: String {
        switch self {
        case .notSignedIn:
            return "Sign in to iCloud in Settings to share heart data."
        case .networkUnavailable:
            return "No internet connection — will retry automatically."
        case .quotaExceeded:
            return "Your iCloud storage is full."
        case .rateLimited:
            return "iCloud is busy right now — retrying shortly."
        case .permissionDenied:
            return "iCloud permission was denied."
        case .needsVerification:
            return "iCloud needs to verify your Apple ID before you can accept this invite. Open Settings → your name and follow the prompts."
        case .conflict:
            return "Another device changed the record; retrying…"
        case .shareUnavailable:
            return "This invite is no longer available. Ask for a new link."
        case .ownShare:
            return "That's your own invite link — send it to family members instead."
        case .containerNotConfigured:
            #if DEBUG
            return "iCloud container isn't provisioned yet. Open Xcode → Signing & Capabilities, select your Team, and enable the iCloud / CloudKit capability."
            #else
            return "Live sharing isn't available right now. Please try again later."
            #endif
        case .unknown(let detail):
            return detail
        }
    }

    /// Whether a transient condition caused the error (so a retry makes sense).
    var isTransient: Bool {
        switch self {
        case .networkUnavailable, .rateLimited, .conflict: return true
        default: return false
        }
    }

    var errorDescription: String? { friendlyMessage }
}
