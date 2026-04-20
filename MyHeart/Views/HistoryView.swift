import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.samples.isEmpty {
                    ContentUnavailableView(
                        "No Heart Rate Data",
                        systemImage: "heart.slash",
                        description: Text("Pull to refresh after recording samples in Apple Health.")
                    )
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
