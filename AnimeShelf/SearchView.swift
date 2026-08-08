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
                Color(red: 0.025, green: 0.032, blue: 0.052).ignoresSafeArea()
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        TextField("مثال: 86 أو One Piece", text: $query)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .padding(.horizontal, 15)
                            .frame(height: 50)
                            .animeGlass(cornerRadius: 16, interactive: true)
                            .onSubmit { Task { await model.search(query) } }
                        Button("بحث") {
                            Task { await model.search(query) }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isLoading)
                    }
                    .padding(.horizontal, 16)

                    if model.isLoading {
                        ProgressView("جاري البحث…").frame(maxHeight: .infinity)
                    } else if let error = model.errorMessage {
                        ContentUnavailableView("تعذر البحث", systemImage: "wifi.exclamationmark", description: Text(error))
                    } else if model.hasSearched && model.results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        List(model.results) { anime in
                            NavigationLink {
                                AnimeDetailsView(anime: anime)
                            } label: {
                                HStack(spacing: 12) {
                                    AsyncImage(url: anime.coverURL) { phase in
                                        if let image = phase.image { image.resizable().scaledToFill() }
                                        else { Color.white.opacity(0.08) }
                                    }
                                    .frame(width: 58, height: 82)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(anime.name).font(.headline).lineLimit(2)
                                        Text([anime.type, anime.releaseYear, anime.status].compactMap { $0 }.joined(separator: " • "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("البحث")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("إغلاق") { dismiss() }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}
