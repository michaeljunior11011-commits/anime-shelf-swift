import Foundation

@MainActor
final class WatchProgressStore: ObservableObject {
    @Published private(set) var entries: [WatchProgress] = []
    private let storageKey = "anime-shelf.watch-progress.v1"

    init() {
        load()
    }

    func progress(for episodeID: String) -> WatchProgress? {
        entries.first { $0.episodeID == episodeID }
    }

    func save(anime: Anime, episode: Episode, seconds: Double, duration: Double) {
        guard seconds.isFinite, duration.isFinite, seconds >= 0, duration > 0 else { return }
        let item = WatchProgress(
            episodeID: episode.id,
            animeID: anime.id,
            animeName: anime.name,
            coverURL: anime.coverURL,
            episodeNumber: episode.number,
            seconds: seconds,
            duration: duration,
            updatedAt: Date()
        )
        entries.removeAll { $0.episodeID == episode.id }
        if seconds < duration - 20 {
            entries.insert(item, at: 0)
        }
        entries.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    func remove(episodeID: String) {
        entries.removeAll { $0.episodeID == episodeID }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WatchProgress].self, from: data) else { return }
        entries = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
