import SwiftUI

@main
struct AnimeShelfApp: App {
    @StateObject private var progressStore = WatchProgressStore()
    @StateObject private var settingsStore = AppSettingsStore()
    @StateObject private var libraryStore = LibraryStore()

    var body: some Scene {
        WindowGroup {
            AnimeShelfRootView()
                .environmentObject(progressStore)
                .environmentObject(settingsStore)
                .environmentObject(libraryStore)
                .environment(\.locale, settingsStore.value.language.locale)
                .environment(\.layoutDirection, settingsStore.value.language.layoutDirection)
                .preferredColorScheme(settingsStore.preferredColorScheme)
                .tint(settingsStore.value.accent.color)
        }
    }
}

private struct AnimeShelfRootView: View {
    @State private var showSplash = true
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        ZStack {
            TabView {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }
                BrowseView()
                    .tabItem { Label("Browse", systemImage: "square.grid.2x2.fill") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }
            .opacity(showSplash ? 0 : 1)

            if showSplash {
                SplashView()
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(2)
            }
        }
        .background(AnimeTheme.background(settings.value))
        .task {
            guard showSplash else { return }
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeInOut(duration: 0.42)) { showSplash = false }
        }
    }
}

private struct SplashView: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        ZStack {
            AnimeTheme.background(settings.value).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(settings.value.accent.color.opacity(0.16)).frame(width: 112, height: 112)
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(settings.value.accent.color)
                }
                .glassEffect(.regular.tint(settings.value.accent.color.opacity(0.12)), in: Circle())
                Text("Anime Shelf")
                    .font(.system(size: 31, weight: .black, design: .rounded))
                    .tracking(1.4)
            }
        }
    }
}
