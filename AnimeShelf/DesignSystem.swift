import SwiftUI

enum AnimeTheme {
    static func background(_ settings: AppSettings) -> Color {
        switch settings.theme {
        case .light: return Color(red: 0.94, green: 0.96, blue: 0.98)
        case .amoled: return .black
        case .system, .dark: return Color(red: 0.022, green: 0.030, blue: 0.050)
        }
    }

    static func raised(_ settings: AppSettings) -> Color {
        settings.theme == .light ? .white : Color.white.opacity(settings.theme == .amoled ? 0.07 : 0.09)
    }
}

struct AppBackdrop: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        ZStack {
            AnimeTheme.background(settings.value)
            RadialGradient(
                colors: [settings.value.accent.color.opacity(0.16), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

struct SectionHeading: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    var action: (() -> Void)? = nil
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.bold())
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let action {
                Button("عرض الكل", action: action)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(settings.value.accent.color)
            }
        }
        .padding(.horizontal, 18)
    }
}

struct AnimeProgressBar: View {
    let value: Double
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.24))
                Capsule()
                    .fill(settings.value.accent.color)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
        .animation(.smooth(duration: 0.28), value: value)
    }
}

struct EdgeFade: View {
    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 28)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.50)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 24)
        }
        .allowsHitTesting(false)
    }
}

struct ArtworkPlaceholder: View {
    var icon = "sparkles.tv"
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [settings.value.accent.color.opacity(0.25), .black.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}

struct CyanBadge: View {
    let text: String
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(.black)
            .background(settings.value.accent.color, in: Capsule())
    }
}
