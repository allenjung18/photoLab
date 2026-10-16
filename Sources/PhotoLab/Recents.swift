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

/// One entry of Open Recent: a folder (`id` is its path), a Photos album
/// (`id` is its identifier) or a collection (`id` is its
/// `PhotoCollection.id`), with the view state it was left in.
struct RecentSource: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case folder, photos, collection }
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

    /// Unique across the kinds.
    var key: String { kind.rawValue + ":" + id }
}

extension RecentSource.Kind {
    /// The SF Symbol a list shows beside an entry of this kind.
    var symbol: String {
        switch self {
        case .folder: return "folder"
        case .photos: return "photo.on.rectangle"
        case .collection: return "rectangle.stack"
        }
    }
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
/// Library's `AppSettings` (`recents`) beside the last source, most recent
/// first, deduped, capped at `RecentSource.limit`.
extension Library {
    private func storedRecents() -> [RecentSource] {
        settings.recents
    }

    private func store(_ list: [RecentSource]) {
        settings.recents = list
        recentsRevision += 1
    }

    /// The key of the open source, nil when none.
    private var currentSourceKey: String? {
        if let folder { return RecentSource(kind: .folder, id: folder.path, title: "").key }
        if let photos = source as? PhotosSource {
            return RecentSource(kind: .photos, id: photos.album.id, title: "").key
        }
        if let collection = openCollection {
            return RecentSource(kind: .collection, id: collection.id.uuidString, title: "").key
        }
        return nil
    }

    /// The recent sources a menu or the Welcome view lists: a folder that no
    /// longer exists is dropped (and forgotten), and so is an album Photos no
    /// longer lists and a collection no longer saved. Photos entries are
    /// kept out of the list, never prompted for, while access is not
    /// already allowed.
    func recentSources(access: PhotosAccess = .live) -> [RecentSource] {
        _ = recentsRevision
        var list = storedRecents()
        let kept = list.filter { entry in
            switch entry.kind {
            case .folder: return FileManager.default.fileExists(atPath: entry.id)
            case .collection:
                return UUID(uuidString: entry.id).flatMap { collectionStore?.load($0) } != nil
            case .photos: return true
            }
        }
        if kept.count != list.count { list = kept; store(list) }
        var albums: Set<String>?
        if list.contains(where: { $0.kind == .photos }) {
            albums = access.client.authorizationStatus().canRead
                ? Set(access.client.albums().map(\.id)) : []
        }
        return list.filter { $0.kind != .photos || albums?.contains($0.id) == true }
    }

    /// Drops one entry (a deleted collection's) from the list.
    func forgetRecent(_ key: String) {
        let list = storedRecents()
        let kept = list.filter { $0.key != key }
        if kept.count != list.count { store(kept) }
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
        case .collection:
            guard let id = UUID(uuidString: entry.id) else {
                openError = "\(entry.title) is no longer saved"
                return
            }
            openCollection(id, title: entry.title)
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

    /// A rename in place (`Library.rename`): every remembered anchor that
    /// was a moved photo is its new id, so a source reopens on it.
    func rekeyRecentAnchors(_ map: [Photo.ID: Photo.ID]) {
        guard rememberFolder else { return }
        var list = storedRecents()
        var changed = false
        for i in list.indices {
            if let anchor = list[i].state?.anchor, let moved = map[anchor] {
                list[i].state?.anchor = moved
                changed = true
            }
        }
        if changed { store(list) }
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
                        Label(entry.title, systemImage: entry.kind.symbol)
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
