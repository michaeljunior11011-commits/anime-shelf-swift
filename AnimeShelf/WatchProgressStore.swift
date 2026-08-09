import Foundation

@MainActor
final class WatchProgressStore: ObservableObject {
    @Published private(set) var records: [WatchRecord] = []

    private let fileURL: URL
    private let legacyKey = "anime-shelf.watch-progress.v1"
    private let legacyDataOverride: Data?

    init(fileURL: URL? = nil, legacyData: Data? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = support.appendingPathComponent("AnimeShelf", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("watch-history-v2.json")
        }
        legacyDataOverride = legacyData
        load()
    }

    var continueWatching: [AnimeProgressSummary] {
        let grouped = Dictionary(grouping: records, by: \.animeID)
        return grouped.compactMap { animeID, animeRecords in
            guard let latestIncomplete = animeRecords
                .filter({ !$0.completed })
                .max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
            let total = max(max(animeRecords.map(\.episodeCount).max() ?? 0, animeRecords.count), 1)
            let completed = animeRecords.filter(\.completed).count
            let watched = animeRecords.reduce(0.0) { $0 + $1.fraction }
            return AnimeProgressSummary(
                animeID: animeID,
                animeName: latestIncomplete.animeName,
                coverURL: latestIncomplete.coverURL,
                bannerURL: latestIncomplete.bannerURL,
                latestRecord: latestIncomplete,
                totalEpisodes: total,
                completedEpisodes: completed,
                fraction: min(max(watched / Double(total), 0), 1)
            )
        }
        .sorted { $0.latestRecord.updatedAt > $1.latestRecord.updatedAt }
    }

    var animeSummaries: [AnimeProgressSummary] {
        let grouped = Dictionary(grouping: records, by: \.animeID)
        return grouped.compactMap { animeID, animeRecords in
            guard let latest = animeRecords.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
            let total = max(max(animeRecords.map(\.episodeCount).max() ?? 0, animeRecords.count), 1)
            let completed = animeRecords.filter(\.completed).count
            let watched = animeRecords.reduce(0.0) { $0 + $1.fraction }
            return AnimeProgressSummary(
                animeID: animeID,
                animeName: latest.animeName,
                coverURL: latest.coverURL,
                bannerURL: latest.bannerURL,
                latestRecord: latest,
                totalEpisodes: total,
                completedEpisodes: completed,
                fraction: min(max(watched / Double(total), 0), 1)
            )
        }.sorted { $0.latestRecord.updatedAt > $1.latestRecord.updatedAt }
    }

    func progress(for episodeID: String) -> WatchRecord? {
        records.first { $0.episodeID == episodeID }
    }

    func register(anime: Anime, episodes: [Episode]) {
        var changed = false
        for index in records.indices where records[index].animeID == anime.id {
            if records[index].episodeCount != episodes.count || records[index].bannerURL != anime.bannerURL {
                records[index].episodeCount = episodes.count
                records[index].bannerURL = anime.bannerURL
                changed = true
            }
        }
        if changed { persist() }
    }

    func save(
        anime: Anime,
        episode: Episode,
        seconds: Double,
        duration: Double,
        episodeCount: Int,
        completed: Bool = false
    ) {
        guard seconds.isFinite, duration.isFinite, seconds >= 0, duration > 0 else { return }
        let old = progress(for: episode.id)
        let item = WatchRecord(
            episodeID: episode.id,
            animeID: anime.id,
            animeName: anime.name,
            coverURL: anime.fullCoverURL ?? anime.coverURL,
            bannerURL: anime.bannerURL,
            episodeNumber: episode.number,
            seconds: completed ? duration : seconds,
            duration: duration,
            completed: completed || old?.completed == true,
            episodeCount: max(episodeCount, old?.episodeCount ?? 0),
            updatedAt: Date()
        )
        records.removeAll { $0.episodeID == episode.id }
        records.append(item)
        records.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    func markCompleted(anime: Anime, episode: Episode, duration: Double, episodeCount: Int) {
        let knownDuration = duration > 0 ? duration : (progress(for: episode.id)?.duration ?? 0)
        guard knownDuration > 0 else { return }
        save(
            anime: anime,
            episode: episode,
            seconds: knownDuration,
            duration: knownDuration,
            episodeCount: episodeCount,
            completed: true
        )
    }

    func remove(episodeID: String) {
        records.removeAll { $0.episodeID == episodeID }
        persist()
    }

    func clearAll() {
        records = []
        persist()
    }

    func flush() { persist() }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([WatchRecord].self, from: data) {
            records = decoded.sorted { $0.updatedAt > $1.updatedAt }
            return
        }
        migrateLegacyProgress()
    }

    private func migrateLegacyProgress() {
        guard let data = legacyDataOverride ?? UserDefaults.standard.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode([LegacyWatchProgress].self, from: data) else { return }
        records = legacy.map {
            WatchRecord(
                episodeID: $0.episodeID,
                animeID: $0.animeID,
                animeName: $0.animeName,
                coverURL: $0.coverURL,
                bannerURL: nil,
                episodeNumber: $0.episodeNumber,
                seconds: $0.seconds,
                duration: $0.duration,
                completed: false,
                episodeCount: 1,
                updatedAt: $0.updatedAt
            )
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private struct LegacyWatchProgress: Codable {
    let episodeID: String
    let animeID: String
    let animeName: String
    let coverURL: URL?
    let episodeNumber: String
    let seconds: Double
    let duration: Double
    let updatedAt: Date
}
