import Foundation
import AppKit
import SwiftUI

/// A saved set of photos across folders (File › Open Collection, Photo ›
/// Add to Collection). Folder photos only: each member is a `.file` id plus
/// the root folder whose `.photolab/` holds its sidecar — the open
/// `FolderSource`'s folder when it was added — so an edit made in the
/// collection is written to the very file that folder reads
/// (`CollectionSource.sidecars(for:)`). A collection never holds a photo's
/// pixels or its edit, only where they are.
struct PhotoCollection: Codable, Identifiable, Equatable, Sendable {
    /// One photo of a collection: its file (the id `Library.scan` gave it)
    /// and the folder its sidecar store is rooted at.
    struct Member: Codable, Hashable, Sendable {
        var file: URL
        var root: URL

        var id: PhotoID { .file(file) }
    }

    static let currentVersion = 1

    var version = PhotoCollection.currentVersion
    let id: UUID
    var name: String
    let created: Date
    var members: [Member]

    init(id: UUID = UUID(), name: String, created: Date = Date(), members: [Member] = []) {
        self.id = id
        self.name = name
        self.created = created
        self.members = members
    }

    /// The member for a photo id, if it is one.
    func member(for id: PhotoID) -> Member? {
        guard let file = id.fileURL else { return nil }
        return members.first { $0.file == file }
    }

    /// The collection with `new` appended, each photo once (a member already
    /// there keeps its place and its root). Returns how many were added.
    @discardableResult
    mutating func add(_ new: [Member]) -> Int {
        var seen = Set(members.map(\.file))
        var added = 0
        for m in new where !seen.contains(m.file) {
            members.append(m)
            seen.insert(m.file)
            added += 1
        }
        return added
    }

    /// The collection without the members whose ids are in `ids`. Never
    /// touches a file. Returns how many were removed.
    @discardableResult
    mutating func remove(_ ids: Set<PhotoID>) -> Int {
        let before = members.count
        members.removeAll { ids.contains($0.id) }
        return before - members.count
    }
}

enum CollectionError: LocalizedError, Equatable {
    case emptyName
    case tooNew(Int)

    var errorDescription: String? {
        switch self {
        case .emptyName: return "A collection needs a name."
        case .tooNew(let v): return "This collection was saved by a newer PhotoLab (version \(v))."
        }
    }
}

/// The collections on disk: one `<id>.json` per collection in an injected
/// directory (the app's is `~/Library/Application Support/PhotoLab/Collections/`,
/// `CollectionStore.app`; every test passes a temporary one). Writes are
/// atomic; a file this build cannot decode is listed as unreadable and
/// never overwritten or deleted by a load.
struct CollectionStore: Sendable {
    static let fileExtension = "json"

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The app's store, under Application Support.
    static var app: CollectionStore {
        CollectionStore(directory: AppDirectories.applicationSupport
            .appendingPathComponent("PhotoLab/Collections", isDirectory: true))
    }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(Self.fileExtension)
    }

    /// Writes the collection atomically, creating the directory first.
    func save(_ collection: PhotoCollection) throws {
        let name = collection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CollectionError.emptyName }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(collection).write(to: url(for: collection.id), options: .atomic)
    }

    /// One collection, or nil when its file is missing or cannot be read.
    func load(_ id: UUID) -> PhotoCollection? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? Self.decode(data)
    }

    /// Every collection, by name (case-insensitive), plus the files that
    /// could not be read.
    func loadAll() -> (collections: [PhotoCollection], unreadable: [URL]) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return ([], []) }
        var out: [PhotoCollection] = []
        var bad: [URL] = []
        for file in files where file.pathExtension == Self.fileExtension {
            do {
                out.append(try Self.decode(Data(contentsOf: file)))
            } catch {
                bad.append(file)
            }
        }
        out.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (out, bad)
    }

    /// Deletes the collection's file, and nothing else: no member's photo
    /// or sidecar is touched.
    func remove(_ id: UUID) throws {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    static func decode(_ data: Data) throws -> PhotoCollection {
        let c = try decoder.decode(PhotoCollection.self, from: data)
        if c.version > PhotoCollection.currentVersion { throw CollectionError.tooNew(c.version) }
        return c
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// A collection opened as the library's source. It lists the members whose
/// file exists (`missing` counts the others: never dropped from the
/// collection, never silently), reads thumbnails and originals as
/// `FolderSource` does, and routes each member's edit to
/// `SidecarStore(folder: member.root)` (`sidecars(for:)`,
/// `loadSidecars(for:)`), so the edit is the file that member's folder reads.
struct CollectionSource: PhotoSource {
    let collection: PhotoCollection

    init(_ collection: PhotoCollection) {
        self.collection = collection
    }

    var title: String { collection.name }

    func photos() throws -> [Photo] {
        present.map { Photo(url: $0.file) }
    }

    /// The members whose file exists, in collection order.
    var present: [PhotoCollection.Member] {
        collection.members.filter { FileManager.default.fileExists(atPath: $0.file.path) }
    }

    /// The members whose file is gone (moved, renamed, deleted).
    var missing: [PhotoCollection.Member] {
        collection.members.filter { !FileManager.default.fileExists(atPath: $0.file.path) }
    }

    /// Unused by the library for a collection (every member routes through
    /// `sidecars(for:)`): the first member's root, or the folder of nothing.
    var sidecars: SidecarStore {
        SidecarStore(folder: collection.members.first?.root ?? URL(fileURLWithPath: "/", isDirectory: true))
    }

    /// The member's own root store; a file that is not a member gets its
    /// enclosing folder's.
    func sidecars(for id: PhotoID) -> SidecarStore {
        if let m = collection.member(for: id) { return SidecarStore(folder: m.root) }
        return SidecarStore(folder: (id.fileURL ?? URL(fileURLWithPath: "/")).deletingLastPathComponent())
    }

    /// Each root's store read once for its own members, merged.
    func loadSidecars(for ids: [PhotoID]) -> SidecarStore.Loaded {
        var byRoot: [URL: [PhotoID]] = [:]
        var order: [URL] = []
        for id in ids {
            let root = sidecars(for: id).directory
            if byRoot[root] == nil { order.append(root) }
            byRoot[root, default: []].append(id)
        }
        var out: SidecarStore.Loaded = ([:], [:], [:], [])
        for root in order {
            let group = byRoot[root]!
            let loaded = sidecars(for: group[0]).loadAll(for: group)
            out.recipes.merge(loaded.recipes) { a, _ in a }
            out.marks.merge(loaded.marks) { a, _ in a }
            out.keywords.merge(loaded.keywords) { a, _ in a }
            out.unreadable += loaded.unreadable
        }
        return out
    }

    func thumbnail(for id: PhotoID, maxPixelSize: Int) -> NSImage? {
        ImageLoading.downsampled(id, maxPixelSize: maxPixelSize)
    }

    func originalFile(for id: PhotoID) async throws -> URL {
        guard let url = id.fileURL, collection.member(for: id) != nil else {
            throw PhotoSourceError.notInThisSource(id)
        }
        return url
    }
}

/// What New Collection… asks for: the name, then the photos it starts with.
struct NewCollectionRequest: Identifiable {
    let id = UUID()
    let targets: [Photo.ID]
}

// MARK: Library

extension Library {
    /// The open collection, when the source is one.
    var openCollection: PhotoCollection? { (source as? CollectionSource)?.collection }

    /// Every saved collection, by name (re-read when `collectionsRevision`
    /// changes, so a menu redraws); empty without a store.
    func savedCollections() -> [PhotoCollection] {
        _ = collectionsRevision
        return collectionStore?.loadAll().collections ?? []
    }

    /// Add to Collection is offered over folder photos only: a folder or a
    /// collection is open (a Photos album's assets are a later step).
    var canAddToCollection: Bool {
        collectionStore != nil && (source is FolderSource || source is CollectionSource)
    }

    /// The members `ids` make: each with the open folder as its root, or
    /// its own root when the open source is a collection. Ids not listed,
    /// and any asset, are left out.
    func collectionMembers(for ids: [Photo.ID]) -> [PhotoCollection.Member] {
        let listed = Set(photos.map(\.id))
        return ids.compactMap { id in
            guard listed.contains(id), let file = id.fileURL else { return nil }
            if let folder { return PhotoCollection.Member(file: file, root: folder) }
            if let m = openCollection?.member(for: id) { return m }
            return nil
        }
    }

    /// New Collection…: the name sheet, then `createCollection`.
    func requestNewCollection(for ids: [Photo.ID]) {
        guard canAddToCollection else { return }
        newCollectionRequest = NewCollectionRequest(targets: ids)
    }

    /// Makes a collection named `name` holding `ids` (folder photos of the
    /// open source) and saves it. Nil, with `collectionError` set, when the
    /// name is empty or the write fails.
    @discardableResult
    func createCollection(named name: String, adding ids: [Photo.ID] = []) -> PhotoCollection? {
        guard let collectionStore else { return nil }
        var c = PhotoCollection(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        c.add(collectionMembers(for: ids))
        do {
            try collectionStore.save(c)
        } catch {
            collectionError = error.localizedDescription
            return nil
        }
        collectionError = nil
        collectionsRevision += 1
        return c
    }

    /// Adds the photos to a saved collection (each once). Returns how many
    /// were added.
    @discardableResult
    func addToCollection(_ collectionID: UUID, ids: [Photo.ID]) -> Int {
        guard canAddToCollection, let collectionStore, var c = collectionStore.load(collectionID) else { return 0 }
        let added = c.add(collectionMembers(for: ids))
        guard added > 0 else { return 0 }
        do {
            try collectionStore.save(c)
        } catch {
            collectionError = error.localizedDescription
            return 0
        }
        collectionError = nil
        collectionsRevision += 1
        if openCollection?.id == c.id { replaceCollection(c) }
        return added
    }

    /// Remove from Collection: drops the photos from the open collection and
    /// from the grid. Never touches a file: each photo and its sidecar stay
    /// where they are. Returns how many were removed.
    @discardableResult
    func removeFromCollection(_ ids: [Photo.ID]) -> Int {
        guard let collectionStore, let open = openCollection else { return 0 }
        var c = collectionStore.load(open.id) ?? open
        let removed = c.remove(Set(ids))
        guard removed > 0 else { return 0 }
        do {
            try collectionStore.save(c)
        } catch {
            collectionError = error.localizedDescription
            return 0
        }
        collectionError = nil
        collectionsRevision += 1
        replaceCollection(c)
        return removed
    }

    /// Opens a saved collection by id; refused, like a missing folder, when
    /// its file is gone or unreadable.
    func openCollection(_ id: UUID, title: String? = nil) {
        guard let c = collectionStore?.load(id) else {
            openError = "\(title ?? "That collection") is no longer saved"
            return
        }
        open(collection: c)
    }

    /// Opens a collection as the source and remembers it (last source, Open
    /// Recent) like a folder.
    func open(collection: PhotoCollection) {
        open(CollectionSource(collection))
        guard openError == nil else { return }
        if rememberFolder {
            settings.lastSource = .collection(id: collection.id.uuidString)
            noteRecent(RecentSource(kind: .collection, id: collection.id.uuidString, title: collection.name))
        }
    }

    /// Delete Collection…: the confirm, then `deleteCollection`.
    func requestDeleteCollection(_ collection: PhotoCollection) {
        deleteCollectionRequest = collection
    }

    /// Deletes the collection's file only (no photo, no sidecar), drops its
    /// Open Recent entry, and closes it when it is the open source.
    func deleteCollection(_ id: UUID) {
        guard let collectionStore else { return }
        do {
            try collectionStore.remove(id)
        } catch {
            collectionError = error.localizedDescription
            return
        }
        collectionError = nil
        forgetRecent(RecentSource(kind: .collection, id: id.uuidString, title: "").key)
        if openCollection?.id == id { closeSource() }
        collectionsRevision += 1
    }
}

// MARK: Views

/// Photo › Add to Collection: each saved collection, then New Collection….
struct AddToCollectionMenu: View {
    @Environment(Library.self) private var library
    let context: CommandContext

    var body: some View {
        let collections = library.savedCollections()
        Menu("Add to Collection") {
            ForEach(collections) { c in
                Button(c.name) { library.addToCollection(c.id, ids: context.targets) }
                    .disabled(context.targets.isEmpty || library.openCollection?.id == c.id)
            }
            if !collections.isEmpty { Divider() }
            CommandItems(placement: .collection, context: context)
        }
        .disabled(!library.canAddToCollection)
    }
}

/// File › Open Collection: each saved collection.
struct OpenCollectionMenu: View {
    @Environment(Library.self) private var library

    var body: some View {
        let collections = library.savedCollections()
        Menu("Open Collection") {
            ForEach(collections) { c in
                Button(c.name) { library.open(collection: c) }
            }
        }
        .disabled(collections.isEmpty)
    }
}

/// The Welcome view's Collections list: open one, or delete it from its
/// context menu.
struct CollectionList: View {
    @Environment(Library.self) private var library

    var body: some View {
        let collections = library.savedCollections()
        if !collections.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Collections").font(.headline)
                ForEach(collections) { c in
                    Button {
                        library.open(collection: c)
                    } label: {
                        Label("\(c.name) (\(c.members.count))", systemImage: "rectangle.stack")
                    }
                    .buttonStyle(.link)
                    .contextMenu {
                        Button("Delete Collection…") { library.requestDeleteCollection(c) }
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}

/// New Collection…'s name sheet: Create saves it with the targets.
struct NewCollectionSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let request: NewCollectionRequest
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        guard !trimmed.isEmpty else { return }
        if library.createCollection(named: trimmed, adding: request.targets) != nil { dismiss() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.targets.count == 1 ? "New Collection with 1 Photo"
                 : "New Collection with \(request.targets.count) Photos")
                .font(.headline)
            TextField("Collection name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if let error = library.collectionError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
