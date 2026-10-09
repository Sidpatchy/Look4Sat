import SwiftUI

@main
struct Look4SatApp: App {
    @StateObject private var store = SatelliteStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .preferredColorScheme(store.preferences.lightTheme ? .light : .dark)
                .compositingGroup()
                .colorMultiply(
                    store.preferences.nightMode && !store.preferences.lightTheme
                        ? Color(red: 1, green: 0, blue: 0)
                        : .white
                )
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
