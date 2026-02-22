import SwiftUI

@main
struct VoxscribeApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            AppShellView(viewModel: viewModel)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.light)
                .task {
                    await viewModel.bootstrapIfNeeded()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
