import AVKit
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    let player = AVPlayer()
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var currentTime = 0.0
    @Published var duration = 0.0
    private var timeObserver: Any?
    private var store: WatchProgressStore?
    private var anime: Anime?
    private var episode: Episode?

    func load(anime: Anime, episode: Episode, store: WatchProgressStore) async {
        guard self.episode == nil else { return }
        self.anime = anime
        self.episode = episode
        self.store = store
        do {
            let url = try await VideoResolver.shared.resolve(episode)
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            if let progress = store.progress(for: episode.id), progress.seconds > 0 {
                await item.seek(to: CMTime(seconds: progress.seconds, preferredTimescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            observeTime()
            player.play()
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func saveNow() {
        guard let anime, let episode, let store else { return }
        store.save(anime: anime, episode: episode, seconds: currentTime, duration: duration)
    }

    func stop() {
        saveNow()
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 1_000),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                let value = self.player.currentItem?.duration.seconds ?? 0
                self.duration = value.isFinite ? value : 0
                self.saveNow()
            }
        }
    }
}

struct PlayerView: View {
    let anime: Anime
    let episode: Episode
    @EnvironmentObject private var progressStore: WatchProgressStore
    @StateObject private var model = PlayerViewModel()
    @State private var showComments = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                VideoPlayer(player: model.player)
                    .aspectRatio(16 / 9, contentMode: .fit)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(anime.name).font(.headline).lineLimit(1)
                        Text("الحلقة \(episode.number)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("التعليقات", systemImage: "text.bubble.fill") {
                        showComments = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)

                Text("\(TimeFormatter.milliseconds(model.currentTime)) / \(TimeFormatter.milliseconds(model.duration))")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.cyan)

                if model.isLoading { ProgressView("جاري تجهيز أفضل جودة…") }
                if let error = model.errorMessage {
                    ContentUnavailableView("تعذر تشغيل الحلقة", systemImage: "play.slash", description: Text(error))
                }
                Spacer()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(anime: anime, episode: episode, store: progressStore) }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showComments) { CommentsView(episodeID: episode.id) }
    }
}

