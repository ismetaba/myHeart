import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: HeartRateViewModel

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "heart.fill") }

            HistoryView()
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
        }
        .tint(.pink)
        .alert("Health Access Needed",
               isPresented: .constant(viewModel.authorizationError != nil),
               actions: {
                   Button("OK") { viewModel.authorizationError = nil }
               },
               message: { Text(viewModel.authorizationError ?? "") })
    }
}

#Preview {
    ContentView()
        .environmentObject(HeartRateViewModel.preview)
}
