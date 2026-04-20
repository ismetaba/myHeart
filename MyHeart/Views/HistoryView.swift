import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @EnvironmentObject private var profile: UserProfile

    @State private var searchText: String = ""
    @State private var onlyElevated: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if currentSamples.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle(isOn: $onlyElevated) {
                            Label("Only ≥ \(profile.elevatedThreshold) bpm", systemImage: "exclamationmark.triangle")
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Source")
            .refreshable { await viewModel.refresh() }
        }
    }

    // MARK: Data

    private var currentSamples: [HeartRateSample] {
        switch viewModel.mode {
        case .overall: return viewModel.samples
        case .daily:   return viewModel.dailySamples
        }
    }

    private var filteredSamples: [HeartRateSample] {
        var result = currentSamples
        if onlyElevated {
            let t = Double(profile.elevatedThreshold)
            result = result.filter { $0.bpm >= t }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            result = result.filter {
                $0.source.localizedCaseInsensitiveContains(q)
            }
        }
        return result.sorted { $0.date > $1.date }
    }

    private var grouped: [(Date, [HeartRateSample])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filteredSamples) { cal.startOfDay(for: $0.date) }
        return groups.sorted { $0.key > $1.key }
    }

    // MARK: UI

    private var list: some View {
        List {
            headerSection
            ForEach(grouped, id: \.0) { day, samples in
                Section {
                    ForEach(samples) { sample in
                        HistoryRow(
                            sample: sample,
                            zone: HeartRateZone(bpm: sample.bpm, maxHR: profile.maxHR),
                            elevatedThreshold: profile.elevatedThreshold
                        )
                    }
                } header: {
                    HStack {
                        Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                            .font(.footnote.weight(.semibold))
                        Spacer()
                        Text("\(samples.count) sample\(samples.count == 1 ? "" : "s")")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                miniStat(label: "Samples", value: "\(filteredSamples.count)", icon: "number")
                if let minBpm = filteredSamples.map(\.bpm).min() {
                    miniStat(label: "Min", value: "\(Int(minBpm.rounded()))", icon: "arrow.down.heart")
                }
                if let maxBpm = filteredSamples.map(\.bpm).max() {
                    miniStat(label: "Max", value: "\(Int(maxBpm.rounded()))", icon: "arrow.up.heart")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        }
    }

    @ViewBuilder
    private func miniStat(label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.slash")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No Heart Rate Data")
                .font(.headline)
            Text("Pull to refresh after recording samples in Apple Health.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private struct HistoryRow: View {
    let sample: HeartRateSample
    let zone: HeartRateZone
    let elevatedThreshold: Int

    var body: some View {
        HStack(spacing: 12) {
            // Time + source
            VStack(alignment: .leading, spacing: 2) {
                Text(sample.date, format: .dateTime.hour().minute())
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                Text(sample.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 90, alignment: .leading)

            // Zone chip
            HStack(spacing: 4) {
                Circle().fill(zone.color).frame(width: 6, height: 6)
                Text(zone.short)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(zone.color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(zone.color.opacity(0.14)))

            if Int(sample.bpm.rounded()) >= elevatedThreshold {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Spacer()

            // BPM
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(sample.bpm.rounded()))")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.pink)
                Text("BPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    HistoryView()
        .environmentObject(HeartRateViewModel.preview)
        .environmentObject(UserProfile.shared)
}
