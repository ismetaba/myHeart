import SwiftUI
import UIKit
import UserNotifications
import Contacts
import ContactsUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @EnvironmentObject private var sharing: LiveSharingService
    @EnvironmentObject private var notifications: NotificationPermission
    @EnvironmentObject private var router: AppRouter
    @Environment(\.openURL) private var openURL
    @ObservedObject var profile: UserProfile

    @State private var useManualMax: Bool = false
    @State private var manualMax: Int = 190
    /// Bumped to open the contact picker; see `ContactPickerPresenter`.
    @State private var contactPickerRequest = 0
    @State private var confirmRestoreDefaults = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case displayName, contactName, phone
    }

    var body: some View {
        NavigationStack {
            Form {
                // Age / max HR sit directly above the zones they drive, so a
                // change is visible right away.
                heartSection
                zonesSection
                sharingSection
                emergencyContactSection
                alertsSection
                notificationsSection
                healthSection
                aboutSection
            }
            .navigationTitle("Settings")
            .scrollDismissesKeyboard(.interactively)
            // Once on the Form, not per field: per-field keyboard toolbars
            // show duplicate Done buttons on iOS 16. The phone pad has no
            // return key, so this is the only way to close it.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .background {
                ContactPickerPresenter(request: contactPickerRequest) { name, phone in
                    profile.emergencyContactName = name
                    profile.emergencyContact = phone
                }
            }
            .onAppear(perform: syncLocalState)
            .task { await notifications.refresh() }
        }
    }

    // MARK: Your heart

    private var heartSection: some View {
        Section {
            Stepper(value: $profile.age, in: 10...100) {
                LabeledRow(label: "Age", value: "\(profile.age)")
            }
            .accessibilityLabel("Age")
            .accessibilityValue("\(profile.age) years")

            Toggle(isOn: $useManualMax) {
                Text("Override max HR")
            }
            .onChange(of: useManualMax) { newValue in
                if newValue {
                    profile.maxHROverride = manualMax
                } else {
                    profile.maxHROverride = 0
                }
            }

            if useManualMax {
                Stepper(value: $manualMax, in: 120...220) {
                    LabeledRow(label: "Max HR", value: "\(manualMax) bpm")
                }
                .accessibilityLabel("Max HR")
                .accessibilityValue("\(manualMax) beats per minute")
                .onChange(of: manualMax) { newValue in
                    if useManualMax { profile.maxHROverride = newValue }
                }
            } else {
                LabeledRow(
                    label: "Max HR (formula)",
                    value: "\(profile.formulaMaxHR) bpm",
                    secondary: "220 − age"
                )
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Your Heart")
        } footer: {
            Text("Max HR drives your five heart-rate zones. The formula is a rough estimate — if you know your real max from a lab or ramp test, override it here.")
        }
    }

    private var zonesSection: some View {
        Section {
            ForEach(HeartRateZone.allCases) { zone in
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(zone.color.opacity(0.18))
                        Image(systemName: zone.systemImage)
                            .foregroundStyle(zone.textColor)
                    }
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(zone.label)
                            .font(.subheadline.weight(.medium))
                        Text(zoneRangeText(zone))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(zonePercentText(zone))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Zones at \(Int(profile.maxHR)) bpm max")
        }
    }

    // MARK: Live sharing

    private var sharingSection: some View {
        Section {
            // Sharing is started and stopped in the Family tab; this row only
            // reports the state and takes you there.
            LabeledContent("Status") {
                Text(sharingStatusText)
            }
            Button(sharing.sharingEnabled ? "Manage in Family Tab" : "Start Sharing in Family Tab") {
                router.openFamily()
            }

            FieldRow(label: "Display Name") {
                TextField("Display Name", text: $profile.displayName, prompt: Text("Your name"))
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($focusedField, equals: .displayName)
            }
        } header: {
            Text("Live Sharing")
        } footer: {
            if profile.hasCustomDisplayName {
                Text("Family sees “\(profile.effectiveDisplayName)” on your live card, invites and alerts.")
            } else {
                Label {
                    Text("Add your name so family knows who an alert is about. Until then they see “\(UIDevice.current.name)”.")
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var sharingStatusText: String {
        guard sharing.sharingEnabled else { return "Off" }
        switch sharing.participantCount {
        case 0: return "On · no one has joined yet"
        case 1: return "On · 1 person following"
        default: return "On · \(sharing.participantCount) people following"
        }
    }

    private var emergencyContactSection: some View {
        Section {
            Button {
                focusedField = nil
                contactPickerRequest += 1
            } label: {
                Label("Choose from Contacts", systemImage: "person.crop.circle.badge.plus")
            }

            // No textContentType on these two: name / phone content types
            // make QuickType suggest the user's *own* details from their Me
            // card, and the emergency contact must be someone else.
            FieldRow(label: "Name") {
                TextField("Contact Name", text: $profile.emergencyContactName, prompt: Text("Name"))
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .contactName)
                    .onSubmit { focusedField = .phone }
            }
            FieldRow(label: "Phone") {
                TextField("Contact Phone", text: $profile.emergencyContact, prompt: Text("Phone number"))
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)
            }

            // Validate once the user has left the fields, not on every keystroke.
            if !isEditingContact, let warning = contactWarning {
                WarningRow(text: warning)
            } else if !isEditingContact, profile.hasEmergencyContact {
                Label {
                    Text("Family sees: Call \(contactPreviewText)")
                } icon: {
                    Image(systemName: "phone.fill")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Emergency Contact")
        } footer: {
            Text("Shared with the people you invite, so they can call this person in one tap from your live card.")
        }
    }

    private var isEditingContact: Bool {
        focusedField == .contactName || focusedField == .phone
    }

    private var contactWarning: String? {
        let phone = profile.emergencyContact.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = profile.emergencyContactName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Followers' Call button keeps only digits and "+", so anything
        // without a few digits silently does nothing in an emergency.
        if !phone.isEmpty && phone.filter({ "0123456789".contains($0) }).count < 3 {
            return "This doesn't look like a phone number — family's Call button won't work."
        }
        // Matches `hasEmergencyContact`: without a phone nothing is shared.
        if phone.isEmpty && !name.isEmpty {
            return "Add a phone number — family only sees the contact when there is one."
        }
        return nil
    }

    private var contactPreviewText: String {
        let phone = profile.emergencyContact.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = profile.emergencyContactName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? phone : "\(name) · \(phone)"
    }

    // MARK: Alerts

    /// Elevated must stay below Critical High (and vice versa), otherwise the
    /// sustained-high alert can never fire before the acute one. The outer
    /// clamps keep the ranges valid even for out-of-range stored values.
    private var elevatedRange: ClosedRange<Int> {
        80...max(80, min(180, profile.criticalHighBPM - 5))
    }

    private var criticalHighRange: ClosedRange<Int> {
        min(220, max(120, profile.elevatedThreshold + 5))...220
    }

    private var alertsSection: some View {
        Section {
            Stepper(value: $profile.criticalLowBPM, in: 30...60, step: 2) {
                LabeledRow(label: "Critical Low", value: "\(profile.criticalLowBPM) bpm")
            }
            .accessibilityLabel("Critical Low")
            .accessibilityValue("\(profile.criticalLowBPM) beats per minute")

            Stepper(value: $profile.elevatedThreshold, in: elevatedRange, step: 5) {
                LabeledRow(
                    label: "Elevated HR",
                    value: "\(profile.elevatedThreshold) bpm",
                    secondary: "flags & sustained alert"
                )
            }
            .accessibilityLabel("Elevated heart rate")
            .accessibilityValue("\(profile.elevatedThreshold) beats per minute")

            Stepper(value: $profile.criticalHighBPM, in: criticalHighRange, step: 5) {
                LabeledRow(label: "Critical High", value: "\(profile.criticalHighBPM) bpm")
            }
            .accessibilityLabel("Critical High")
            .accessibilityValue("\(profile.criticalHighBPM) beats per minute")

            LabeledRow(
                label: "Sustained high",
                value: "≥ \(profile.sustainedHighBPM) bpm for \(UserProfile.sustainedHighMinutes) min",
                secondary: "follows Elevated HR, minimum \(UserProfile.sustainedHighFloorBPM)"
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sustained high")
            .accessibilityValue("\(profile.sustainedHighBPM) beats per minute or more for \(UserProfile.sustainedHighMinutes) minutes. Follows Elevated heart rate, minimum \(UserProfile.sustainedHighFloorBPM).")

            // Legacy stored values can still contradict each other; the
            // steppers only clamp on the next tap, so say so instead of
            // silently rewriting a safety setting.
            if profile.elevatedThreshold >= profile.criticalHighBPM {
                WarningRow(text: "Elevated is at or above Critical High — lower it so the sustained alert means something.")
            }
            // Only a measured max is worth a warning. The 220 − age estimate
            // is below the 160 default from age 61, and abnormal rhythms can
            // exceed it, so there it's just a note — nothing to "fix".
            if profile.isMaxHROverridden && profile.criticalHighBPM > profile.maxHROverride {
                WarningRow(text: "Critical High is above the max HR you entered (\(profile.maxHROverride) bpm), so it only fires for readings above your own maximum.")
            } else if !profile.isMaxHROverridden && profile.criticalHighBPM > profile.formulaMaxHR {
                NoteRow(text: "Critical High is above your estimated max HR (\(profile.formulaMaxHR) bpm), so it only catches unusually high readings.")
            }

            Button("Restore Default Alert Levels") {
                confirmRestoreDefaults = true
            }
            .confirmationDialog(
                "Restore default alert levels?",
                isPresented: $confirmRestoreDefaults,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive) {
                    profile.restoreDefaultAlertLevels()
                    Haptics.success()
                }
            } message: {
                Text("Critical High 160 bpm, Elevated HR 100 bpm and Critical Low 40 bpm.")
            }
        } header: {
            Text("Alerts Your Family Receives")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("While you share live, family gets a time-sensitive alert when your heart rate is at or above Critical High, at or below Critical Low, or stays at or above \(profile.sustainedHighBPM) bpm for \(UserProfile.sustainedHighMinutes) minutes. Workouts can trigger these. Elevated HR also flags samples in History, drives the elevated-time insight and is shown to followers; it stays at least 5 bpm below Critical High. To change alerts you get about someone you follow, open them in the Family tab.")
                Text("MyHeart is not a medical device and doesn't contact emergency services. Alerts depend on your Watch syncing and both phones being online, and can be delayed — in an emergency, call your local emergency number.")
            }
        }
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        Section {
            LabeledContent("Alerts") {
                // Icon + word, so the state isn't signalled by color alone.
                HStack(spacing: 6) {
                    Image(systemName: notificationStatus.icon)
                        .foregroundStyle(notificationStatus.tint)
                        .accessibilityHidden(true)
                    Text(notificationStatus.text)
                }
            }
            if notifications.isDenied {
                WarningRow(text: "You won't be alerted when someone you follow has an emergency.")
            } else if notifications.timeSensitiveDisabled {
                WarningRow(text: "Time Sensitive is off — Focus modes can silence emergency alerts.")
            }
            if notifications.status == .notDetermined {
                Button("Turn On Alerts") {
                    Task { await notifications.requestIfNeeded() }
                }
            } else {
                Button("Notification Settings") {
                    notifications.openSystemSettings()
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("MyHeart uses notifications to alert you about people you follow. Emergency alerts are Time Sensitive so they can break through Focus.")
        }
    }

    private var notificationStatus: (text: String, icon: String, tint: Color) {
        switch notifications.status {
        case .authorized:
            return ("On", "checkmark.circle.fill", .green)
        case .provisional, .ephemeral:
            return ("On (delivered quietly)", "checkmark.circle", .green)
        case .denied:
            return ("Off", "xmark.circle.fill", .red)
        case .notDetermined:
            return ("Not set up", "questionmark.circle", .secondary)
        @unknown default:
            return ("Unknown", "questionmark.circle", .secondary)
        }
    }

    // MARK: Health & about

    private var healthSection: some View {
        Section {
            if viewModel.healthUnavailable {
                Text("Apple Health isn't available on this device.")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    if let url = URL(string: "x-apple-health://") {
                        openURL(url)
                    }
                } label: {
                    Label("Open Apple Health", systemImage: "heart.text.square.fill")
                }
            }
        } header: {
            Text("Health data")
        } footer: {
            if !viewModel.healthUnavailable {
                Text("To change what MyHeart can read: \(HealthCopy.permissionPath)")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: appVersion)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = appVersion
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            NavigationLink {
                PrivacyDataView()
            } label: {
                Label("Privacy & Data", systemImage: "hand.raised.fill")
            }
        } header: {
            Text("About")
        } footer: {
            Text("MyHeart is not a medical device and is no substitute for professional medical advice.")
        }
    }

    // MARK: Helpers

    private func syncLocalState() {
        useManualMax = profile.isMaxHROverridden
        manualMax = profile.isMaxHROverridden
            ? profile.maxHROverride
            : profile.formulaMaxHR
    }

    private func zoneRangeText(_ zone: HeartRateZone) -> String {
        let r = zone.range(maxHR: profile.maxHR)
        if zone == .peak {
            return "\(r.lowerBound)+ bpm"
        }
        return "\(r.lowerBound) – \(r.upperBound) bpm"
    }

    private func zonePercentText(_ zone: HeartRateZone) -> String {
        let lo = Int((zone.lowerFraction * 100).rounded())
        let hi = Int((zone.upperFraction * 100).rounded())
        if zone == .peak { return "\(lo)%+" }
        return "\(lo)–\(hi)%"
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(v ?? "1.0") (\(b ?? "1"))"
    }
}

// MARK: - Rows

/// Label + value row (used as stepper labels). Stacks vertically at
/// accessibility text sizes so neither side truncates next to the ± control.
private struct LabeledRow: View {
    let label: String
    let value: String
    var secondary: String? = nil

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(value)
                    .foregroundStyle(.primary)
                    .fontWeight(.semibold)
                if let secondary {
                    Text(secondary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                Text(label)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value)
                        .foregroundStyle(.primary)
                    if let secondary {
                        Text(secondary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Label + text field row; the field moves below its label at accessibility
/// text sizes.
private struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var field: Content

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .accessibilityHidden(true)
                field
            }
        } else {
            HStack {
                // The text field's own title already names it for VoiceOver.
                Text(label)
                    .accessibilityHidden(true)
                Spacer()
                field
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// Neutral counterpart of `WarningRow`, for context that needs no action.
private struct NoteRow: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Inline warning; the icon (not only the color) marks it as a warning.
private struct WarningRow: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Warning: \(text)")
    }
}

// MARK: - Privacy & data

private struct PrivacyDataView: View {
    var body: some View {
        List {
            Section {
                point(
                    "Reads Apple Health, never writes",
                    detail: "MyHeart reads the Health data you allow it to and never changes or adds to it.",
                    systemImage: "heart.text.square.fill"
                )
                point(
                    "Reports stay on this device",
                    detail: "PDF reports are made on your iPhone and only leave it when you tap Export and choose where to send them.",
                    systemImage: "doc.richtext"
                )
                point(
                    "Live sharing uses your iCloud",
                    detail: "When you turn it on, your latest reading is stored in your own iCloud account. Only people with your invite link can see it, and you can stop sharing in the Family tab at any time.",
                    systemImage: "icloud.fill"
                )
                point(
                    "What followers see",
                    detail: "Your display name, latest heart rate and zone and when it was recorded, resting heart rate and HRV, a 24-hour trend, the device that recorded it, your Elevated HR (shown as your “usual limit”) and max heart rate, whether a reading counts as an emergency and since when, and your emergency contact if you added one.",
                    systemImage: "person.2.fill"
                )
                point(
                    "No MyHeart server",
                    detail: "There is no MyHeart account or server; your data moves only between Apple Health, your iCloud and the people you invite.",
                    systemImage: "lock.fill"
                )
            } footer: {
                Text("MyHeart is not a medical device and doesn't contact emergency services.")
            }
        }
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func point(_ title: String, detail: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.pink)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Contact picker

/// Presents the system contact picker, which needs no Contacts permission
/// (it runs out of process and only hands back what the user taps).
/// Driven by a counter rather than a Bool, so a picker dismissed by a swipe
/// (which may not report a cancel) can always be opened again.
private struct ContactPickerPresenter: UIViewControllerRepresentable {
    let request: Int
    let onPick: (_ name: String, _ phone: String) -> Void

    // Starts at the current request, so a re-created presenter never opens
    // the picker for a tap that was already handled.
    func makeCoordinator() -> Coordinator { Coordinator(handledRequest: request) }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.isUserInteractionEnabled = false
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onPick = onPick
        guard request != coordinator.handledRequest else { return }
        coordinator.handledRequest = request
        guard host.presentedViewController == nil else { return }

        let picker = CNContactPickerViewController()
        picker.delegate = coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        // One number → pick the contact directly; several → the user picks
        // the number on the contact card.
        picker.predicateForSelectionOfContact = NSPredicate(format: "phoneNumbers.@count == 1")
        host.present(picker, animated: true)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var handledRequest: Int
        var onPick: ((_ name: String, _ phone: String) -> Void)?

        init(handledRequest: Int) {
            self.handledRequest = handledRequest
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            guard contact.isKeyAvailable(CNContactPhoneNumbersKey),
                  let number = contact.phoneNumbers.first?.value.stringValue else { return }
            onPick?(Self.name(of: contact), number)
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            guard let number = (contactProperty.value as? CNPhoneNumber)?.stringValue else { return }
            onPick?(Self.name(of: contactProperty.contact), number)
        }

        /// Picker contacts are partial; only format the keys that were fetched.
        private static func name(of contact: CNContact) -> String {
            let nameKeys = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
            if contact.areKeysAvailable([nameKeys]),
               let full = CNContactFormatter.string(from: contact, style: .fullName),
               !full.isEmpty {
                return full
            }
            if contact.isKeyAvailable(CNContactOrganizationNameKey) {
                return contact.organizationName
            }
            return ""
        }
    }
}

#Preview {
    SettingsView(profile: .shared)
        .environmentObject(HeartRateViewModel.preview)
        .environmentObject(LiveSharingService.shared)
        .environmentObject(NotificationPermission.shared)
        .environmentObject(AppRouter.shared)
}
