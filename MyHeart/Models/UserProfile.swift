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

    /// Threshold used for "elevated HR" insights and the history flag.
    @Published var elevatedThreshold: Int {
        didSet { storedElevatedThreshold = elevatedThreshold }
    }

    /// Shown to family members when you share. Defaults to the device name.
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
        let storedName = defaults.string(forKey: "profile.displayName") ?? ""
        self.displayName = storedName.isEmpty ? UIDevice.current.name : storedName
        let high = defaults.integer(forKey: "profile.criticalHighBPM")
        self.criticalHighBPM = high == 0 ? 160 : high
        let low = defaults.integer(forKey: "profile.criticalLowBPM")
        self.criticalLowBPM = low == 0 ? 40 : low
        self.emergencyContact = defaults.string(forKey: "profile.emergencyContact") ?? ""
        self.emergencyContactName = defaults.string(forKey: "profile.emergencyContactName") ?? ""
    }

    var hasEmergencyContact: Bool {
        !emergencyContact.isEmpty
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
