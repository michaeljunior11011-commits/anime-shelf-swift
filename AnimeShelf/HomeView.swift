import SwiftUI

struct HomeView: View {
    @StateObject private var model = HomeViewModel()
    @EnvironmentObject private var progressStore: WatchProgressStore

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.035, green: 0.047, blue: 0.075), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        header
                        continueWatching
                        animeSection("الحلقات الجديدة", icon: "sparkles", items: model.latest)
                        animeSection("الأنميات المستمرة", icon: "dot.radiowaves.left.and.right", items: model.ongoing)
                        animeSection("الأنميات المكتملة", icon: "checkmark.seal.fill", items: model.completed)
                        animeSection("الأكثر شهرة", icon: "flame.fill", items: model.popular)

                        if let message = model.errorMessage {
                            ContentUnavailableView(
                                "تعذر تحميل القائمة",
                                systemImage: "wifi.exclamationmark",
                                description: Text(message)
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }
                    }
                    .padding(.bottom, 40)
                }
                .refreshable { await model.load() }

                if model.isLoading && model.latest.isEmpty {
                    ProgressView("جاري تحميل الأنميات…")
                        .controlSize(.large)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.load() }
        }
        .tint(Color(red: 0.32, green: 0.77, blue: 0.94))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ANIME SHELF")
                    .font(.caption.weight(.black))
                    .tracking(3)
                    .foregroundStyle(.cyan)
                Text("وش نتابع اليوم؟")
                    .font(.largeTitle.bold())
            }
            Spacer()
            Image(systemName: "play.square.stack.fill")
                .font(.system(size: 34))
                .foregroundStyle(.cyan)
                .padding(11)
                .glassEffect(.regular.tint(.cyan.opacity(0.2)).interactive(), in: Circle())
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var continueWatching: some View {
        if !progressStore.entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("أكمل المشاهدة", icon: "clock.arrow.circlepath")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(progressStore.entries) { progress in
                            ContinueCard(progress: progress)
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
            .frame(minHeight: 250)
        }
    }

    private func animeSection(_ title: String, icon: String, items: [Anime]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title, icon: icon)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 13) {
                    ForEach(items) { anime in
                        NavigationLink(value: anime) {
                            AnimeCard(anime: anime)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .navigationDestination(for: Anime.self) { anime in
            AnimeDetailsView(anime: anime)
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        GlassSectionTitle(title: title, icon: icon)
            .padding(.horizontal, 18)
    }
}

private struct AnimeCard: View {
    let anime: Anime

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: anime.coverURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 145, height: 205)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let rating = anime.rating {
                    Label(rating, systemImage: "star.fill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(8)
                }
            }

            Text(anime.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(width: 145, alignment: .leading)
            Text(anime.latestEpisodeName ?? anime.status ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ContinueCard: View {
    let progress: WatchProgress

    var body: some View {
        NavigationLink {
            ResumeView(progress: progress)
        } label: {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: progress.coverURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 315, height: 205)
                .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 7) {
                    Text(progress.animeName).font(.headline).lineLimit(1)
                    HStack {
                        Text("الحلقة \(progress.episodeNumber)")
                        Spacer()
                        Text(progress.millisecondTime).monospacedDigit()
                    }
                    .font(.caption.weight(.medium))
                    ProgressView(value: progress.fraction)
                        .tint(.cyan)
                }
                .padding(14)
            }
            .frame(width: 315, height: 205)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .glassEffect(.regular.tint(.cyan.opacity(0.08)).interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ResumeView: View {
    let progress: WatchProgress
    @State private var episode: Episode?
    @State private var errorMessage: String?

    private var anime: Anime {
        Anime(
            id: progress.animeID,
            name: progress.animeName,
            type: nil,
            status: nil,
            season: nil,
            releaseYear: nil,
            rating: nil,
            genres: nil,
            coverURL: progress.coverURL,
            latestEpisodeID: progress.episodeID,
            latestEpisodeName: "الحلقة \(progress.episodeNumber)"
        )
    }

    var body: some View {
        Group {
            if let episode {
                PlayerView(anime: anime, episode: episode)
            } else if let errorMessage {
                ContentUnavailableView("تعذر استعادة الحلقة", systemImage: "play.slash", description: Text(errorMessage))
            } else {
                ProgressView("استعادة الحلقة عند \(progress.millisecondTime)…")
            }
        }
        .task {
            do {
                let episodes = try await AnimeSlayerService.shared.episodes(animeID: progress.animeID)
                episode = episodes.first { $0.id == progress.episodeID }
                if episode == nil { errorMessage = "لم تعد الحلقة موجودة على المصدر." }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
