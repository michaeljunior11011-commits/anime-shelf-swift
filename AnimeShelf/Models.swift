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
    var bannerURL: URL?
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

    init(
        id: String, name: String, type: String?, status: String?, season: String?,
        releaseYear: String?, rating: String?, genres: String?, coverURL: URL?,
        fullCoverURL: URL?, bannerURL: URL?, synopsis: String?, englishTitle: String?,
        latestEpisodeID: String?, latestEpisodeName: String?
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.status = status
        self.season = season
        self.releaseYear = releaseYear
        self.rating = rating
        self.genres = genres
        self.coverURL = coverURL
        self.fullCoverURL = fullCoverURL
        self.bannerURL = bannerURL
        self.synopsis = synopsis
        self.englishTitle = englishTitle
        self.latestEpisodeID = latestEpisodeID
        self.latestEpisodeName = latestEpisodeName
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.flexibleStringIfPresent(forKey: .id) ?? UUID().uuidString
        name = values.flexibleStringIfPresent(forKey: .name) ?? "Anime"
        type = values.flexibleStringIfPresent(forKey: .type)
        status = values.flexibleStringIfPresent(forKey: .status)
        season = values.flexibleStringIfPresent(forKey: .season)
        releaseYear = values.flexibleStringIfPresent(forKey: .releaseYear)
        rating = values.flexibleStringIfPresent(forKey: .rating)
        genres = values.flexibleStringIfPresent(forKey: .genres)
        coverURL = values.flexibleURLIfPresent(forKey: .coverURL)
        fullCoverURL = values.flexibleURLIfPresent(forKey: .fullCoverURL)
        bannerURL = values.flexibleURLIfPresent(forKey: .bannerURL)
        synopsis = values.flexibleStringIfPresent(forKey: .synopsis)
        englishTitle = values.flexibleStringIfPresent(forKey: .englishTitle)
        latestEpisodeID = values.flexibleStringIfPresent(forKey: .latestEpisodeID)
        latestEpisodeName = values.flexibleStringIfPresent(forKey: .latestEpisodeName)
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

    enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        data = values.lossyArray(Anime.self, forKey: .data)
    }
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

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.flexibleStringIfPresent(forKey: .id) ?? ""
        name = values.flexibleStringIfPresent(forKey: .name) ?? "Anime"
        type = values.flexibleStringIfPresent(forKey: .type)
        status = values.flexibleStringIfPresent(forKey: .status)
        season = values.flexibleStringIfPresent(forKey: .season)
        releaseYear = values.flexibleStringIfPresent(forKey: .releaseYear)
        ageRating = values.flexibleStringIfPresent(forKey: .ageRating)
        rating = values.flexibleStringIfPresent(forKey: .rating)
        synopsis = values.flexibleStringIfPresent(forKey: .synopsis)
        englishTitle = values.flexibleStringIfPresent(forKey: .englishTitle)
        genres = values.flexibleStringIfPresent(forKey: .genres)
        coverURL = values.flexibleURLIfPresent(forKey: .coverURL)
        fullCoverURL = values.flexibleURLIfPresent(forKey: .fullCoverURL)
        bannerURL = values.flexibleURLIfPresent(forKey: .bannerURL)
        episodes = (try? values.decode(EpisodePage.self, forKey: .episodes)) ?? EpisodePage(data: [], count: 0)
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

    init(
        id: String, name: String, number: String, skipFrom: String?, skipTo: String?,
        rating: String?, sources: [EpisodeSource]
    ) {
        self.id = id
        self.name = name
        self.number = number
        self.skipFrom = skipFrom
        self.skipTo = skipTo
        self.rating = rating
        self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.flexibleStringIfPresent(forKey: .id) ?? UUID().uuidString
        name = values.flexibleStringIfPresent(forKey: .name) ?? "Episode"
        number = values.flexibleStringIfPresent(forKey: .number) ?? "0"
        skipFrom = values.flexibleStringIfPresent(forKey: .skipFrom)
        skipTo = values.flexibleStringIfPresent(forKey: .skipTo)
        rating = values.flexibleStringIfPresent(forKey: .rating)
        sources = values.lossyArray(EpisodeSource.self, forKey: .sources)
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

    enum CodingKeys: String, CodingKey { case data, count, total }

    init(data: [Episode], count: Int?) {
        self.data = data
        self.count = count
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        data = values.lossyArray(Episode.self, forKey: .data)
        count = values.flexibleIntIfPresent(forKey: .count) ?? values.flexibleIntIfPresent(forKey: .total)
    }
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

    init(id: String, serverID: String, serverName: String, url: URL) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.flexibleStringIfPresent(forKey: .id) ?? UUID().uuidString
        serverID = values.flexibleStringIfPresent(forKey: .serverID) ?? ""
        serverName = values.flexibleStringIfPresent(forKey: .serverName) ?? "Server"
        guard let decodedURL = values.flexibleURLIfPresent(forKey: .url) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: values, debugDescription: "Invalid video source URL")
        }
        url = decodedURL
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

    enum CodingKeys: String, CodingKey { case file, url, label, quality }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = values.flexibleURLIfPresent(forKey: .file) ?? values.flexibleURLIfPresent(forKey: .url) else {
            throw DecodingError.dataCorruptedError(forKey: .file, in: values, debugDescription: "Invalid media URL")
        }
        file = value
        label = values.flexibleStringIfPresent(forKey: .label)
            ?? values.flexibleStringIfPresent(forKey: .quality)
            ?? "mp4"
    }
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
        let dimensions = width > 0 ? "\(width)×\(height)" : "\(height)p"
        return [dimensions, bitrate].compactMap { $0 }.joined(separator: " • ")
    }
}

struct WatchRecord: Codable, Identifiable, Hashable, Sendable {
    let episodeID: String
    let animeID: String
    let animeName: String
    let coverURL: URL?
    var bannerURL: URL?
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

    enum CodingKeys: String, CodingKey { case option, value, name, id }

    init(option: String, value: String) {
        self.option = option
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        option = values.flexibleStringIfPresent(forKey: .option)
            ?? values.flexibleStringIfPresent(forKey: .name)
            ?? ""
        value = values.flexibleStringIfPresent(forKey: .value)
            ?? values.flexibleStringIfPresent(forKey: .id)
            ?? option
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(option, forKey: .option)
        try values.encode(value, forKey: .value)
    }
}

struct FilterOptionGroup: Decodable, Sendable {
    let data: [FilterOption]

    enum CodingKeys: String, CodingKey { case data, options }

    init(data: [FilterOption]) { self.data = data }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let items = try? single.decode([FilterOption].self) {
            data = items
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? values.decodeIfPresent([FilterOption].self, forKey: .data))
            ?? (try? values.decodeIfPresent([FilterOption].self, forKey: .options))
            ?? []
    }
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

    init(genres: FilterOptionGroup, years: FilterOptionGroup, seasons: FilterOptionGroup) {
        self.genres = genres
        self.years = years
        self.seasons = seasons
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        genres = (try? values.decodeIfPresent(FilterOptionGroup.self, forKey: .genres)) ?? FilterOptionGroup(data: [])
        years = (try? values.decodeIfPresent(FilterOptionGroup.self, forKey: .years)) ?? FilterOptionGroup(data: [])
        seasons = (try? values.decodeIfPresent(FilterOptionGroup.self, forKey: .seasons)) ?? FilterOptionGroup(data: [])
    }
}

extension AnimeFilterOptions {
    static var fallback: AnimeFilterOptions {
        let genres = [
            ("أكشن", "1"), ("مغامرات", "2"), ("كوميديا", "4"), ("غموض", "7"),
            ("دراما", "8"), ("خيال", "10"), ("رعب", "13"), ("سحر", "15"),
            ("رومانسي", "21"), ("مدرسي", "22"), ("خيال علمي", "23"),
            ("شونين", "25"), ("رياضي", "27"), ("قوى خارقة", "28"),
            ("شريحة من الحياة", "31"), ("خارق للطبيعة", "32"), ("نفسي", "35"),
            ("إثارة", "36"), ("سينين", "37"), ("إيسيكاي", "39")
        ].map { FilterOption(option: $0.0, value: $0.1) }
        let current = Calendar.current.component(.year, from: Date())
        let years = stride(from: current, through: 1950, by: -1)
            .map { FilterOption(option: String($0), value: String($0)) }
        let seasons = ["Winter", "Spring", "Summer", "Fall"]
            .map { FilterOption(option: $0, value: $0) }
        return AnimeFilterOptions(
            genres: FilterOptionGroup(data: genres),
            years: FilterOptionGroup(data: years),
            seasons: FilterOptionGroup(data: seasons)
        )
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
