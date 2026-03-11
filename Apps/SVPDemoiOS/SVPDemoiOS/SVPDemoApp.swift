import SwiftUI

@main
struct SVPDemoApp: App {
    @StateObject private var viewModel = DemoPlayerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}
