import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var results: [Anime] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasSearched = false

    func search(_ query: String) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isLoading = true
        hasSearched = true
        errorMessage = nil
        do {
            results = try await AnimeSlayerService.shared.animeList(
                type: "filter",
                extra: ["anime_name": text],
                limit: 60
            )
        } catch {
            results = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SearchViewModel()
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        TextField("Search anime", text: $query)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .padding(.horizontal, 15)
                            .frame(height: 50)
                            .animeGlass(cornerRadius: 16, interactive: true)
                            .onSubmit { Task { await model.search(query) } }
                        Button("Search") { Task { await model.search(query) } }
                            .buttonStyle(.glassProminent)
                            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isLoading)
                    }
                    .padding(.horizontal, 16)

                    if model.isLoading {
                        ProgressView("Loading").frame(maxHeight: .infinity)
                    } else if let error = model.errorMessage {
                        ContentUnavailableView("Unable to load", systemImage: "wifi.exclamationmark", description: Text(error))
                    } else if model.hasSearched && model.results.isEmpty {
                        ContentUnavailableView("No results", systemImage: "magnifyingglass")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(model.results) { anime in
                                    NavigationLink { AnimeDetailsView(anime: anime) } label: { SearchResultRow(anime: anime) }
                                        .buttonStyle(.plain)
                                }
                            }.padding(.horizontal, 16)
                        }.scrollIndicators(.hidden)
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
    }
}

private struct SearchResultRow: View {
    let anime: Anime
    @EnvironmentObject private var settings: AppSettingsStore
    var body: some View {
        HStack(spacing: 12) {
            CachedRemoteImage(url: anime.coverURL, targetSize: CGSize(width: 62, height: 88)) { image in
                image.resizable().scaledToFill()
            } placeholder: { ArtworkPlaceholder(icon: "photo") }
            .frame(width: 62, height: 88).clipShape(RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(anime.name).font(.headline).lineLimit(2)
                Text(anime.metadataLine(language: settings.value.language)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
        }
        .padding(9)
        .background(AnimeTheme.raised(settings.value), in: RoundedRectangle(cornerRadius: 16))
    }
}
