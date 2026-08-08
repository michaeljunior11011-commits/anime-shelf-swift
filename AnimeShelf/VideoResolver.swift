import Foundation

actor VideoResolver {
    static let shared = VideoResolver()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(_ episode: Episode) async throws -> URL {
        if let alternate = episode.sources.first(where: { $0.serverName.lowercased().contains("muilt") || $0.url.host?.contains("a-reslayer.com") == true }),
           let fullHD = try? await resolveMediaFire1080(from: alternate.url) {
            return fullHD
        }

        if let primary = episode.sources.first(where: { $0.url.path.contains("video-qualities.php") }),
           let fallback = try? await resolvePrimary(from: primary.url) {
            return fallback
        }

        throw ServiceError.noVideo
    }

    private func resolveMediaFire1080(from endpoint: URL) async throws -> URL {
        let (data, response) = try await session.data(from: endpoint)
        try validate(response, data: data)
        let pages = try JSONDecoder().decode([URL].self, from: data)
        let preferred = pages.first { $0.absoluteString.localizedCaseInsensitiveContains("uhd_1080p") }
            ?? pages.first { $0.host?.contains("mediafire.com") == true }
        guard let pageURL = preferred else { throw ServiceError.noVideo }

        var request = URLRequest(url: pageURL)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (htmlData, htmlResponse) = try await session.data(for: request)
        try validate(htmlResponse, data: htmlData)
        guard let html = String(data: htmlData, encoding: .utf8) else { throw ServiceError.noVideo }
        let pattern = #"aria-label=[\"']Download file[\"'][^>]*href=[\"']([^\"']+)[\"']"#
        let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: range),
              let urlRange = Range(match.range(at: 1), in: html) else {
            throw ServiceError.noVideo
        }
        let decoded = String(html[urlRange]).replacingOccurrences(of: "&amp;", with: "&")
        guard let url = URL(string: decoded), url.scheme == "https", url.pathExtension.lowercased() == "mp4" else {
            throw ServiceError.noVideo
        }
        return url
    }

    private func resolvePrimary(from source: URL) async throws -> URL {
        guard let components = URLComponents(url: source, resolvingAgainstBaseURL: false),
              let file = components.queryItems?.first(where: { $0.name == "f" })?.value,
              let episode = components.queryItems?.first(where: { $0.name == "e" })?.value else {
            throw ServiceError.invalidURL
        }
        let endpoint = AppConfiguration.animeBaseURL.appendingPathComponent("v-qs2.php")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.addAnimeClientHeaders()
        request.httpBody = [
            "f": file,
            "e": episode,
            "inf": AppConfiguration.videoResolverSecret
        ].formEncoded
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let videos = try JSONDecoder().decode([ResolvedVideo].self, from: data)
        return videos.first(where: { $0.file.lastPathComponent == "h.mp4" })?.file
            ?? videos.last?.file
            ?? { throw ServiceError.noVideo }()
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, 200..<400 ~= http.statusCode else {
            throw ServiceError.server(String(data: data, encoding: .utf8) ?? "Video server error")
        }
    }
}

