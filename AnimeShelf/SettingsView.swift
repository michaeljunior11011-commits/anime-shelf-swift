import PhotosUI
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var progressStore: WatchProgressStore
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showClearHistory = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                ScrollView {
                    VStack(spacing: 18) {
                        profileHeader
                        appearanceSection
                        playerSection
                        storageSection
                        aboutSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 34)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Settings")
            .task(id: selectedPhoto) {
                if let data = try? await selectedPhoto?.loadTransferable(type: Data.self) {
                    settings.setAvatar(data: data)
                }
            }
            .alert("Clear Watch History", isPresented: $showClearHistory) {
                Button("Clear Watch History", role: .destructive) { progressStore.clearAll() }
                Button("Close", role: .cancel) {}
            }
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 12) {
            Group {
                if let avatar = settings.avatarImage {
                    Image(uiImage: avatar).resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [settings.value.accent.color, settings.value.accent.color.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Text(settings.value.displayName.prefix(1).uppercased())
                            .font(.system(size: 44, weight: .black, design: .rounded)).foregroundStyle(.black)
                    }
                }
            }
            .frame(width: 116, height: 116)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 2))
            .shadow(color: settings.value.accent.color.opacity(0.25), radius: 24)

            TextField("Display Name", text: $settings.value.displayName)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Text("Local only — no account required").font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Change Photo", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.glassProminent)
                if settings.avatarImage != nil {
                    Button("Remove Photo", systemImage: "trash", role: .destructive) { settings.removeAvatar() }
                        .buttonStyle(.glass)
                }
            }
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .animeGlass(cornerRadius: 26)
    }

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance", icon: "paintbrush.fill") {
            SettingsRow(title: "Language", icon: "globe") {
                HStack(spacing: 6) {
                    ForEach(AppLanguage.allCases) { language in
                        ChoiceChip(title: language.title, selected: settings.value.language == language) {
                            settings.value.language = language
                        }
                    }
                }
            }
            Divider().opacity(0.18)
            VStack(alignment: .leading, spacing: 10) {
                Label("Theme", systemImage: "circle.lefthalf.filled").font(.subheadline.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74))], spacing: 8) {
                    ForEach(AppThemeMode.allCases) { mode in
                        ChoiceChip(title: themeTitle(mode), selected: settings.value.theme == mode) {
                            settings.value.theme = mode
                        }
                    }
                }
            }
            Divider().opacity(0.18)
            VStack(alignment: .leading, spacing: 10) {
                Label("Accent Color", systemImage: "swatchpalette.fill").font(.subheadline.weight(.semibold))
                HStack(spacing: 15) {
                    ForEach(AccentChoice.allCases) { accent in
                        Button { settings.value.accent = accent } label: {
                            ZStack {
                                Circle().fill(accent.color).frame(width: 35, height: 35)
                                if settings.value.accent == accent {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black)
                                }
                            }
                        }.buttonStyle(.plain).accessibilityLabel(accent.title)
                    }
                }
            }
        }
    }

    private var playerSection: some View {
        SettingsSection(title: "Player", icon: "play.rectangle.fill") {
            VStack(alignment: .leading, spacing: 9) {
                Label("Preferred Quality", systemImage: "4k.tv").font(.subheadline.weight(.semibold))
                Picker("Preferred Quality", selection: $settings.value.videoQuality) {
                    Text("Best 1080p").tag(VideoQualityPreference.best1080)
                    Text("Balanced 720p").tag(VideoQualityPreference.balanced720)
                }.pickerStyle(.segmented)
            }
            Divider().opacity(0.18)
            VStack(alignment: .leading, spacing: 9) {
                Label("Buffering", systemImage: "waveform.path").font(.subheadline.weight(.semibold))
                Picker("Buffering", selection: $settings.value.buffer) {
                    Text("Automatic").tag(BufferPreference.automatic)
                    Text("Stable").tag(BufferPreference.stable)
                }.pickerStyle(.segmented)
            }
            Divider().opacity(0.18)
            Toggle(isOn: $settings.value.skipIntroEnabled) {
                Label("Enable Skip Intro", systemImage: "forward.end.fill")
            }
            Toggle(isOn: $settings.value.autoPlayNext) {
                Label("Auto Play Next", systemImage: "forward.frame.fill")
            }
            Divider().opacity(0.18)
            NavigationLink {
                IntroTimingSettingsView()
            } label: {
                HStack {
                    Label("Intro Timing", systemImage: "timer")
                    Spacer()
                    Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                }
            }.buttonStyle(.plain)
        }
    }

    private var storageSection: some View {
        SettingsSection(title: "Image Cache", icon: "internaldrive.fill") {
            Button {
                Task { await ImagePipeline.shared.clear() }
            } label: {
                HStack {
                    Label("Clear Image Cache", systemImage: "photo.stack")
                    Spacer()
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
            Divider().opacity(0.18)
            Button(role: .destructive) { showClearHistory = true } label: {
                HStack {
                    Label("Clear Watch History", systemImage: "clock.badge.xmark")
                    Spacer()
                    Image(systemName: "trash")
                }
            }.buttonStyle(.plain)
        }
    }

    private var aboutSection: some View {
        SettingsSection(title: "About", icon: "info.circle.fill") {
            HStack {
                Text("Anime Shelf")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func themeTitle(_ mode: AppThemeMode) -> String {
        switch mode {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        case .amoled: return "AMOLED"
        }
    }
}

private struct IntroTimingSettingsView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var progressStore: WatchProgressStore

    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                VStack(spacing: 16) {
                    SettingsSection(title: "Intro Timing", icon: "timer") {
                        TimingStepper(title: "Intro Start", value: binding(\.start), range: 0...180)
                        Divider().opacity(0.18)
                        TimingStepper(title: "Intro End", value: binding(\.end), range: 20...240)
                        Divider().opacity(0.18)
                        TimingStepper(title: "Jump To", value: binding(\.target), range: 10...240)
                    }

                    SettingsSection(title: "Custom anime timings", icon: "slider.horizontal.3") {
                        if progressStore.animeSummaries.isEmpty {
                            Text("No watched anime yet").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        } else {
                            ForEach(progressStore.animeSummaries) { summary in
                                AnimeIntroOverrideRow(summary: summary)
                                if summary.id != progressStore.animeSummaries.last?.id { Divider().opacity(0.18) }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Intro Timing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ keyPath: WritableKeyPath<IntroTiming, Double>) -> Binding<Double> {
        Binding(
            get: { settings.value.globalIntroTiming[keyPath: keyPath] },
            set: { settings.value.globalIntroTiming[keyPath: keyPath] = $0 }
        )
    }
}

private struct AnimeIntroOverrideRow: View {
    let summary: AnimeProgressSummary
    @EnvironmentObject private var settings: AppSettingsStore

    private var enabled: Binding<Bool> {
        Binding(
            get: { settings.value.introOverrides[summary.animeID] != nil },
            set: { settings.setIntroTiming($0 ? settings.value.globalIntroTiming : nil, animeID: summary.animeID) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(summary.animeName, isOn: enabled).font(.subheadline.weight(.semibold))
            if settings.value.introOverrides[summary.animeID] != nil {
                HStack {
                    TimingMiniField(label: "Intro Start", value: timingBinding(\.start))
                    TimingMiniField(label: "Intro End", value: timingBinding(\.end))
                    TimingMiniField(label: "Jump To", value: timingBinding(\.target))
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func timingBinding(_ keyPath: WritableKeyPath<IntroTiming, Double>) -> Binding<Double> {
        Binding(
            get: { settings.value.introOverrides[summary.animeID]?[keyPath: keyPath] ?? settings.value.globalIntroTiming[keyPath: keyPath] },
            set: { newValue in
                var timing = settings.value.introOverrides[summary.animeID] ?? settings.value.globalIntroTiming
                timing[keyPath: keyPath] = newValue
                settings.setIntroTiming(timing, animeID: summary.animeID)
            }
        )
    }
}

private struct TimingStepper: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        Stepper(value: $value, in: range, step: 5) {
            HStack { Text(title); Spacer(); Text(TimeFormatter.milliseconds(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
    }
}

private struct TimingMiniField: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    var body: some View {
        VStack(spacing: 5) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Stepper("\(Int(value))s", value: $value, in: 0...240, step: 5).labelsHidden()
            Text("\(Int(value))s").font(.caption.monospacedDigit())
        }.frame(maxWidth: .infinity)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: () -> Content
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(settings.value.accent.color)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AnimeTheme.raised(settings.value), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 21).stroke(.white.opacity(0.07), lineWidth: 0.7) }
    }
}

private struct SettingsRow<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack { Label(title, systemImage: icon).font(.subheadline.weight(.semibold)); Spacer(); content() }
    }
}

private struct ChoiceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @EnvironmentObject private var settings: AppSettingsStore
    var body: some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold))
                .padding(.horizontal, 11).padding(.vertical, 8)
                .foregroundStyle(selected ? .black : .primary)
                .background(selected ? settings.value.accent.color : .white.opacity(0.07), in: Capsule())
        }.buttonStyle(.plain)
    }
}
