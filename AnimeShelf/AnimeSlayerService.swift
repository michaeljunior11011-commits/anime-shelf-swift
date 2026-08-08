import Foundation

actor AnimeSlayerService {
    static let shared = AnimeSlayerService()
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func animeList(type: String, extra: [String: Any] = [:], limit: Int = 18) async throws -> [Anime] {
        var payload: [String: Any] = [
            "list_type": type,
            "_offset": 0,
            "_limit": limit,
            "_order_by": "latest_first"
        ]
        extra.forEach { payload[$0.key] = $0.value }
        let url = try endpoint("animes/get-published-animes", json: payload)
        var request = URLRequest(url: url)
        request.addAnimeClientHeaders()
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(APIEnvelope<AnimePage>.self, from: data).response.data
    }

    func episodes(animeID: String) async throws -> [Episode] {
        let payload: [String: Any] = [
            "anime_id": animeID,
            "_offset": 0,
            "_limit": 500,
            "_order_by": "latest_first"
        ]
        let url = try endpoint("episodes/get-episodes", json: payload)
        var request = URLRequest(url: url)
        request.addAnimeClientHeaders()
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(APIEnvelope<EpisodePage>.self, from: data).response.data
            .sorted { (Int($0.number) ?? 0) < (Int($1.number) ?? 0) }
    }

    private func endpoint(_ path: String, json: [String: Any]) throws -> URL {
        let jsonData = try JSONSerialization.data(withJSONObject: json)
        guard let jsonText = String(data: jsonData, encoding: .utf8),
              var components = URLComponents(url: AppConfiguration.animeBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ServiceError.invalidURL
        }
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
