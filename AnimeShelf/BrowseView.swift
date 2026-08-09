import SwiftUI

@MainActor
final class BrowseViewModel: ObservableObject {
    @Published var results: [Anime] = []
    @Published var options: AnimeFilterOptions?
    @Published var filter: BrowseFilter
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?

    private let key = "anime-shelf.browse-filter.v1"
    private var offset = 0
    private var canLoadMore = true

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(BrowseFilter.self, from: data) {
            filter = saved
        } else {
            filter = BrowseFilter()
        }
    }

    func loadInitial() async {
        async let optionRequest = try? AnimeSlayerService.shared.filterOptions()
        await reload()
        options = await optionRequest
    }

    func apply(_ newFilter: BrowseFilter) async {
        filter = newFilter
        if let data = try? JSONEncoder().encode(filter) {
            UserDefaults.standard.set(data, forKey: key)
        }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        offset = 0
        canLoadMore = true
        do {
            results = try await AnimeSlayerService.shared.browse(filter: filter, limit: 40)
            offset = results.count
            canLoadMore = results.count == 40
        } catch {
            results = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadMoreIfNeeded(after anime: Anime) async {
        guard canLoadMore, !isLoading, !isLoadingMore, results.suffix(4).contains(anime) else { return }
        isLoadingMore = true
        do {
            let next = try await AnimeSlayerService.shared.browse(filter: filter, offset: offset, limit: 40)
            let existing = Set(results.map(\.id))
            results.append(contentsOf: next.filter { !existing.contains($0.id) })
            offset += next.count
            canLoadMore = next.count == 40
        } catch {
            canLoadMore = false
        }
        isLoadingMore = false
    }
}

struct BrowseView: View {
    @StateObject private var model = BrowseViewModel()
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var showFilters = false
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                VStack(spacing: 12) {
                    searchAndFilterBar
                    content
                }
            }
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.large)
            .task {
                searchText = model.filter.query
                await model.loadInitial()
            }
            .sheet(isPresented: $showFilters) {
                FilterPanel(filter: model.filter, options: model.options) { filter in
                    showFilters = false
                    Task { await model.apply(filter) }
                }
            }
        }
    }

    private var searchAndFilterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search anime", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { applySearch() }
                if !searchText.isEmpty {
                    Button { searchText = ""; applySearch() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 48)
            .background(AnimeTheme.raised(settings.value), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            Button { showFilters = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.headline).frame(width: 48, height: 48)
                    if model.filter.activeCount > 0 {
                        Text("\(model.filter.activeCount)")
                            .font(.caption2.bold()).foregroundStyle(.black)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(settings.value.accent.color, in: Circle())
                            .offset(x: 4, y: -4)
                    }
                }
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Filter")
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            Spacer(); ProgressView("Loading"); Spacer()
        } else if let error = model.errorMessage {
            Spacer()
            ContentUnavailableView("Unable to load", systemImage: "wifi.exclamationmark", description: Text(error))
            Button("Retry") { Task { await model.reload() } }.buttonStyle(.glassProminent)
            Spacer()
        } else if model.results.isEmpty {
            Spacer(); ContentUnavailableView("No results", systemImage: "magnifyingglass"); Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 11) {
                    ForEach(model.results) { anime in
                        NavigationLink { AnimeDetailsView(anime: anime) } label: {
                            BrowseAnimeRow(anime: anime)
                        }
                        .buttonStyle(.plain)
                        .task { await model.loadMoreIfNeeded(after: anime) }
                    }
                    if model.isLoadingMore { ProgressView().padding() }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.reload() }
        }
    }

    private func applySearch() {
        var newFilter = model.filter
        newFilter.query = searchText
        Task { await model.apply(newFilter) }
    }
}

private struct BrowseAnimeRow: View {
    let anime: Anime
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        HStack(spacing: 14) {
            CachedRemoteImage(url: anime.fullCoverURL ?? anime.coverURL, targetSize: CGSize(width: 95, height: 136)) { image in
                image.resizable().scaledToFill()
            } placeholder: { ArtworkPlaceholder(icon: "photo") }
            .frame(width: 92, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.38), radius: 9, x: -4, y: 6)

            VStack(alignment: .leading, spacing: 8) {
                Text(anime.name).font(.headline).lineLimit(2)
                Text(anime.metadataLine(language: settings.value.language)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let genres = anime.genres {
                    Text(genres).font(.caption).foregroundStyle(settings.value.accent.color).lineLimit(2)
                }
                if let rating = anime.rating { Label(rating, systemImage: "star.fill").font(.caption.weight(.semibold)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.forward").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(AnimeTheme.raised(settings.value), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.06), lineWidth: 0.7) }
    }
}

private struct FilterPanel: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var draft: BrowseFilter
    @State private var expanded: Set<String> = ["Year"]
    let options: AnimeFilterOptions?
    let apply: (BrowseFilter) -> Void

    init(filter: BrowseFilter, options: AnimeFilterOptions?, apply: @escaping (BrowseFilter) -> Void) {
        _draft = State(initialValue: filter)
        self.options = options
        self.apply = apply
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                ScrollView {
                    VStack(spacing: 11) {
                        FilterSection(title: "Year", expanded: binding("Year")) {
                            optionGrid(yearOptions) { option in
                                filterCheck(option.option, selected: draft.years.contains(option.value)) {
                                    toggle(option.value, in: &draft.years)
                                }
                            }
                        }
                        FilterSection(title: "Genre", expanded: binding("Genre")) {
                            optionGrid(options?.genres.data ?? []) { option in
                                filterCheck(option.option, selected: draft.genreIDs.contains(option.value)) {
                                    toggle(option.value, in: &draft.genreIDs)
                                }
                            }
                        }
                        FilterSection(title: "Status", expanded: binding("Status")) {
                            optionGrid(statusOptions) { option in
                                filterCheck(LocalizedStringKey(option.option), selected: draft.statuses.contains(option.value)) {
                                    toggle(option.value, in: &draft.statuses)
                                }
                            }
                        }
                        FilterSection(title: "Type", expanded: binding("Type")) {
                            optionGrid(typeOptions) { option in
                                filterCheck(LocalizedStringKey(option.option), selected: draft.types.contains(option.value)) {
                                    toggle(option.value, in: &draft.types)
                                }
                            }
                        }
                        FilterSection(title: "Season", expanded: binding("Season")) {
                            optionGrid(options?.seasons.data ?? []) { option in
                                filterCheck(option.option, selected: draft.seasons.contains(option.value)) {
                                    toggle(option.value, in: &draft.seasons)
                                }
                            }
                        }
                        FilterSection(title: "Sort", expanded: binding("Sort")) {
                            VStack(spacing: 8) {
                                ForEach(BrowseOrder.allCases) { order in
                                    filterCheck(order.title, selected: draft.order == order) { draft.order = order }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset") { draft = BrowseFilter() }.foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Apply") { apply(draft) }
                    .font(.headline).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(settings.value.accent.color, in: Capsule())
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(.ultraThinMaterial)
            }
        }
    }

    private var yearOptions: [FilterOption] {
        let current = Calendar.current.component(.year, from: Date())
        return (options?.years.data ?? []).filter { (Int($0.value) ?? current) <= current }
    }
    private var statusOptions: [FilterOption] { [
        FilterOption(option: "Currently Airing", value: "Currently Airing"),
        FilterOption(option: "Finished Airing", value: "Finished Airing"),
        FilterOption(option: "Not yet aired", value: "Not yet aired")
    ] }
    private var typeOptions: [FilterOption] { ["TV", "Movie", "OVA", "ONA", "Special"].map { FilterOption(option: $0, value: $0) } }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) }, set: { value in
            if value { expanded.insert(key) } else { expanded.remove(key) }
        })
    }

    private func toggle(_ value: String, in set: inout Set<String>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    private func optionGrid<Content: View>(_ values: [FilterOption], @ViewBuilder content: (FilterOption) -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(values) { content($0) }
        }
    }

    private func filterCheck(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        filterCheck(Text(title), selected: selected, action: action)
    }
    private func filterCheck(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        filterCheck(Text(title), selected: selected, action: action)
    }
    private func filterCheck(_ title: Text, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).stroke(selected ? settings.value.accent.color : .secondary, lineWidth: 1.4)
                    if selected {
                        RoundedRectangle(cornerRadius: 5).fill(settings.value.accent.color)
                        Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.black)
                    }
                }.frame(width: 21, height: 21)
                title.font(.subheadline).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.white.opacity(selected ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }
}

private struct FilterSection<Content: View>: View {
    let title: LocalizedStringKey
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.smooth(duration: 0.24)) { expanded.toggle() } } label: {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0)).foregroundStyle(.secondary)
                }
                .padding(14)
            }.buttonStyle(.plain)
            if expanded { content().padding([.horizontal, .bottom], 12).transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
