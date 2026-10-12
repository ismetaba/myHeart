import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @EnvironmentObject private var profile: UserProfile

    @State private var searchText: String = ""
    @State private var onlyElevated: Bool = false
    /// Long ranges hold tens of thousands of samples; render them in pages so
    /// the list stays responsive.
    @State private var visibleLimit: Int = Self.pageSize

    private static let pageSize = 1000

    var body: some View {
        // Filter + sort once per render instead of once per use.
        let filtered = filteredSamples
        NavigationStack {
            Group {
                if currentSamples.isEmpty {
                    emptyState
                } else {
                    list(filtered)
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
                        Image(systemName: onlyElevated
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filter")
                }
            }
            .searchable(text: $searchText, prompt: "Source")
            .refreshable { await viewModel.refresh() }
            .onChange(of: searchText) { _ in visibleLimit = Self.pageSize }
            .onChange(of: onlyElevated) { _ in visibleLimit = Self.pageSize }
            .onChange(of: currentSamples.count) { _ in visibleLimit = Self.pageSize }
        }
    }

    // MARK: Data

    private var currentSamples: [HeartRateSample] {
        switch viewModel.mode {
        case .overall: return viewModel.samples
        case .daily:   return viewModel.dailySamples
        }
    }

    private var rangeDescription: String {
        switch viewModel.mode {
        case .overall:
            return viewModel.selectedRange.fullTitle
        case .daily:
            let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            return "\(viewModel.dailyStart.formatted(style)) – \(viewModel.dailyEnd.formatted(style))"
        }
    }

    /// Newest first, with the elevated / source filters applied.
    private var filteredSamples: [HeartRateSample] {
        var result = currentSamples
        if onlyElevated {
            let t = Double(profile.elevatedThreshold)
            result = result.filter { $0.bpm.rounded() >= t }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            result = result.filter {
                $0.source.localizedCaseInsensitiveContains(q)
            }
        }
        return result.sorted { $0.date > $1.date }
    }

    private func grouped(_ samples: ArraySlice<HeartRateSample>) -> [(Date, [HeartRateSample])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: samples) { cal.startOfDay(for: $0.date) }
        return groups.sorted { $0.key > $1.key }
    }

    // MARK: UI

    private func list(_ filtered: [HeartRateSample]) -> some View {
        let visible = filtered.prefix(visibleLimit)
        let maxHR = profile.maxHR
        let threshold = profile.elevatedThreshold
        return List {
            headerSection(filtered)
            if filtered.isEmpty {
                Section {
                    Text("No samples match the current filter.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(grouped(visible), id: \.0) { day, samples in
                Section {
                    ForEach(samples) { sample in
                        HistoryRow(
                            sample: sample,
                            zone: HeartRateZone(bpm: sample.bpm, maxHR: maxHR),
                            elevatedThreshold: threshold
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
            if filtered.count > visible.count {
                Section {
                    Button {
                        visibleLimit += Self.pageSize
                    } label: {
                        Label("Show older samples (\(filtered.count - visible.count) more)", systemImage: "chevron.down")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func headerSection(_ filtered: [HeartRateSample]) -> some View {
        Section {
            HStack(spacing: 12) {
                miniStat(label: "Samples", value: "\(filtered.count)", icon: "number")
                if let minBpm = filtered.map(\.bpm).min() {
                    miniStat(label: "Min", value: "\(Int(minBpm.rounded()))", icon: "arrow.down.heart")
                }
                if let maxBpm = filtered.map(\.bpm).max() {
                    miniStat(label: "Max", value: "\(Int(maxBpm.rounded()))", icon: "arrow.up.heart")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        } footer: {
            Text("Showing \(rangeDescription) — change the range on the Heart tab.")
                .font(.caption2)
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
            Text("Nothing recorded for \(rangeDescription). Pull to refresh after recording samples in Apple Health, or pick a longer range on the Heart tab.")
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
