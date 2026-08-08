import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var latest: [Anime] = []
    @Published var ongoing: [Anime] = []
    @Published var completed: [Anime] = []
    @Published var popular: [Anime] = []
    @Published var isLoading = false
    @Published var failedSections: Set<HomeSection> = []

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        failedSections = []
        await withTaskGroup(of: SectionLoadResult.self) { group in
            group.addTask { await Self.fetch(.latest, type: "latest_episodes") }
            group.addTask { await Self.fetch(.ongoing, type: "currently_airing") }
            group.addTask {
                await Self.fetch(.completed, type: "filter", extra: ["anime_status": "Finished Airing"])
            }
            group.addTask { await Self.fetch(.popular, type: "top_anime") }

            for await result in group {
                switch result.result {
                case .success(let items):
                    switch result.section {
                    case .latest: latest = items
                    case .ongoing: ongoing = items
                    case .completed: completed = items
                    case .popular: popular = items
                    }
                case .failure:
                    failedSections.insert(result.section)
                }
            }
        }
        isLoading = false
    }

    private nonisolated static func fetch(
        _ section: HomeSection,
        type: String,
        extra: [String: Any] = [:]
    ) async -> SectionLoadResult {
        do {
            let items = try await AnimeSlayerService.shared.animeList(type: type, extra: extra)
            return SectionLoadResult(section: section, result: .success(items))
        } catch {
            return SectionLoadResult(section: section, result: .failure(HomeLoadError()))
        }
    }
}

enum HomeSection: Hashable, Sendable {
    case latest, ongoing, completed, popular
}

private struct HomeLoadError: Error, Sendable {}

private struct SectionLoadResult: Sendable {
    let section: HomeSection
    let result: Result<[Anime], HomeLoadError>
}
