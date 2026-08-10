import Foundation

actor AnimeCloudCommentsService {
    static let shared = AnimeCloudCommentsService()

    private struct CloudAnime: Sendable {
        let id: String
        let name: String
        let keywords: String
    }

    private let session: URLSession
    private var catalog: [CloudAnime]?
    private var episodeMap: [String: String] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func comments(
        animeName: String,
        episodeNumber: String,
        fallbackEpisodeID: String,
        offset: Int = 0
    ) async throws -> [RemoteComment] {
        let cloudEpisodeID = try await resolveEpisodeID(animeName: animeName, episodeNumber: episodeNumber)
            ?? fallbackEpisodeID
        return try await fetchComments(episodeID: cloudEpisodeID, offset: offset)
    }

    private func resolveEpisodeID(animeName: String, episodeNumber: String) async throws -> String? {
        let cacheKey = "\(normalize(animeName))|\(episodeNumber)"
        if let value = episodeMap[cacheKey] { return value }

        let catalog = try await loadCatalog()
        let wanted = normalize(animeName)
        let match = catalog
            .map { ($0, titleScore(wanted, normalize($0.name + " " + $0.keywords))) }
            .filter { $0.1 >= 0.72 }
            .max { $0.1 < $1.1 }?.0
        guard let match else { return nil }

        let object = try await postJSON(
            to: AppConfiguration.commentsCatalogURL,
            values: ["command": "getAnimeDetails", "animeID": match.id]
        )
        guard let dictionary = object as? [String: Any],
              let episodes = dictionary["result"] as? [[String: Any]] else { return nil }
        let wantedNumber = numericEpisode(episodeNumber)
        let episode = episodes.first { row in
            let name = string(row, keys: ["name", "epName", "episode"])
            return numericEpisode(name) == wantedNumber
        }
        guard let episode, let id = string(episode, keys: ["id", "epID"]).nonEmpty else { return nil }
        episodeMap[cacheKey] = id
        return id
    }

    private func loadCatalog() async throws -> [CloudAnime] {
        if let catalog { return catalog }
        async let anime = catalogRequest(command: "getAllAnime")
        async let movies = catalogRequest(command: "getAllMovies")
        let (animeValues, movieValues) = try await (anime, movies)
        let values = animeValues + movieValues
        catalog = values
        return values
    }

    private func catalogRequest(command: String) async throws -> [CloudAnime] {
        let object = try await postJSON(
            to: AppConfiguration.commentsCatalogURL,
            values: ["command": command, "cmode": "0", "hiddenMode": "0"]
        )
        guard let dictionary = object as? [String: Any],
              let rows = dictionary["result"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = string(row, keys: ["id", "animeID"]).nonEmpty,
                  let name = string(row, keys: ["name", "animeName"]).nonEmpty else { return nil }
            return CloudAnime(id: id, name: name, keywords: string(row, keys: ["keywords"]))
        }
    }

    private func fetchComments(episodeID: String, offset: Int) async throws -> [RemoteComment] {
        let object = try await postJSON(
            to: AppConfiguration.commentsURL,
            values: [
                "command": "getComments",
                "offset": String(offset),
                "epID": episodeID,
                "orderBy": "1"
            ]
        )
        let records = findCommentArray(in: object)
        return records.compactMap(makeComment)
    }

    private func postJSON(to url: URL, values: [String: String]) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Anime Cloud/6.5", forHTTPHeaderField: "User-Agent")
        request.httpBody = values.formEncoded
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ServiceError.server("خدمة التعليقات غير متاحة حاليًا.")
        }
        guard !data.isEmpty else { return [:] }
        do {
            return try JSONSerialization.jsonObject(with: FlexibleJSON.decodedData(from: data))
        } catch {
            throw ServiceError.invalidResponse
        }
    }

    private func findCommentArray(in object: Any) -> [[String: Any]] {
        if let records = object as? [[String: Any]] { return records }
        guard let dictionary = object as? [String: Any] else { return [] }
        for key in ["result", "comments", "data", "response"] {
            if let value = dictionary[key] {
                let found = findCommentArray(in: value)
                if !found.isEmpty { return found }
            }
        }
        return []
    }

    private func makeComment(_ json: [String: Any]) -> RemoteComment? {
        let body = string(json, keys: ["content", "comment", "text", "message"])
        guard !body.isEmpty else { return nil }
        let id = string(json, keys: ["id", "commentID", "comment_id"]).nonEmpty ?? UUID().uuidString
        let author = string(json, keys: ["userName", "username", "name", "displayName"]).nonEmpty ?? "مستخدم"
        let date = string(json, keys: ["time", "date", "createdAt", "created_at"])
        let avatar = string(json, keys: ["profilePicture", "image", "avatar", "userImage"])
        return RemoteComment(id: id, author: author, body: body, date: date, avatarURL: URL(string: avatar))
    }

    private func string(_ json: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = json[key] as? String { return value }
            if let value = json[key] as? NSNumber { return value.stringValue }
        }
        return ""
    }

    private func numericEpisode(_ value: String) -> Double? {
        let expression = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression?.matches(in: value, range: range).last,
              let numberRange = Range(match.range(at: 1), in: value) else { return nil }
        return Double(value[numberRange])
    }

    private func normalize(_ value: String) -> String {
        let withoutParentheses = value.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        return withoutParentheses
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\p{Arabic}]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func titleScore(_ wanted: String, _ candidate: String) -> Double {
        if wanted == candidate { return 1 }
        if candidate.hasPrefix(wanted) || wanted.hasPrefix(candidate) { return 0.94 }
        let left = Set(wanted.split(separator: " "))
        let right = Set(candidate.split(separator: " "))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(max(left.count, right.count))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
