import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel
    @State private var pdfURL: URL?
    @State private var showShare = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    rangePicker
                    latestCard
                    statsGrid
                    chartCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("MyHeart")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await export() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(viewModel.samples.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable { await viewModel.refresh() }
            .sheet(isPresented: $showShare) {
                if let pdfURL {
                    ShareSheet(activityItems: [pdfURL])
                }
            }
            .alert("Export Failed",
                   isPresented: .constant(exportError != nil),
                   actions: { Button("OK") { exportError = nil } },
                   message: { Text(exportError ?? "") })
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: Binding(
            get: { viewModel.selectedRange },
            set: { newValue in Task { await viewModel.changeRange(to: newValue) } }
        )) {
            ForEach(HeartRateViewModel.TimeRange.allCases) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(.segmented)
    }

    private var latestCard: some View {
        VStack(spacing: 8) {
            Text("Current Heart Rate")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(viewModel.summary.latest.map { String(Int($0.bpm)) } ?? "—")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.pink)
                Text("BPM")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if let date = viewModel.summary.latest?.date {
                Text(date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(title: "Resting", value: format(viewModel.summary.restingBPM), unit: "bpm", icon: "bed.double.fill")
            StatTile(title: "Average", value: format(viewModel.summary.averageBPM), unit: "bpm", icon: "waveform.path.ecg")
            StatTile(title: "Min", value: format(viewModel.summary.minBPM), unit: "bpm", icon: "arrow.down.heart")
            StatTile(title: "Max", value: format(viewModel.summary.maxBPM), unit: "bpm", icon: "arrow.up.heart")
            StatTile(title: "HRV (SDNN)", value: format(viewModel.summary.hrvSDNN), unit: "ms", icon: "heart.text.square")
            StatTile(title: "Samples", value: "\(viewModel.summary.sampleCount)", unit: "", icon: "number")
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trend")
                .font(.headline)
            if viewModel.samples.isEmpty {
                Text("No heart rate samples in this range. Wear your Apple Watch or record a workout, then pull to refresh.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            } else {
                Chart(viewModel.samples) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("BPM", sample.bpm))
                        .foregroundStyle(.pink)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Time", sample.date), y: .value("BPM", sample.bpm))
                        .foregroundStyle(.pink.opacity(0.5))
                        .symbolSize(16)
                }
                .frame(height: 220)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(Int(value.rounded()))
    }

    private func export() async {
        do {
            let url = try PDFExporter.export(summary: viewModel.summary, samples: viewModel.samples)
            pdfURL = url
            showShare = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title2.weight(.semibold))
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}

#Preview {
    DashboardView()
        .environmentObject(HeartRateViewModel.preview)
}
