import SwiftUI

struct HomeView: View {
    @StateObject private var model = HomeViewModel()
    @EnvironmentObject private var progressStore: WatchProgressStore
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var showSearch = false
    @State private var selectedAnime: Anime?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        header
                        featuredSection
                        animeRail(title: "Top 10", items: model.topTen, ranked: true)
                        continueWatching
                        animeRail(title: "New This Week", items: model.latest)
                        animeRail(title: "Top Rated", items: model.topRated)
                        animeRail(title: "Movies", items: model.movies)
                        animeRail(title: "Completed Picks", items: model.completed)

                        if let error = model.errorMessage {
                            retryCard(error)
                        }
                    }
                    .padding(.bottom, 36)
                }
                .refreshable { await model.load() }
                .scrollIndicators(.hidden)

                if model.isLoading && model.featured == nil {
                    ProgressView("Loading")
                        .controlSize(.large)
                        .padding(22)
                        .animeGlass(cornerRadius: 22)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.load() }
            .sheet(isPresented: $showSearch) { SearchView() }
            .navigationDestination(item: $selectedAnime) { anime in
                AnimeDetailsView(anime: anime)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Anime Shelf")
                    .font(.caption.weight(.black))
                    .tracking(2.7)
                    .foregroundStyle(settings.value.accent.color)
                Text(settings.value.displayName)
                    .font(.title2.bold())
                    .lineLimit(1)
            }
            Spacer()
            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(settings.value.accent.color.opacity(0.14)).interactive(), in: Circle())
            .accessibilityLabel("Search")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var featuredSection: some View {
        if let anime = model.featured {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Featured")
                FeaturedAnimeCard(anime: anime) { selectedAnime = anime }
                    .padding(.horizontal, 18)
            }
        }
    }

    @ViewBuilder
    private var continueWatching: some View {
        if !progressStore.continueWatching.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Continue Watching")
                ZStack {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 14) {
                            ForEach(progressStore.continueWatching) { summary in
                                NavigationLink {
                                    ResumePlayerView(summary: summary)
                                } label: {
                                    ContinueWatchingCard(summary: summary)
                                }
                                .buttonStyle(.plain)
                                .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                    content
                                        .scaleEffect(phase.isIdentity ? 1 : 0.93)
                                        .brightness(phase.isIdentity ? 0 : -0.17)
                                        .opacity(phase.isIdentity ? 1 : 0.76)
                                }
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 18)
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                    EdgeFade()
                }
            }
        }
    }

    @ViewBuilder
    private func animeRail(title: LocalizedStringKey, items: [Anime], ranked: Bool = false) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: title)
                ZStack {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 13) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, anime in
                                Button { selectedAnime = anime } label: {
                                    PosterCard(anime: anime, rank: ranked ? index + 1 : nil)
                                }
                                .buttonStyle(.plain)
                                .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                    content
                                        .scaleEffect(phase.isIdentity ? 1 : 0.91)
                                        .brightness(phase.isIdentity ? 0 : -0.22)
                                        .saturation(phase.isIdentity ? 1 : 0.72)
                                        .opacity(phase.isIdentity ? 1 : 0.72)
                                }
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 18)
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    EdgeFade()
                }
            }
        }
    }

    private func retryCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(settings.value.accent.color)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Retry") { Task { await model.load() } }.buttonStyle(.glassProminent)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .animeGlass(cornerRadius: 22)
        .padding(.horizontal, 18)
    }
}
private struct FeaturedAnimeCard: View {
    let anime: Anime
    let open: () -> Void
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedRemoteImage(
                url: anime.bannerURL ?? anime.fullCoverURL ?? anime.coverURL,
                targetSize: CGSize(width: 760, height: 880)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ArtworkPlaceholder()
            }
            .blur(radius: 18)
            .scaleEffect(1.12)
            .opacity(0.48)

            CachedRemoteImage(
                url: anime.fullCoverURL ?? anime.coverURL ?? anime.bannerURL,
                targetSize: CGSize(width: 660, height: 920)
            ) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ArtworkPlaceholder()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 8)

            LinearGradient(
                colors: [.black.opacity(0.04), .clear, .black.opacity(0.28), .black.opacity(0.98)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 11) {
                if let rating = anime.rating { CyanBadge(text: "★ \(rating)") }
                Text(anime.name)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .lineLimit(2)
                Text(anime.metadataLine(language: settings.value.language)).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.72))
                HStack(spacing: 10) {
                    Button(action: open) {
                        Label("Play", systemImage: "play.fill")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.white, in: Capsule())
                    }
                    Button { library.toggle(anime.id) } label: {
                        Label("My List", systemImage: library.contains(anime.id) ? "checkmark" : "plus")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(18)
        }
        .frame(height: 480)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.55), radius: 22, x: -10, y: 14)
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture(perform: open)
    }
}

private struct PosterCard: View {
    let anime: Anime
    let rank: Int?
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                CachedRemoteImage(url: anime.fullCoverURL ?? anime.coverURL, targetSize: CGSize(width: 155, height: 225)) { image in
                    image.resizable().scaledToFill()
                } placeholder: { ArtworkPlaceholder(icon: "photo") }
                .frame(width: 150, height: 216)
                .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)

                if let rank {
                    Text("\(rank)")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 5)
                        .padding(8)
                }
            }
            .frame(width: 150, height: 216)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .shadow(color: .black.opacity(0.50), radius: 14, x: -7, y: 9)

            Text(anime.name).font(.subheadline.weight(.semibold)).lineLimit(2).frame(width: 150, alignment: .leading)
            Text(anime.latestEpisodeName ?? anime.metadataLine(language: settings.value.language))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 150, alignment: .leading)
        }
    }
}

private struct ContinueWatchingCard: View {
    let summary: AnimeProgressSummary

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedRemoteImage(
                url: summary.bannerURL ?? summary.coverURL,
                targetSize: CGSize(width: 330, height: 205)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: { ArtworkPlaceholder() }
            .frame(width: 315, height: 195)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.95)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                Text(summary.animeName).font(.headline).lineLimit(1)
                HStack {
                    Text("Episode") + Text(" \(summary.latestRecord.episodeNumber)")
                    Spacer()
                    Image(systemName: "play.fill")
                }
                .font(.caption.weight(.semibold))
                AnimeProgressBar(value: summary.fraction)
            }
            .padding(14)
            .background(.black.opacity(0.28))
        }
        .frame(width: 315, height: 195)
        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 16, x: -8, y: 10)
    }
}

private struct ResumePlayerView: View {
    let summary: AnimeProgressSummary
    @State private var context: PlaybackContext?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let context {
                PlayerView(context: context)
            } else if let errorMessage {
                ContentUnavailableView("Unable to play episode", systemImage: "play.slash", description: Text(errorMessage))
            } else {
                ProgressView("Loading episodes")
            }
        }
        .task {
            do {
                let details = try await AnimeSlayerService.shared.details(animeID: summary.animeID)
                let episodes = details.episodes.data.sorted { (Int($0.number) ?? 0) < (Int($1.number) ?? 0) }
                context = PlaybackContext(
                    anime: details.anime,
                    episodes: episodes,
                    initialEpisodeID: summary.latestRecord.episodeID
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
 
