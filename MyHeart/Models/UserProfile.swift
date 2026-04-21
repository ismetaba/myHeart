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

    private init() {
        let defaults = UserDefaults.standard
        self.age = defaults.integer(forKey: "profile.age") == 0 ? 30 : defaults.integer(forKey: "profile.age")
        self.maxHROverride = defaults.integer(forKey: "profile.maxHROverride")
        let stored = defaults.integer(forKey: "profile.elevatedThreshold")
        self.elevatedThreshold = stored == 0 ? 100 : stored
        let storedName = defaults.string(forKey: "profile.displayName") ?? ""
        self.displayName = storedName.isEmpty ? UIDevice.current.name : storedName
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
