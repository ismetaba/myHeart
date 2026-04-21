import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @ObservedObject var profile: UserProfile

    @State private var useManualMax: Bool = false
    @State private var manualMax: Int = 190

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                sharingSection
                zonesSection
                thresholdsSection
                healthSection
                aboutSection
            }
            .navigationTitle("Settings")
            .onAppear(perform: syncLocalState)
        }
    }

    private var sharingSection: some View {
        Section {
            HStack {
                Text("Display Name")
                Spacer()
                TextField("Your name", text: $profile.displayName)
                    .multilineTextAlignment(.trailing)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .foregroundStyle(.primary)
            }
        } header: {
            Text("Live Sharing")
        } footer: {
            Text("This is the name family members see when you share your heart live. Defaults to your device name.")
        }
    }

    // MARK: Sections

    private var profileSection: some View {
        Section {
            Stepper(value: $profile.age, in: 10...100) {
                LabeledRow(label: "Age", value: "\(profile.age)")
            }

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
                .onChange(of: manualMax) { newValue in
                    if useManualMax { profile.maxHROverride = newValue }
                }
            } else {
                LabeledRow(
                    label: "Max HR (formula)",
                    value: "\(profile.formulaMaxHR) bpm",
                    secondary: "220 − age"
                )
            }
        } header: {
            Text("Profile")
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
                            .foregroundStyle(zone.color)
                    }
                    .frame(width: 32, height: 32)

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
            }
        } header: {
            Text("Zones at \(Int(profile.maxHR)) bpm max")
        }
    }

    private var thresholdsSection: some View {
        Section {
            Stepper(value: $profile.elevatedThreshold, in: 80...180, step: 5) {
                LabeledRow(
                    label: "Elevated HR",
                    value: "\(profile.elevatedThreshold) bpm",
                    secondary: "used for flags & insights"
                )
            }
        } header: {
            Text("Thresholds")
        } footer: {
            Text("Samples at or above this value are flagged in History and counted in the \"elevated time\" insight. Default 100 bpm.")
        }
    }

    private var healthSection: some View {
        Section {
            Button {
                if let url = URL(string: "x-apple-health://") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Apple Health", systemImage: "heart.text.square.fill")
            }
            Text("Change MyHeart's permissions in Health → Sharing → Data Access & Devices → MyHeart.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Health data")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledRow(label: "Version", value: appVersion)
            LabeledRow(label: "Data", value: "On-device only")
        } header: {
            Text("About")
        } footer: {
            Text("MyHeart reads heart rate, resting heart rate, and HRV from Apple Health. Nothing leaves your device — reports are generated locally and shared only when you tap Export.")
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

private struct LabeledRow: View {
    let label: String
    let value: String
    var secondary: String? = nil

    var body: some View {
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

#Preview {
    SettingsView(profile: .shared)
        .environmentObject(HeartRateViewModel.preview)
}
