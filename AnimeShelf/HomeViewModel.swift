import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var featured: Anime?
    @Published var topTen: [Anime] = []
    @Published var latest: [Anime] = []
    @Published var topRated: [Anime] = []
    @Published var movies: [Anime] = []
    @Published var completed: [Anime] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        async let topRequest = Self.fetch(type: "top_anime", limit: 12)
        async let latestRequest = Self.fetch(type: "latest_episodes", limit: 20)
        async let ratedRequest = Self.fetch(
            type: "filter",
            limit: 20,
            orderBy: "anime_rating_desc"
        )
        async let movieRequest = Self.fetch(
            type: "filter",
            extra: ["anime_type": "Movie"],
            limit: 20,
            orderBy: "anime_rating_desc"
        )
        async let completedRequest = Self.fetch(
            type: "filter",
            extra: ["anime_status": "Finished Airing"],
            limit: 20
        )

        let responses = await (topRequest, latestRequest, ratedRequest, movieRequest, completedRequest)
        topTen = responses.0
        latest = responses.1
        topRated = responses.2
        movies = responses.3
        completed = responses.4
        featured = topTen.first ?? latest.first

        if [topTen, latest, topRated, movies, completed].allSatisfy(\.isEmpty) {
            errorMessage = "تعذر تحميل الصفحة الرئيسية. تحقق من اتصالك ثم حاول مجددًا."
        }
        isLoading = false

        let artwork = (topTen + latest).compactMap(\.coverURL)
        await ImagePipeline.shared.prefetch(artwork, targetSize: CGSize(width: 150, height: 220), scale: 2)
    }

    private nonisolated static func fetch(
        type: String,
        extra: [String: Any] = [:],
        limit: Int,
        orderBy: String = "latest_first"
    ) async -> [Anime] {
        (try? await AnimeSlayerService.shared.animeList(
            type: type,
            extra: extra,
            limit: limit,
            orderBy: orderBy
        )) ?? []
    }
}
