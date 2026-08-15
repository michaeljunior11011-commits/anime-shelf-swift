import SwiftUI

/// Shared, local-only values that let Xcode render app screens without a
/// signed-in account, a running app, or a network request.
struct PreviewEnvironment<Content: View>: View {
    @StateObject private var progressStore = WatchProgressStore()
    @StateObject private var settingsStore = AppSettingsStore()
    @StateObject private var libraryStore = LibraryStore()

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environmentObject(progressStore)
            .environmentObject(settingsStore)
            .environmentObject(libraryStore)
            .environment(\.locale, settingsStore.value.language.locale)
            .environment(\.layoutDirection, settingsStore.value.language.layoutDirection)
            .preferredColorScheme(settingsStore.preferredColorScheme)
            .tint(settingsStore.value.accent.color)
    }
}
