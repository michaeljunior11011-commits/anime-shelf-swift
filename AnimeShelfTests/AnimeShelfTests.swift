import XCTest
@testable import AnimeShelf

final class AnimeShelfTests: XCTestCase {
    func testTimeFormatterKeepsMilliseconds() {
        XCTAssertEqual(TimeFormatter.milliseconds(976.432), "00:16:16.432")
    }

    func testEpisodeUsesServerIntroMarkersOnlyWhenValid() {
        let marked = episode(id: "1", number: "1", skipFrom: "12", skipTo: "93")
        XCTAssertEqual(marked.serverIntroTiming, IntroTiming(start: 12, end: 93, target: 93))
        XCTAssertNil(episode(id: "2", number: "2", skipFrom: "0", skipTo: "0").serverIntroTiming)
    }

    func testBrowseFilterRoundTrip() throws {
        var filter = BrowseFilter()
        filter.years = ["2026", "2025"]
        filter.genreIDs = ["1", "10"]
        filter.order = .rating
        let data = try JSONEncoder().encode(filter)
        XCTAssertEqual(try JSONDecoder().decode(BrowseFilter.self, from: data), filter)
    }

    @MainActor
    func testProgressPersistsExactResumePosition() throws {
        let url = temporaryFile("exact-position")
        let store = WatchProgressStore(fileURL: url)
        store.save(
            anime: anime(),
            episode: episode(id: "ep-7", number: "7"),
            seconds: 976.432,
            duration: 1_420.096,
            episodeCount: 12
        )
        let reloaded = WatchProgressStore(fileURL: url)
        XCTAssertEqual(reloaded.progress(for: "ep-7")?.seconds ?? 0, 976.432, accuracy: 0.001)
        XCTAssertEqual(reloaded.progress(for: "ep-7")?.millisecondTime, "00:16:16.432")
    }

    @MainActor
    func testCompletionRequiresExplicitEndEventCall() {
        let url = temporaryFile("completion")
        let store = WatchProgressStore(fileURL: url)
        let anime = anime()
        let episode = episode(id: "ep-1", number: "1")
        store.save(anime: anime, episode: episode, seconds: 1_419, duration: 1_420, episodeCount: 3)
        XCTAssertFalse(store.progress(for: episode.id)?.completed ?? true)
        store.markCompleted(anime: anime, episode: episode, duration: 1_420, episodeCount: 3)
        XCTAssertTrue(store.progress(for: episode.id)?.completed ?? false)
    }

    @MainActor
    func testAnimeSummaryCombinesEpisodesAndMinutes() {
        let store = WatchProgressStore(fileURL: temporaryFile("summary"))
        let anime = anime()
        let first = episode(id: "ep-1", number: "1")
        let second = episode(id: "ep-2", number: "2")
        store.markCompleted(anime: anime, episode: first, duration: 100, episodeCount: 4)
        store.save(anime: anime, episode: second, seconds: 50, duration: 100, episodeCount: 4)
        XCTAssertEqual(store.continueWatching.first?.fraction ?? 0, 0.375, accuracy: 0.0001)
    }

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimeShelfTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("\(name).json")
    }

    private func anime() -> Anime {
        Anime(
            id: "anime-1",
            name: "Test Anime",
            type: "TV",
            status: "Currently Airing",
            season: "Summer",
            releaseYear: "2026",
            rating: "8.5",
            genres: "Action",
            coverURL: nil,
            fullCoverURL: nil,
            bannerURL: nil,
            synopsis: nil,
            englishTitle: nil,
            latestEpisodeID: nil,
            latestEpisodeName: nil
        )
    }

    private func episode(
        id: String,
        number: String,
        skipFrom: String? = nil,
        skipTo: String? = nil
    ) -> Episode {
        Episode(
            id: id,
            name: "Episode \(number)",
            number: number,
            skipFrom: skipFrom,
            skipTo: skipTo,
            rating: nil,
            sources: []
        )
    }
}

