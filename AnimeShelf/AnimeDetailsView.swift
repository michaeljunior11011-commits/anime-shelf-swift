import SwiftUI

struct AnimeDetailsView: View {
    let anime: Anime
    @EnvironmentObject private var progressStore: WatchProgressStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var details: AnimeDetails?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var commentsEpisode: Episode?
    @State private var playbackContext: PlaybackContext?

    private var displayAnime: Anime { details?.anime ?? anime }
    private var episodes: [Episode] {
        details?.episodes.data.sorted { (Int($0.number) ?? 0) < (Int($1.number) ?? 0) } ?? []
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                LazyVStack(spacing: 22) {
                    hero
                    information
                    actionButtons

                    if isLoading {
                        ProgressView("Loading episodes").padding(.vertical, 36)
                    } else if let errorMessage {
                        errorCard(errorMessage)
                    } else {
                        episodeList
                    }
                }
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetails() }
        .sheet(item: $commentsEpisode) {
            CommentsView(animeName: displayAnime.name, episodeNumber: $0.number, episodeID: $0.id)
        }
        .navigationDestination(item: $playbackContext) { PlayerView(context: $0) }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            CachedRemoteImage(
                url: displayAnime.bannerURL ?? displayAnime.fullCoverURL ?? displayAnime.coverURL,
                targetSize: CGSize(width: 820, height: 520)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: { ArtworkPlaceholder() }
            .frame(height: 330)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.05), .black.opacity(0.30), AnimeTheme.background(settings.value)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 14) {
                CachedRemoteImage(
                    url: displayAnime.fullCoverURL ?? displayAnime.coverURL,
                    targetSize: CGSize(width: 130, height: 188)
                ) { image in image.resizable().scaledToFill() }
                placeholder: { ArtworkPlaceholder(icon: "photo") }
                .frame(width: 112, height: 162)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.65), radius: 16, y: 8)

                VStack(alignment: .leading, spacing: 7) {
                    if let english = displayAnime.englishTitle, english != displayAnime.name {
                        Text(english).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(displayAnime.name)
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .lineLimit(3)
                    Text(displayAnime.metadataLine(language: settings.value.language))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 7)
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 360)
    }

    @ViewBuilder
    private var information: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let rating = displayAnime.rating { CyanBadge(text: "★ \(rating)") }
                if let status = displayAnime.status {
                    Text(LocalizedStringKey(status))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.08), in: Capsule())
                }
            }

            if let genres = displayAnime.genres, !genres.isEmpty {
                Text(genres).font(.subheadline.weight(.medium)).foregroundStyle(settings.value.accent.color)
            }
            if let synopsis = displayAnime.synopsis, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    private var actionButtons: some View {
        HStack(spacing: 11) {
            Button { playBestStartingEpisode() } label: {
                Label(hasResume ? "Resume" : "Play", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(.white, in: Capsule())
            }
            .disabled(episodes.isEmpty)

            Button { library.toggle(displayAnime.id) } label: {
                Label("My List", systemImage: library.contains(displayAnime.id) ? "checkmark" : "plus")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 18)
    }

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeading(title: "Episodes", subtitle: "\(episodes.count)")
            LazyVStack(spacing: 11) {
                ForEach(episodes) { episode in
                    EpisodeRow(
                        anime: displayAnime,
                        episode: episode,
                        progress: progressStore.progress(for: episode.id),
                        play: { play(episode) },
                        comments: { commentsEpisode = episode }
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var hasResume: Bool {
        progressStore.records.contains { $0.animeID == displayAnime.id && !$0.completed && $0.seconds > 0 }
    }

    private func playBestStartingEpisode() {
        let record = progressStore.records
            .filter { $0.animeID == displayAnime.id && !$0.completed }
            .max { $0.updatedAt < $1.updatedAt }
        let episode = record.flatMap { record in episodes.first { $0.id == record.episodeID } } ?? episodes.first
        if let episode { play(episode) }
    }

    private func play(_ episode: Episode) {
        playbackContext = PlaybackContext(anime: displayAnime, episodes: episodes, initialEpisodeID: episode.id)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(settings.value.accent.color)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry") { Task { await loadDetails() } }.buttonStyle(.glassProminent)
        }
        .padding(22)
        .animeGlass(cornerRadius: 20)
        .padding(.horizontal, 18)
    }

    private func loadDetails() async {
        isLoading = true
        errorMessage = nil
        do {
            let value = try await AnimeSlayerService.shared.details(animeID: anime.id)
            details = value
            progressStore.register(anime: value.anime, episodes: value.episodes.data)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct EpisodeRow: View {
    let anime: Anime
    let episode: Episode
    let progress: WatchRecord?
    let play: () -> Void
    let comments: () -> Void
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottom) {
                        CachedRemoteImage(
                            url: anime.bannerURL ?? anime.coverURL,
                            targetSize: CGSize(width: 145, height: 88)
                        ) { image in image.resizable().scaledToFill() }
                        placeholder: { ArtworkPlaceholder(icon: "play.fill") }
                        .frame(width: 132, height: 78)
                        .clipped()

                        LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
                        Image(systemName: progress?.completed == true ? "checkmark.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)

                        if let progress {
                            AnimeProgressBar(value: progress.fraction)
                                .padding(.horizontal, 7)
                                .padding(.bottom, 6)
                        }
                    }
                    .frame(width: 132, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Episode") + Text(" \(episode.number)")
                        Text(episode.rating.map { "★ \($0)" } ?? String(localized: "Best available quality"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            Button(action: comments) {
                Image(systemName: "text.bubble")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Comments")
        }
        .padding(10)
        .background(AnimeTheme.raised(settings.value), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 0.7)
        }
    }
}
