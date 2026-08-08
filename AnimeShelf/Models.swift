import Foundation

struct Anime: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String?
    let status: String?
    let season: String?
    let releaseYear: String?
    let rating: String?
    let genres: String?
    let coverURL: URL?
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
        case latestEpisodeID = "latest_episode_id"
        case latestEpisodeName = "latest_episode_name"
    }
}

struct AnimePage: Decodable {
    let data: [Anime]
}

struct APIEnvelope<Value: Decodable>: Decodable {
    let response: Value
}

struct Episode: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let number: String
    let sources: [EpisodeSource]

    enum CodingKeys: String, CodingKey {
        case id = "episode_id"
        case name = "episode_name"
        case number = "episode_number"
        case sources = "episode_urls"
    }
}

struct EpisodePage: Decodable {
    let data: [Episode]
    let count: Int?
}

struct EpisodeSource: Codable, Hashable {
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

struct RemoteComment: Identifiable, Hashable {
    let id: String
    let author: String
    let body: String
    let date: String
    let avatarURL: URL?
}

struct ResolvedVideo: Decodable {
    let file: URL
    let label: String
}

struct WatchProgress: Codable, Identifiable, Hashable {
    let episodeID: String
    let animeID: String
    let animeName: String
    let coverURL: URL?
    let episodeNumber: String
    var seconds: Double
    var duration: Double
    var updatedAt: Date

    var id: String { episodeID }
    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }

    var millisecondTime: String {
        TimeFormatter.milliseconds(seconds)
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

