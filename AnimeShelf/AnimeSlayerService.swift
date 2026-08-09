import Foundation

actor AnimeSlayerService {
    static let shared = AnimeSlayerService()
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.urlCache = URLCache(
                memoryCapacity: 16 * 1_024 * 1_024,
                diskCapacity: 80 * 1_024 * 1_024
            )
            self.session = URLSession(configuration: configuration)
        }
    }

    func animeList(
        type: String,
        extra: [String: Any] = [:],
        offset: Int = 0,
        limit: Int = 18,
        orderBy: String = "latest_first"
    ) async throws -> [Anime] {
        var payload: [String: Any] = [
            "list_type": type,
            "_offset": offset,
            "_limit": limit,
            "_order_by": orderBy
        ]
        extra.forEach { payload[$0.key] = $0.value }
        let url = try jsonEndpoint("animes/get-published-animes", json: payload)
        return try await request(APIEnvelope<AnimePage>.self, url: url).response.data
    }

    func browse(filter: BrowseFilter, offset: Int = 0, limit: Int = 40) async throws -> [Anime] {
        var extra: [String: Any] = [:]
        if !filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            extra["anime_name"] = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !filter.years.isEmpty { extra["anime_release_years"] = filter.years.sorted() }
        if !filter.genreIDs.isEmpty { extra["anime_genre_ids"] = filter.genreIDs.sorted() }
        if !filter.statuses.isEmpty { extra["anime_status"] = filter.statuses.sorted() }
        if !filter.types.isEmpty { extra["anime_type"] = filter.types.sorted() }
        if !filter.seasons.isEmpty { extra["anime_season"] = filter.seasons.sorted() }
        return try await animeList(
            type: "filter",
            extra: extra,
            offset: offset,
            limit: limit,
            orderBy: filter.order.rawValue
        )
    }

    func details(animeID: String) async throws -> AnimeDetails {
        guard var components = URLComponents(
            url: AppConfiguration.animeBaseURL.appendingPathComponent("anime/get-anime-details"),
            resolvingAgainstBaseURL: false
        ) else { throw ServiceError.invalidURL }
        components.queryItems = [URLQueryItem(name: "anime_id", value: animeID)]
        guard let url = components.url else { throw ServiceError.invalidURL }
        return try await request(APIEnvelope<AnimeDetails>.self, url: url).response
    }

    func episodes(animeID: String) async throws -> [Episode] {
        try await details(animeID: animeID).episodes.data
            .sorted { (Int($0.number) ?? 0) < (Int($1.number) ?? 0) }
    }

    func filterOptions() async throws -> AnimeFilterOptions {
        let url = AppConfiguration.animeBaseURL.appendingPathComponent("animes/get-anime-dropdowns")
        return try await request(APIEnvelope<AnimeFilterOptions>.self, url: url).response
    }

    private func request<Value: Decodable>(_ type: Value.Type, url: URL) async throws -> Value {
        var request = URLRequest(url: url)
        request.addAnimeClientHeaders()
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(type, from: data)
    }

    private func jsonEndpoint(_ path: String, json: [String: Any]) throws -> URL {
        let jsonData = try JSONSerialization.data(withJSONObject: json)
        guard let jsonText = String(data: jsonData, encoding: .utf8),
              var components = URLComponents(
                url: AppConfiguration.animeBaseURL.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
              ) else { throw ServiceError.invalidURL }
        components.queryItems = [URLQueryItem(name: "json", value: jsonText)]
        guard let url = components.url else { throw ServiceError.invalidURL }
        return url
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw ServiceError.server(message)
        }
    }
}

enum ServiceError: LocalizedError {
    case invalidURL
    case noVideo
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "تعذر إنشاء رابط صالح."
        case .noVideo: return "لا يوجد مصدر فيديو صالح لهذه الحلقة."
        case .server(let message): return message
        }
    }
}
