import Foundation

/// How the grid looked when a source was last open: the anchor photo, loupe
/// or grid, and the filter. Remembered per source and restored when it opens
/// again.
struct SourceViewState: Codable, Equatable, Sendable {
    var anchor: PhotoID?
    var loupe: Bool
    /// `PhotoFilter.storageKey`.
    var filter: String
}

/// One entry of Open Recent: a folder (`id` is its path) or a Photos album
/// (`id` is its identifier), with the view state it was left in.
struct RecentSource: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case folder, photos }
    var kind: Kind
    var id: String
    var title: String
    var state: SourceViewState?

    /// The Open Recent list is capped at this many sources.
    static let limit = 10

    init(kind: Kind, id: String, title: String, state: SourceViewState? = nil) {
        self.kind = kind
        self.id = id
        self.title = title
        self.state = state
    }

    /// Unique across the two kinds.
    var key: String { kind.rawValue + ":" + id }
}

extension PhotoFilter {
    var storageKey: String {
        switch self {
        case .all: return "all"
        case .picks: return "picks"
        case .unflagged: return "unflagged"
        case .rejected: return "rejected"
        case .stars(let n): return "stars\(n)"
        }
    }

    init?(storageKey: String) {
        guard let match = Self.allCases.first(where: { $0.storageKey == storageKey }) else { return nil }
        self = match
    }
}

/// Open Recent and reopening where you left off. The list lives in the
/// Library's injected `UserDefaults` beside `lastSourceKind`, most recent
/// first, deduped, capped at `RecentSource.limit`.
extension Library {
    private static let recentsKey = "recentSources"

    private func storedRecents() -> [RecentSource] {
        guard let data = defaults.data(forKey: Self.recentsKey),
              let list = try? JSONDecoder().decode([RecentSource].self, from: data) else { return [] }
        return list
    }

    private func store(_ list: [RecentSource]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.recentsKey)
        recentsRevision += 1
    }

    /// The key of the open source, nil when none.
    private var currentSourceKey: String? {
        if let folder { return RecentSource(kind: .folder, id: folder.path, title: "").key }
        if let photos = source as? PhotosSource {
            return RecentSource(kind: .photos, id: photos.album.id, title: "").key
        }
        return nil
    }

    /// The recent sources a menu or the Welcome view lists: a folder that no
    /// longer exists is dropped (and forgotten), and so is an album Photos no
    /// longer lists. Photos entries are kept out of the list, never
    /// prompted for, while access is not already allowed.
    func recentSources(access: PhotosAccess = .live) -> [RecentSource] {
        _ = recentsRevision
        var list = storedRecents()
        let kept = list.filter { $0.kind != .folder || FileManager.default.fileExists(atPath: $0.id) }
        if kept.count != list.count { list = kept; store(list) }
        var albums: Set<String>?
        if list.contains(where: { $0.kind == .photos }) {
            albums = access.client.authorizationStatus().canRead
                ? Set(access.client.albums().map(\.id)) : []
        }
        return list.filter { $0.kind == .folder || albums?.contains($0.id) == true }
    }

    /// Moves (or adds) the source to the top, keeping any state it has.
    func noteRecent(_ entry: RecentSource) {
        guard rememberFolder else { return }
        var list = storedRecents()
        var entry = entry
        if let old = list.first(where: { $0.key == entry.key }) { entry.state = old.state }
        list.removeAll { $0.key == entry.key }
        list.insert(entry, at: 0)
        store(Array(list.prefix(RecentSource.limit)))
    }

    func clearRecents() {
        store([])
    }

    /// Opens a recent entry (an album through `access`); its view state is
    /// restored by `open`. A missing folder or album is refused like any
    /// other source, with `openError` saying so.
    func openRecent(_ entry: RecentSource, access: PhotosAccess = .live) {
        switch entry.kind {
        case .folder:
            open(URL(fileURLWithPath: entry.id))
        case .photos:
            guard access.client.authorizationStatus().canRead,
                  let album = access.client.albums().first(where: { $0.id == entry.id }) else {
                openError = "\(entry.title) is no longer in Photos"
                return
            }
            open(album: album, access: access)
        }
    }

    /// Remembers the open source's anchor, view and filter against its
    /// recent entry (no reordering).
    func saveViewState() {
        guard rememberFolder, !restoringViewState, let key = currentSourceKey else { return }
        var list = storedRecents()
        guard let i = list.firstIndex(where: { $0.key == key }) else { return }
        let state = SourceViewState(anchor: selection, loupe: loupe, filter: filter.storageKey)
        guard list[i].state != state else { return }
        list[i].state = state
        store(list)
    }

    /// Called at the end of `open`: the filter comes back as it was; the
    /// anchor and the loupe only when the photo is still there and the
    /// restored filter admits it, otherwise today's reset (grid, nothing
    /// selected).
    func restoreViewState() {
        guard rememberFolder, let key = currentSourceKey,
              let state = storedRecents().first(where: { $0.key == key })?.state else { return }
        filter = PhotoFilter(storageKey: state.filter) ?? .all
        if let anchor = state.anchor, photos.contains(where: { $0.id == anchor }), isVisible(anchor) {
            selection = anchor
            loupe = state.loupe
        }
    }
}

import SwiftUI

/// File > Open Recent: the last sources, most recent first, and Clear Menu.
struct OpenRecentMenu: View {
    @Environment(Library.self) private var library

    var body: some View {
        let recents = library.recentSources(access: Self.access)
        Menu("Open Recent") {
            ForEach(recents) { entry in
                Button(entry.title) { library.openRecent(entry) }
            }
            if !recents.isEmpty { Divider() }
            Button("Clear Menu") { library.clearRecents() }
                .disabled(recents.isEmpty)
        }
    }

    /// Photos entries are only listed from an app bundle that can be asked.
    static var access: PhotosAccess { .live }
}

/// The Welcome view's list of recent sources.
struct RecentList: View {
    @Environment(Library.self) private var library

    var body: some View {
        let recents = library.recentSources()
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent").font(.headline)
                ForEach(recents) { entry in
                    Button {
                        library.openRecent(entry)
                    } label: {
                        Label(entry.title, systemImage: entry.kind == .folder ? "folder" : "photo.on.rectangle")
                    }
                    .buttonStyle(.link)
                }
                Button("Clear Menu") { library.clearRecents() }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }
}
