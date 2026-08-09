import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var animeIDs: Set<String> = []
    private let key = "anime-shelf.my-list.v1"

    init() {
        animeIDs = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func contains(_ animeID: String) -> Bool { animeIDs.contains(animeID) }

    func toggle(_ animeID: String) {
        if animeIDs.contains(animeID) { animeIDs.remove(animeID) }
        else { animeIDs.insert(animeID) }
        UserDefaults.standard.set(Array(animeIDs).sorted(), forKey: key)
    }
}
