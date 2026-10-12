import Foundation
import SwiftUI
import UIKit

/// Shared user profile. Age drives max HR which drives zone thresholds.
/// Users can override max HR directly if they know their actual value
/// (lab-tested, ramp test, etc.).
@MainActor
final class UserProfile: ObservableObject {
    static let shared = UserProfile()

    @AppStorage("profile.age") private var storedAge: Int = 30
    @AppStorage("profile.maxHROverride") private var storedMaxHROverride: Int = 0
    @AppStorage("profile.elevatedThreshold") private var storedElevatedThreshold: Int = 100
    @AppStorage("profile.displayName") private var storedDisplayName: String = ""
    @AppStorage("profile.criticalHighBPM") private var storedCriticalHighBPM: Int = 160
    @AppStorage("profile.criticalLowBPM") private var storedCriticalLowBPM: Int = 40
    @AppStorage("profile.emergencyContact") private var storedEmergencyContact: String = ""
    @AppStorage("profile.emergencyContactName") private var storedEmergencyContactName: String = ""

    @Published var age: Int {
        didSet { storedAge = age }
    }

    /// If 0, the formula (220 - age) is used. Otherwise this value overrides it.
    @Published var maxHROverride: Int {
        didSet { storedMaxHROverride = maxHROverride }
    }

    /// Threshold used for "elevated HR" insights, the history flag, and (via
    /// `sustainedHighBPM`) the sustained-high family alert.
    @Published var elevatedThreshold: Int {
        didSet { storedElevatedThreshold = elevatedThreshold }
    }

    /// Shown to family members when you share. Empty until the user sets it;
    /// `effectiveDisplayName` supplies the fallback.
    @Published var displayName: String {
        didSet { storedDisplayName = displayName }
    }

    /// BPM that triggers an acute "critical high" emergency flag on shared records.
    @Published var criticalHighBPM: Int {
        didSet { storedCriticalHighBPM = criticalHighBPM }
    }

    /// BPM below which a "critical low" emergency flag is set on shared records.
    @Published var criticalLowBPM: Int {
        didSet { storedCriticalLowBPM = criticalLowBPM }
    }

    /// Phone number followers / the user can quick-dial in an emergency.
    @Published var emergencyContact: String {
        didSet { storedEmergencyContact = emergencyContact }
    }

    @Published var emergencyContactName: String {
        didSet { storedEmergencyContactName = emergencyContactName }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.age = defaults.integer(forKey: "profile.age") == 0 ? 30 : defaults.integer(forKey: "profile.age")
        self.maxHROverride = defaults.integer(forKey: "profile.maxHROverride")
        let stored = defaults.integer(forKey: "profile.elevatedThreshold")
        self.elevatedThreshold = stored == 0 ? 100 : stored
        // Don't pre-fill the device name: since iOS 16 it's just "iPhone",
        // which makes family alerts read "iPhone — emergency".
        self.displayName = defaults.string(forKey: "profile.displayName") ?? ""
        let high = defaults.integer(forKey: "profile.criticalHighBPM")
        self.criticalHighBPM = high == 0 ? 160 : high
        let low = defaults.integer(forKey: "profile.criticalLowBPM")
        self.criticalLowBPM = low == 0 ? 40 : low
        self.emergencyContact = defaults.string(forKey: "profile.emergencyContact") ?? ""
        self.emergencyContactName = defaults.string(forKey: "profile.emergencyContactName") ?? ""
    }

    /// Minutes at or above `sustainedHighBPM` before family is alerted.
    static let sustainedHighMinutes = 10
    /// The sustained-high alert never starts below this, so a low Elevated
    /// setting doesn't page family during an ordinary brisk walk.
    static let sustainedHighFloorBPM = 120

    /// Single source for the sustained-high family alert level, so what
    /// Settings shows and what gets evaluated can't drift apart.
    var sustainedHighBPM: Int { max(elevatedThreshold, Self.sustainedHighFloorBPM) }

    /// Back to the first-launch alert levels (same values as in `init`).
    func restoreDefaultAlertLevels() {
        criticalHighBPM = 160
        elevatedThreshold = 100
        criticalLowBPM = 40
    }

    var hasEmergencyContact: Bool {
        !emergencyContact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Name shown to followers — never empty.
    var effectiveDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? UIDevice.current.name : trimmed
    }

    /// The user typed a name (rather than relying on the device-name fallback).
    var hasCustomDisplayName: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Max heart rate used for zone computation.
    var maxHR: Double {
        if maxHROverride > 0 { return Double(maxHROverride) }
        return Double(max(120, 220 - age)) // safety floor
    }

    /// True if the user has manually overridden the max HR.
    var isMaxHROverridden: Bool { maxHROverride > 0 }

    /// Suggested max HR from the standard formula.
    var formulaMaxHR: Int { max(120, 220 - age) }
}
