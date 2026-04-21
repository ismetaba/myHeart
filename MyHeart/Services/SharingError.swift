import Foundation
import CloudKit

/// User-facing wrapper around CloudKit errors. The raw CKError codes are
/// numeric and obscure; this maps the common ones to human strings and
/// flags which cases the UI can safely retry.
enum SharingError: LocalizedError {
    case notSignedIn
    case networkUnavailable
    case quotaExceeded
    case rateLimited
    case permissionDenied
    case shareAlreadyAccepted
    case conflict
    case unknown(String)

    static func wrap(_ error: Error) -> SharingError {
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated:             return .notSignedIn
            case .networkUnavailable,
                 .networkFailure:               return .networkUnavailable
            case .quotaExceeded:                return .quotaExceeded
            case .requestRateLimited,
                 .zoneBusy,
                 .serviceUnavailable:           return .rateLimited
            case .permissionFailure:            return .permissionDenied
            case .participantMayNeedVerification: return .shareAlreadyAccepted
            case .serverRecordChanged:          return .conflict
            default:
                return .unknown(ck.localizedDescription)
            }
        }
        return .unknown(error.localizedDescription)
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
            return "iCloud is rate-limiting updates — slowing down."
        case .permissionDenied:
            return "iCloud permission was denied."
        case .shareAlreadyAccepted:
            return "You already follow this person."
        case .conflict:
            return "Another device changed the record; retrying…"
        case .unknown(let detail):
            return detail
        }
    }

    /// Whether a transient condition caused the error (so a UI retry makes sense).
    var isTransient: Bool {
        switch self {
        case .networkUnavailable, .rateLimited, .conflict: return true
        default: return false
        }
    }

    var errorDescription: String? { friendlyMessage }
}
