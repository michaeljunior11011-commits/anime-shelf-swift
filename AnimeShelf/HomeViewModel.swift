import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var latest: [Anime] = []
    @Published var ongoing: [Anime] = []
    @Published var completed: [Anime] = []
    @Published var popular: [Anime] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let latestRequest = AnimeSlayerService.shared.animeList(type: "latest_episodes")
            async let ongoingRequest = AnimeSlayerService.shared.animeList(type: "currently_airing")
            async let completedRequest = AnimeSlayerService.shared.animeList(
                type: "filter",
                extra: ["anime_status": "Finished Airing"]
            )
            async let popularRequest = AnimeSlayerService.shared.animeList(type: "top_anime")
            (latest, ongoing, completed, popular) = try await (
                latestRequest,
                ongoingRequest,
                completedRequest,
                popularRequest
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

