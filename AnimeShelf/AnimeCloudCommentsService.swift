import Foundation

actor AnimeCloudCommentsService {
    static let shared = AnimeCloudCommentsService()

    func comments(episodeID: String, offset: Int = 0) async throws -> [RemoteComment] {
        var request = URLRequest(url: AppConfiguration.commentsURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "command": "getComments",
            "offset": String(offset),
            "epID": episodeID,
            "orderBy": "new"
        ].formEncoded

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ServiceError.server("تعذر تحميل التعليقات.")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        let records = findCommentArray(in: object)
        return records.compactMap(makeComment)
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
        let date = string(json, keys: ["date", "createdAt", "created_at", "time"])
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
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

