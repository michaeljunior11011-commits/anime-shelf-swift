import SwiftUI

@main
struct AnimeShelfApp: App {
    @StateObject private var progressStore = WatchProgressStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(progressStore)
                .environment(\.layoutDirection, .rightToLeft)
                .preferredColorScheme(.dark)
        }
    }
}

