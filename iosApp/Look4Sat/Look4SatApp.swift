import SwiftUI

@main
struct Look4SatApp: App {
    @StateObject private var store = SatelliteStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .preferredColorScheme(.dark)
                .task {
                    await store.start()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        guard !Task.isCancelled else { break }
                        await store.recalculatePasses()
                    }
                }
        }
    }
}
