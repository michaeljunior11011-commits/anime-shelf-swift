import AVKit
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var currentIndex = 0
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var media: ResolvedMedia?
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published var isMuted = false
    @Published private(set) var didReachEnd = false

    private var context: PlaybackContext?
    private weak var progressStore: WatchProgressStore?
    private weak var settingsStore: AppSettingsStore?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var permitsProgressWrites = false
    private var lastSavedTime = -1.0
    private var loadGeneration = 0

    var hasNextEpisode: Bool {
        guard let context else { return false }
        return currentIndex + 1 < context.episodes.count
    }

    var hasPreviousEpisode: Bool { currentIndex > 0 }

    var shouldShowNextEpisode: Bool {
        hasNextEpisode && duration > 0 && currentTime >= max(duration - 30, 0)
    }

    var shouldShowSkipIntro: Bool {
        guard let context, let episode = currentEpisode, let settingsStore,
              let timing = settingsStore.introTiming(animeID: context.anime.id, episode: episode) else { return false }
        return currentTime >= timing.start && currentTime < timing.end
    }

    func load(
        context: PlaybackContext,
        progressStore: WatchProgressStore,
        settingsStore: AppSettingsStore
    ) async {
        guard self.context == nil else { return }
        self.context = context
        self.progressStore = progressStore
        self.settingsStore = settingsStore
        configureAudio()
        player.automaticallyWaitsToMinimizeStalling = true
        observeTime()

        let initial = context.episodes.firstIndex { $0.id == context.initialEpisodeID } ?? 0
        await playEpisode(at: initial, saveCurrent: false)
    }

    func playNext() {
        guard hasNextEpisode else { return }
        Task { await playEpisode(at: currentIndex + 1, saveCurrent: !didReachEnd) }
    }

    func playPrevious() {
        guard hasPreviousEpisode else { return }
        Task { await playEpisode(at: currentIndex - 1, saveCurrent: true) }
    }

    func skipIntro() {
        guard let context, let episode = currentEpisode, let settingsStore,
              let timing = settingsStore.introTiming(animeID: context.anime.id, episode: episode) else { return }
        player.seek(
            to: CMTime(seconds: timing.target, preferredTimescale: 1_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
        player.volume = isMuted ? 0 : 1
    }

    func saveNow() {
        guard permitsProgressWrites,
              let context,
              let episode = currentEpisode,
              let progressStore,
              duration > 0,
              currentTime.isFinite,
              currentTime >= 0 else { return }
        progressStore.save(
            anime: context.anime,
            episode: episode,
            seconds: min(currentTime, duration),
            duration: duration,
            episodeCount: context.episodes.count
        )
        lastSavedTime = currentTime
    }

    func stop() {
        saveNow()
        progressStore?.flush()
        player.pause()
        removeObservers()
    }

    private func playEpisode(at index: Int, saveCurrent: Bool) async {
        guard let context, context.episodes.indices.contains(index), let settingsStore else { return }
        if saveCurrent { saveNow() }

        loadGeneration += 1
        let generation = loadGeneration
        permitsProgressWrites = false
        didReachEnd = false
        isLoading = true
        errorMessage = nil
        media = nil
        currentTime = 0
        duration = 0
        lastSavedTime = -1
        currentIndex = index
        currentEpisode = context.episodes[index]
        removeEndObserver()

        do {
            let episode = context.episodes[index]
            let resolved = try await VideoResolver.shared.resolve(
                episode,
                preference: settingsStore.value.videoQuality
            )
            guard generation == loadGeneration else { return }
            media = resolved

            let asset = AVURLAsset(
                url: resolved.url,
                options: [
                    AVURLAssetAllowsCellularAccessKey: true,
                    AVURLAssetAllowsExpensiveNetworkAccessKey: true,
                    AVURLAssetAllowsConstrainedNetworkAccessKey: true
                ]
            )
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = settingsStore.value.buffer.forwardSeconds
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            player.replaceCurrentItem(with: item)
            player.isMuted = isMuted
            if !isMuted { player.volume = 1 }
            observeEnd(of: item)

            try await waitUntilReady(item, generation: generation)
            guard generation == loadGeneration else { return }

            let loadedDuration = try? await asset.load(.duration)
            let durationValue = loadedDuration?.seconds ?? item.duration.seconds
            duration = durationValue.isFinite ? durationValue : 0

            if let saved = progressStore?.progress(for: episode.id),
               !saved.completed,
               saved.seconds > 0.5,
               (duration == 0 || saved.seconds < duration - 2) {
                let target = CMTime(seconds: saved.seconds, preferredTimescale: 1_000)
                _ = await item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = saved.seconds
            }

            guard generation == loadGeneration else { return }
            permitsProgressWrites = true
            isLoading = false
            player.play()
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func waitUntilReady(_ item: AVPlayerItem, generation: Int) async throws {
        for _ in 0..<180 {
            guard generation == loadGeneration else { throw CancellationError() }
            switch item.status {
            case .readyToPlay: return
            case .failed: throw item.error ?? ServiceError.noVideo
            default: try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw ServiceError.server("Video preparation timed out")
    }

    private func observeTime() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 1_000),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = max(seconds, 0) }
                let itemDuration = self.player.currentItem?.duration.seconds ?? 0
                if itemDuration.isFinite, itemDuration > 0 { self.duration = itemDuration }
                if self.permitsProgressWrites,
                   self.currentTime > 0,
                   abs(self.currentTime - self.lastSavedTime) >= 2 {
                    self.saveNow()
                }
                self.objectWillChange.send()
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      let context = self.context,
                      let episode = self.currentEpisode else { return }
                self.didReachEnd = true
                self.permitsProgressWrites = false
                self.progressStore?.markCompleted(
                    anime: context.anime,
                    episode: episode,
                    duration: self.duration,
                    episodeCount: context.episodes.count
                )
                self.progressStore?.flush()
                if self.settingsStore?.value.autoPlayNext == true, self.hasNextEpisode {
                    self.playNext()
                }
            }
        }
    }

    private func removeEndObserver() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    private func removeObservers() {
        removeEndObserver()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func configureAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            try? session.setCategory(.playback)
            try? session.setActive(true)
        }
    }
}

struct PlayerView: View {
    let context: PlaybackContext
    @EnvironmentObject private var progressStore: WatchProgressStore
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PlayerViewModel()
    @State private var showComments = false
    @State private var showFullScreen = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 15) {
                VideoStage(model: model, showFullScreen: { showFullScreen = true })
                    .aspectRatio(16 / 9, contentMode: .fit)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(context.anime.name).font(.headline).lineLimit(1)
                        if let episode = model.currentEpisode {
                            Text("Episode") + Text(" \(episode.number)")
                        }
                    }
                    Spacer()
                    Button("Comments", systemImage: "text.bubble.fill") { showComments = true }
                        .buttonStyle(.glassProminent)
                        .disabled(model.currentEpisode == nil)
                }
                .padding(.horizontal, 16)

                if let media = model.media {
                    HStack(spacing: 8) {
                        Label(media.qualityLabel, systemImage: "4k.tv")
                        Text("•")
                        Text(media.sourceName)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                Text("\(TimeFormatter.milliseconds(model.currentTime)) / \(TimeFormatter.milliseconds(model.duration))")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(settingsStore.value.accent.color)

                HStack(spacing: 12) {
                    Button("Previous Episode", systemImage: "backward.end.fill") { model.playPrevious() }
                        .buttonStyle(.glass)
                        .disabled(!model.hasPreviousEpisode)
                    Button("Next Episode", systemImage: "forward.end.fill") { model.playNext() }
                        .buttonStyle(.glass)
                        .disabled(!model.hasNextEpisode)
                }

                if model.isLoading { ProgressView("Preparing best quality") }
                if let error = model.errorMessage {
                    ContentUnavailableView("Unable to play episode", systemImage: "play.slash", description: Text(error))
                }
                Spacer(minLength: 0)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(context: context, progressStore: progressStore, settingsStore: settingsStore) }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { model.saveNow(); progressStore.flush() }
        }
        .sheet(isPresented: $showComments) {
            if let episode = model.currentEpisode { CommentsView(episodeID: episode.id) }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenPlayer(model: model, isPresented: $showFullScreen)
        }
    }
}

private struct VideoStage: View {
    @ObservedObject var model: PlayerViewModel
    let showFullScreen: (() -> Void)?
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        ZStack {
            SystemVideoPlayer(player: model.player)
            VStack {
                HStack {
                    Spacer()
                    Button { model.toggleMute() } label: {
                        Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.glass)
                    if let showFullScreen {
                        Button(action: showFullScreen) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .frame(width: 42, height: 42)
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
                .padding(10)
                Spacer()
                HStack {
                    if model.shouldShowSkipIntro {
                        Button("Skip Intro", systemImage: "forward.end.fill") { model.skipIntro() }
                            .buttonStyle(.glassProminent)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer()
                    if model.shouldShowNextEpisode {
                        Button("Next Episode", systemImage: "forward.end.fill") { model.playNext() }
                            .buttonStyle(.glassProminent)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(14)
                .animation(.smooth(duration: 0.25), value: model.shouldShowSkipIntro)
                .animation(.smooth(duration: 0.25), value: model.shouldShowNextEpisode)
            }
        }
        .background(.black)
    }
}

private struct SystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}

private struct FullScreenPlayer: View {
    @ObservedObject var model: PlayerViewModel
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoStage(model: model, showFullScreen: nil).ignoresSafeArea()
            Button { isPresented = false } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
            }
            .buttonStyle(.glassProminent)
            .padding(18)
        }
        .onAppear { model.player.play() }
    }
}
