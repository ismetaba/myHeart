import Foundation
import SwiftUI
import UserNotifications
import UIKit
import HealthKit

/// The app's tabs, used for programmatic tab switching.
enum AppTab: Hashable {
    case health, heart, family, history, settings
}

/// App-wide navigation requests that originate outside the view tree
/// (notification taps, accepted invites).
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    /// Devices without Apple Health (e.g. iPad on iPadOS 16) can still
    /// follow family members, so they start on that tab.
    @Published var selectedTab: AppTab = HKHealthStore.isHealthDataAvailable() ? .health : .family

    /// Zone owner name (`FollowedPerson.id`) of someone whose detail screen
    /// should open. The Family tab consumes and clears it once that person is
    /// in the followed list.
    @Published var pendingFollowedID: String?

    private init() {}

    func openFamily(personID: String? = nil) {
        selectedTab = .family
        if let personID { pendingFollowedID = personID }
    }
}

/// Tracks whether MyHeart may show notifications, so screens can explain
/// why alerts won't arrive and offer a fix. Refreshed on launch and every
/// time the app returns to the foreground.
@MainActor
final class NotificationPermission: ObservableObject {
    static let shared = NotificationPermission()

    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    /// Time Sensitive delivery is switched off, so a Focus can silence emergencies.
    @Published private(set) var timeSensitiveDisabled = false

    private init() {}

    /// Alerts will be delivered (possibly quietly for provisional).
    var isAllowed: Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    var isDenied: Bool { status == .denied }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
        timeSensitiveDisabled = settings.authorizationStatus == .authorized
            && settings.timeSensitiveSetting == .disabled
    }

    /// Shows the system prompt the first time; afterwards it's a no-op.
    func requestIfNeeded() async {
        await refresh()
        guard status == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
    }

    /// The notification settings page for MyHeart in the Settings app.
    func openSystemSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// Copy shared by several screens so instructions never contradict each other.
enum HealthCopy {
    /// Where users change what MyHeart may read. There is no public deep link
    /// to this page — `x-apple-health://` only opens the Health app.
    static let permissionPath = "In the Health app, tap your profile picture, then Apps (under Privacy) → MyHeart."
}
