import SwiftUI
import UIKit

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case arabic = "ar"
    case english = "en"
    var id: String { rawValue }
    var title: String { self == .arabic ? "العربية" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }
    var layoutDirection: LayoutDirection { self == .arabic ? .rightToLeft : .leftToRight }
}

enum AppThemeMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark, amoled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "النظام"
        case .light: return "فاتح"
        case .dark: return "داكن"
        case .amoled: return "AMOLED"
        }
    }
}

enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case cyan, blue, purple, red
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cyan: return "سماوي"
        case .blue: return "أزرق"
        case .purple: return "بنفسجي"
        case .red: return "أحمر"
        }
    }
    var color: Color {
        switch self {
        case .cyan: return Color(red: 0.20, green: 0.82, blue: 0.98)
        case .blue: return .blue
        case .purple: return .purple
        case .red: return Color(red: 1, green: 0.22, blue: 0.30)
        }
    }
}

enum VideoQualityPreference: String, Codable, CaseIterable, Identifiable {
    case best1080, balanced720
    var id: String { rawValue }
    var title: String { self == .best1080 ? "أفضل جودة (1080p)" : "متوازن (720p)" }
}

enum BufferPreference: String, Codable, CaseIterable, Identifiable {
    case automatic, stable
    var id: String { rawValue }
    var title: String { self == .automatic ? "تلقائي" : "ثابت للاتصال المتذبذب" }
    var forwardSeconds: TimeInterval { self == .automatic ? 12 : 28 }
}

struct AppSettings: Codable, Equatable {
    var displayName = "مشاهد الأنمي"
    var language = AppLanguage.arabic
    var theme = AppThemeMode.dark
    var accent = AccentChoice.cyan
    var videoQuality = VideoQualityPreference.best1080
    var buffer = BufferPreference.automatic
    var skipIntroEnabled = true
    var autoPlayNext = true
    var globalIntroTiming = IntroTiming.smartDefault
    var introOverrides: [String: IntroTiming] = [:]
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var value: AppSettings { didSet { persist() } }
    @Published private(set) var avatarImage: UIImage?

    private let key = "anime-shelf.settings.v2"
    private let avatarURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("AnimeShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        avatarURL = directory.appendingPathComponent("profile-avatar.jpg")
        if let data = UserDefaults.standard.data(forKey: key),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = settings
        } else {
            value = AppSettings()
        }
        if let data = try? Data(contentsOf: avatarURL) { avatarImage = UIImage(data: data) }
    }

    var preferredColorScheme: ColorScheme? {
        switch value.theme {
        case .system: return nil
        case .light: return .light
        case .dark, .amoled: return .dark
        }
    }

    func introTiming(animeID: String, episode: Episode) -> IntroTiming? {
        guard value.skipIntroEnabled else { return nil }
        return episode.serverIntroTiming ?? value.introOverrides[animeID] ?? value.globalIntroTiming
    }

    func setIntroTiming(_ timing: IntroTiming?, animeID: String) {
        value.introOverrides[animeID] = timing
    }

    func setAvatar(data: Data) {
        guard let source = UIImage(data: data) else { return }
        let target = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: target)
        let rendered = renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.82) else { return }
        try? jpeg.write(to: avatarURL, options: .atomic)
        avatarImage = rendered
    }

    func removeAvatar() {
        try? FileManager.default.removeItem(at: avatarURL)
        avatarImage = nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
