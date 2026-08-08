import SwiftUI

struct AnimeDetailsView: View {
    let anime: Anime
    @State private var episodes: [Episode] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var commentsEpisode: Episode?

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.032, blue: 0.052).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    hero
                    if isLoading {
                        ProgressView("جاري تحميل الحلقات…").padding(.top, 30)
                    } else if let errorMessage {
                        ContentUnavailableView("تعذر تحميل الحلقات", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(episodes) { episode in
                                episodeRow(episode)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .navigationTitle(anime.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadEpisodes() }
        .sheet(item: $commentsEpisode) { episode in
            CommentsView(episodeID: episode.id)
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: anime.coverURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Color.white.opacity(0.08) }
            }
            .frame(height: 300)
            .clipped()
            .overlay(.black.opacity(0.25))
            .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 7) {
                Text(anime.name).font(.title2.bold())
                HStack(spacing: 10) {
                    if let type = anime.type { Text(type) }
                    if let year = anime.releaseYear { Text(year) }
                    if let rating = anime.rating { Label(rating, systemImage: "star.fill") }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }

    private func episodeRow(_ episode: Episode) -> some View {
        NavigationLink {
            PlayerView(anime: anime, episode: episode)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                    .frame(width: 38, height: 38)
                    .background(.cyan.opacity(0.18), in: Circle())
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.name).font(.headline)
                    Text("تشغيل بأفضل جودة متاحة")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    commentsEpisode = episode
                } label: {
                    Image(systemName: "text.bubble")
                        .padding(10)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(13)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func loadEpisodes() async {
        do {
            episodes = try await AnimeSlayerService.shared.episodes(animeID: anime.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

