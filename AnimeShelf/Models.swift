import Foundation

struct Anime: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String?
    let status: String?
    let season: String?
    let releaseYear: String?
    let rating: String?
    let genres: String?
    let coverURL: URL?
    let fullCoverURL: URL?
    let bannerURL: URL?
    let synopsis: String?
    let englishTitle: String?
    let latestEpisodeID: String?
    let latestEpisodeName: String?

    enum CodingKeys: String, CodingKey {
        case id = "anime_id"
        case name = "anime_name"
        case type = "anime_type"
        case status = "anime_status"
        case season = "anime_season"
        case releaseYear = "anime_release_year"
        case rating = "anime_rating"
        case genres = "anime_genres"
        case coverURL = "anime_cover_image_url"
        case fullCoverURL = "anime_cover_image_full_url"
        case bannerURL = "anime_banner_image_url"
        case synopsis = "anime_description"
        case englishTitle = "anime_english_title"
        case latestEpisodeID = "latest_episode_id"
        case latestEpisodeName = "latest_episode_name"
    }

    func metadataLine(language: AppLanguage) -> String {
        [releaseYear, localizedType(language), localizedStatus(language)].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " • ")
    }

    private func localizedStatus(_ language: AppLanguage) -> String? {
        guard language == .arabic else { return status }
        switch status {
        case "Currently Airing": return "مستمر"
        case "Finished Airing": return "مكتمل"
        case "Not yet aired": return "قادم"
        default: return status
        }
    }

    private func localizedType(_ language: AppLanguage) -> String? {
        guard language == .arabic else { return type }
        switch type {
        case "TV": return "مسلسل"
        case "Movie": return "فيلم"
        case "Special": return "حلقة خاصة"
        default: return type
        }
    }
}

struct AnimePage: Decodable, Sendable {
    let data: [Anime]
}

struct APIEnvelope<Value: Decodable>: Decodable {
    let response: Value
}

struct AnimeDetails: Decodable, Sendable {
    let id: String
    let name: String
    let type: String?
    let status: String?
    let season: String?
    let releaseYear: String?
    let ageRating: String?
    let rating: String?
    let synopsis: String?
    let englishTitle: String?
    let genres: String?
    let coverURL: URL?
    let fullCoverURL: URL?
    let bannerURL: URL?
    let episodes: EpisodePage

    enum CodingKeys: String, CodingKey {
        case id = "anime_id"
        case name = "anime_name"
        case type = "anime_type"
        case status = "anime_status"
        case season = "anime_season"
        case releaseYear = "anime_release_year"
        case ageRating = "anime_age_rating"
        case rating = "anime_rating"
        case synopsis = "anime_description"
        case englishTitle = "anime_english_title"
        case genres = "anime_genres"
        case coverURL = "anime_cover_image_url"
        case fullCoverURL = "anime_cover_image_full_url"
        case bannerURL = "anime_banner_image_url"
        case episodes
    }

    var anime: Anime {
        Anime(
            id: id,
            name: name,
            type: type,
            status: status,
            season: season,
            releaseYear: releaseYear,
            rating: rating,
            genres: genres,
            coverURL: coverURL,
            fullCoverURL: fullCoverURL,
            bannerURL: bannerURL,
            synopsis: synopsis,
            englishTitle: englishTitle,
            latestEpisodeID: episodes.data.last?.id,
            latestEpisodeName: episodes.data.last?.name
        )
    }
}

struct Episode: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let number: String
    let skipFrom: String?
    let skipTo: String?
    let rating: String?
    let sources: [EpisodeSource]

    enum CodingKeys: String, CodingKey {
        case id = "episode_id"
        case name = "episode_name"
        case number = "episode_number"
        case skipFrom = "skip_from"
        case skipTo = "skip_to"
        case rating = "episode_rating"
        case sources = "episode_urls"
    }

    var serverIntroTiming: IntroTiming? {
        guard let start = Double(skipFrom ?? ""),
              let end = Double(skipTo ?? ""),
              end > start, end > 0 else { return nil }
        return IntroTiming(start: start, end: end, target: end)
    }
}

struct EpisodePage: Decodable, Sendable {
    let data: [Episode]
    let count: Int?
}

struct EpisodeSource: Codable, Hashable, Sendable {
    let id: String
    let serverID: String
    let serverName: String
    let url: URL

    enum CodingKeys: String, CodingKey {
        case id = "episode_url_id"
        case serverID = "episode_server_id"
        case serverName = "episode_server_name"
        case url = "episode_url"
    }
}

struct PlaybackContext: Hashable, Sendable {
    let anime: Anime
    let episodes: [Episode]
    let initialEpisodeID: String
}

struct IntroTiming: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var target: Double

    static let smartDefault = IntroTiming(start: 10, end: 105, target: 90)
}

struct RemoteComment: Identifiable, Hashable, Sendable {
    let id: String
    let author: String
    let body: String
    let date: String
    let avatarURL: URL?
}

struct ResolvedVideo: Decodable, Sendable {
    let file: URL
    let label: String
}

struct ResolvedMedia: Hashable, Sendable {
    let url: URL
    let sourceName: String
    let width: Int
    let height: Int
    let estimatedBitrate: Double

    var qualityLabel: String {
        guard height > 0 else { return "جودة غير معروفة" }
        let bitrate = estimatedBitrate > 0
            ? String(format: "%.2f Mbps", estimatedBitrate / 1_000_000)
            : nil
        return ["\(width)×\(height)", bitrate].compactMap { $0 }.joined(separator: " • ")
    }
}

struct WatchRecord: Codable, Identifiable, Hashable, Sendable {
    let episodeID: String
    let animeID: String
    let animeName: String
    let coverURL: URL?
    let bannerURL: URL?
    let episodeNumber: String
    var seconds: Double
    var duration: Double
    var completed: Bool
    var episodeCount: Int
    var updatedAt: Date

    var id: String { episodeID }
    var fraction: Double {
        guard duration > 0 else { return completed ? 1 : 0 }
        return completed ? 1 : min(max(seconds / duration, 0), 1)
    }

    var millisecondTime: String { TimeFormatter.milliseconds(seconds) }
}

struct AnimeProgressSummary: Identifiable, Hashable, Sendable {
    let animeID: String
    let animeName: String
    let coverURL: URL?
    let bannerURL: URL?
    let latestRecord: WatchRecord
    let totalEpisodes: Int
    let completedEpisodes: Int
    let fraction: Double

    var id: String { animeID }
}

struct FilterOption: Codable, Identifiable, Hashable, Sendable {
    let option: String
    let value: String
    var id: String { value }
}

struct FilterOptionGroup: Decodable, Sendable {
    let data: [FilterOption]
}

struct AnimeFilterOptions: Decodable, Sendable {
    let genres: FilterOptionGroup
    let years: FilterOptionGroup
    let seasons: FilterOptionGroup

    enum CodingKeys: String, CodingKey {
        case genres = "anime_genres"
        case years = "anime_release_years"
        case seasons
    }
}

struct BrowseFilter: Codable, Equatable, Sendable {
    var query = ""
    var years: Set<String> = []
    var genreIDs: Set<String> = []
    var statuses: Set<String> = []
    var types: Set<String> = []
    var seasons: Set<String> = []
    var order: BrowseOrder = .latest

    var activeCount: Int {
        years.count + genreIDs.count + statuses.count + types.count + seasons.count
    }
}

enum BrowseOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case latest = "latest_first"
    case rating = "anime_rating_desc"
    case newestYear = "anime_year_desc"
    case oldestYear = "anime_year_asc"
    case alphabetical = "anime_name_asc"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .latest: return "الأحدث إضافة"
        case .rating: return "الأعلى تقييمًا"
        case .newestYear: return "الأحدث إصدارًا"
        case .oldestYear: return "الأقدم إصدارًا"
        case .alphabetical: return "أبجديًا"
        }
    }
}

enum TimeFormatter {
    static func milliseconds(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00:00.000" }
        let totalMilliseconds = Int((seconds * 1_000).rounded(.down))
        let milliseconds = totalMilliseconds % 1_000
        let totalSeconds = totalMilliseconds / 1_000
        let secs = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3_600
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, milliseconds)
    }
}
