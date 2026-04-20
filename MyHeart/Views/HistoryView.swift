import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.samples.isEmpty {
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
                } else {
                    List(viewModel.samples) { sample in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sample.date, format: .dateTime.month().day().hour().minute())
                                    .font(.subheadline)
                                Text(sample.source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(sample.bpm.rounded())) BPM")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.pink)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
            .refreshable { await viewModel.refresh() }
        }
    }
}

#Preview {
    HistoryView()
        .environmentObject(HeartRateViewModel.preview)
}
