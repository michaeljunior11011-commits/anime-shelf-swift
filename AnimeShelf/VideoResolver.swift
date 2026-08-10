import AVFoundation
import Foundation

actor VideoResolver {
    static let shared = VideoResolver()

    private let session: URLSession
    private var cache: [String: [ResolvedMedia]] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 45
            configuration.requestCachePolicy = .reloadRevalidatingCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func resolve(_ episode: Episode, preference: VideoQualityPreference = .best1080) async throws -> ResolvedMedia {
        guard let first = try await resolveCandidates(episode, preference: preference).first else {
            throw ServiceError.noVideo
        }
        return first
    }

    func resolveCandidates(
        _ episode: Episode,
        preference: VideoQualityPreference = .best1080
    ) async throws -> [ResolvedMedia] {
        let cacheKey = "\(episode.id)|\(preference.rawValue)"
        if let cached = cache[cacheKey], !cached.isEmpty { return cached }

        async let alternateResult = alternateCandidates(for: episode)
        async let primaryResult = primaryCandidates(for: episode)
        let alternate = (try? await alternateResult) ?? []
        let primary = (try? await primaryResult) ?? []
        let candidates = unique(alternate + primary)
        guard !candidates.isEmpty else { throw ServiceError.noVideo }

        // Names such as h.mp4 and uhd_1080p are enough to start playback immediately.
        // AVPlayer later refreshes the displayed dimensions from the actual track.
        var resolved = candidates.map(Self.quickMedia)
        if resolved.allSatisfy({ $0.height == 0 }), let first = candidates.first,
           let inspected = await Self.inspectWithTimeout(first, seconds: 3) {
            resolved[0] = inspected
        }
        resolved.sort { score($0, preference: preference) > score($1, preference: preference) }
        cache[cacheKey] = resolved
        return resolved
    }

    func clearCache() { cache = [:] }

    private func alternateCandidates(for episode: Episode) async throws -> [MediaCandidate] {
        guard let alternate = episode.sources.first(where: {
            $0.serverName.lowercased().contains("muilt") || $0.url.host?.contains("a-reslayer.com") == true
        }) else { return [] }

        let (data, response) = try await session.data(from: alternate.url)
        try validate(response, data: data)
        let object = try JSONSerialization.jsonObject(with: FlexibleJSON.decodedData(from: data))
        let urls = FlexibleJSON.strings(in: object)
            .compactMap(Self.httpURL)
            .filter { $0.pathExtension.lowercased() == "mp4" || $0.host?.localizedCaseInsensitiveContains("mediafire.com") == true }
            .sorted { Self.inferredHeight($0) > Self.inferredHeight($1) }

        return await withTaskGroup(of: MediaCandidate?.self, returning: [MediaCandidate].self) { group in
            for url in urls.prefix(4) {
                group.addTask {
                    if url.host?.localizedCaseInsensitiveContains("mediafire.com") == true {
                        guard let direct = try? await self.resolveMediaFirePage(url) else { return nil }
                        return MediaCandidate(url: direct, sourceName: "MediaFire")
                    }
                    return MediaCandidate(url: url, sourceName: "Alternate CDN")
                }
            }
            var values: [MediaCandidate] = []
            for await value in group { if let value { values.append(value) } }
            return values
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
        let patterns = [
            #"aria-label=[\"']Download file[\"'][^>]*href=[\"']([^\"']+)[\"']"#,
            #"id=[\"']downloadButton[\"'][^>]*href=[\"']([^\"']+)[\"']"#,
            #"(https://download[^\"']+\.mp4[^\"']*)"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = expression.firstMatch(in: html, range: range),
                  let valueRange = Range(match.range(at: 1), in: html) else { continue }
            let decoded = String(html[valueRange]).replacingOccurrences(of: "&amp;", with: "&")
            if let url = Self.httpURL(decoded), url.pathExtension.lowercased() == "mp4" { return url }
        }
        throw ServiceError.noVideo
    }

    private func primaryCandidates(for episode: Episode) async throws -> [MediaCandidate] {
        guard let source = episode.sources.first(where: { $0.url.path.contains("video-qualities.php") }),
              let components = URLComponents(url: source.url, resolvingAgainstBaseURL: false),
              let file = components.queryItems?.first(where: { $0.name == "f" })?.value,
              let episodeNumber = components.queryItems?.first(where: { $0.name == "e" })?.value else {
            return episode.sources
                .filter { $0.url.pathExtension.lowercased() == "mp4" }
                .map { MediaCandidate(url: $0.url, sourceName: $0.serverName) }
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

        let cleaned = FlexibleJSON.decodedData(from: data)
        if let videos = try? JSONDecoder().decode([ResolvedVideo].self, from: cleaned) {
            return videos.map { MediaCandidate(url: $0.file, sourceName: "Anime CDN") }
        }
        let object = try JSONSerialization.jsonObject(with: cleaned)
        return FlexibleJSON.strings(in: object)
            .compactMap(Self.httpURL)
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .map { MediaCandidate(url: $0, sourceName: "Anime CDN") }
    }

    private func unique(_ candidates: [MediaCandidate]) -> [MediaCandidate] {
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.url.absoluteString).inserted }
    }

    private func score(_ media: ResolvedMedia, preference: VideoQualityPreference) -> Double {
        switch preference {
        case .best1080:
            let cappedHeight = min(media.height, 1080)
            return Double(cappedHeight) * 10_000_000 + media.estimatedBitrate
        case .balanced720:
            let heightScore = media.height <= 720 ? Double(media.height) : 680
            return heightScore * 10_000_000 + media.estimatedBitrate
        }
    }

    private nonisolated static func quickMedia(_ candidate: MediaCandidate) -> ResolvedMedia {
        let height = inferredHeight(candidate.url)
        let width: Int
        switch height {
        case 1080: width = 1920
        case 720: width = 1280
        case 480: width = 854
        case 360: width = 640
        default: width = 0
        }
        return ResolvedMedia(url: candidate.url, sourceName: candidate.sourceName, width: width, height: height, estimatedBitrate: 0)
    }

    private nonisolated static func inferredHeight(_ url: URL) -> Int {
        let name = url.lastPathComponent.lowercased()
        if name.contains("1080") || name.contains("uhd") { return 1080 }
        if name == "h.mp4" || name.contains("720") || name.contains("_h.mp4") { return 720 }
        if name == "s.mp4" || name.contains("480") || name.contains("_s.mp4") { return 480 }
        if name == "m.mp4" || name.contains("360") || name.contains("_m.mp4") { return 360 }
        return 0
    }

    private nonisolated static func httpURL(_ raw: String) -> URL? {
        let value = raw
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private nonisolated static func inspectWithTimeout(_ candidate: MediaCandidate, seconds: UInt64) async -> ResolvedMedia? {
        await withTaskGroup(of: ResolvedMedia?.self, returning: ResolvedMedia?.self) { group in
            group.addTask { try? await inspect(candidate) }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    nonisolated static func inspectURL(_ url: URL, sourceName: String) async -> ResolvedMedia? {
        try? await inspect(MediaCandidate(url: url, sourceName: sourceName))
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
