import AVFoundation
import Foundation

actor VideoResolver {
    static let shared = VideoResolver()

    private let session: URLSession
    private var cache: [String: ResolvedMedia] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 18
            configuration.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: configuration)
        }
    }

    func resolve(_ episode: Episode, preference: VideoQualityPreference = .best1080) async throws -> ResolvedMedia {
        let cacheKey = "\(episode.id)|\(preference.rawValue)"
        if let cached = cache[cacheKey] { return cached }

        async let alternateResult = alternateCandidates(for: episode)
        async let primaryResult = primaryCandidates(for: episode)
        let alternate = (try? await alternateResult) ?? []
        let primary = (try? await primaryResult) ?? []
        let candidates = unique(alternate + primary)
        guard !candidates.isEmpty else { throw ServiceError.noVideo }

        let inspected = await withTaskGroup(of: ResolvedMedia?.self, returning: [ResolvedMedia].self) { group in
            for candidate in candidates.prefix(5) {
                group.addTask { await Self.inspectWithTimeout(candidate) }
            }
            var results: [ResolvedMedia] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        let selected: ResolvedMedia
        if let best = inspected.max(by: { score($0, preference: preference) < score($1, preference: preference) }) {
            selected = best
        } else {
            let fallback = candidates[0]
            selected = ResolvedMedia(
                url: fallback.url,
                sourceName: fallback.sourceName,
                width: 0,
                height: inferredHeight(fallback.url),
                estimatedBitrate: 0
            )
        }
        cache[cacheKey] = selected
        return selected
    }

    func clearCache() { cache = [:] }

    private func alternateCandidates(for episode: Episode) async throws -> [MediaCandidate] {
        guard let alternate = episode.sources.first(where: {
            $0.serverName.lowercased().contains("muilt") || $0.url.host?.contains("a-reslayer.com") == true
        }) else { return [] }

        let (data, response) = try await session.data(from: alternate.url)
        try validate(response, data: data)
        let pages = try JSONDecoder().decode([URL].self, from: data)
            .filter { $0.host?.localizedCaseInsensitiveContains("mediafire.com") == true }
            .sorted { lhs, rhs in
                let leftPreferred = lhs.absoluteString.localizedCaseInsensitiveContains("uhd_1080p")
                let rightPreferred = rhs.absoluteString.localizedCaseInsensitiveContains("uhd_1080p")
                return leftPreferred && !rightPreferred
            }

        return await withTaskGroup(of: MediaCandidate?.self, returning: [MediaCandidate].self) { group in
            for page in pages.prefix(2) {
                group.addTask {
                    guard let direct = try? await self.resolveMediaFirePage(page) else { return nil }
                    return MediaCandidate(url: direct, sourceName: "MediaFire")
                }
            }
            var candidates: [MediaCandidate] = []
            for await candidate in group {
                if let candidate { candidates.append(candidate) }
            }
            return candidates
        }
    }

    private func resolveMediaFirePage(_ pageURL: URL) async throws -> URL {
        var request = URLRequest(url: pageURL)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        guard let html = String(data: data, encoding: .utf8) else { throw ServiceError.noVideo }
        let pattern = #"aria-label=[\"']Download file[\"'][^>]*href=[\"']([^\"']+)[\"']"#
        let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let searchRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: searchRange),
              let valueRange = Range(match.range(at: 1), in: html) else { throw ServiceError.noVideo }
        let decoded = String(html[valueRange]).replacingOccurrences(of: "&amp;", with: "&")
        guard let url = URL(string: decoded), url.scheme == "https", url.pathExtension.lowercased() == "mp4" else {
            throw ServiceError.noVideo
        }
        return url
    }

    private func primaryCandidates(for episode: Episode) async throws -> [MediaCandidate] {
        guard let source = episode.sources.first(where: { $0.url.path.contains("video-qualities.php") }),
              let components = URLComponents(url: source.url, resolvingAgainstBaseURL: false),
              let file = components.queryItems?.first(where: { $0.name == "f" })?.value,
              let episodeNumber = components.queryItems?.first(where: { $0.name == "e" })?.value else {
            return []
        }
        let endpoint = AppConfiguration.animeBaseURL.appendingPathComponent("v-qs2.php")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.addAnimeClientHeaders()
        request.httpBody = [
            "f": file,
            "e": episodeNumber,
            "inf": AppConfiguration.videoResolverSecret
        ].formEncoded
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let videos = try JSONDecoder().decode([ResolvedVideo].self, from: data)
        return videos
            .sorted { inferredHeight($0.file) > inferredHeight($1.file) }
            .map { MediaCandidate(url: $0.file, sourceName: "Anime CDN") }
    }

    private func unique(_ candidates: [MediaCandidate]) -> [MediaCandidate] {
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.url.absoluteString).inserted }
    }

    private func score(_ media: ResolvedMedia, preference: VideoQualityPreference) -> Double {
        switch preference {
        case .best1080:
            return Double(media.height) * 10_000_000 + media.estimatedBitrate
        case .balanced720:
            let heightScore = media.height <= 720 ? Double(media.height) : 680
            return heightScore * 10_000_000 + media.estimatedBitrate
        }
    }

    private func inferredHeight(_ url: URL) -> Int {
        let name = url.lastPathComponent.lowercased()
        if name.contains("1080") || name.contains("uhd") { return 1080 }
        if name == "h.mp4" || name.contains("720") { return 720 }
        if name == "s.mp4" || name.contains("480") { return 480 }
        if name == "m.mp4" || name.contains("360") { return 360 }
        return 0
    }

    private nonisolated static func inspectWithTimeout(_ candidate: MediaCandidate) async -> ResolvedMedia? {
        await withTaskGroup(of: ResolvedMedia?.self, returning: ResolvedMedia?.self) { group in
            group.addTask { try? await inspect(candidate) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func inspect(_ candidate: MediaCandidate) async throws -> ResolvedMedia {
        let asset = AVURLAsset(url: candidate.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw ServiceError.noVideo }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bitrate = try await track.load(.estimatedDataRate)
        let transformed = size.applying(transform)
        return ResolvedMedia(
            url: candidate.url,
            sourceName: candidate.sourceName,
            width: Int(abs(transformed.width).rounded()),
            height: Int(abs(transformed.height).rounded()),
            estimatedBitrate: Double(bitrate)
        )
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, 200..<400 ~= http.statusCode else {
            throw ServiceError.server(String(data: data, encoding: .utf8) ?? "Video server error")
        }
    }
}

private struct MediaCandidate: Hashable, Sendable {
    let url: URL
    let sourceName: String
}
