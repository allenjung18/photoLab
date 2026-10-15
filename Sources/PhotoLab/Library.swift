import Foundation
import AppKit
import Observation
import UniformTypeIdentifiers

/// What the Sync / Paste Settings sheet shows: a source recipe, where it
/// came from, and the photos it goes onto.
struct SyncRequest: Identifiable {
    let id = UUID()
    let source: Recipe
    let sourceName: String
    let targets: [Photo.ID]
    /// The mask the sheet opens with (the last one used).
    let mask: SyncMask
}

/// Which photos the grid shows: one of Lightroom's default filter-bar
/// choices. A photo outside the filter is hidden from the grid, from
/// `batchTargets`, from Select All and from the loupe arrows.
enum PhotoFilter: Hashable, CaseIterable {
    case all, picks, unflagged, rejected
    /// At least `n` stars (1…5).
    case stars(Int)

    static var allCases: [PhotoFilter] {
        [.all, .picks, .unflagged, .rejected] + (1...Marks.maxRating).map { .stars($0) }
    }

    func admits(_ marks: Marks) -> Bool {
        switch self {
        case .all: return true
        case .picks: return marks.flag == .pick
        case .unflagged: return marks.flag == nil
        case .rejected: return marks.flag == .reject
        case .stars(let n): return marks.rating >= n
        }
    }

    var label: String {
        switch self {
        case .all: return "All"
        case .picks: return "Picks"
        case .unflagged: return "Unflagged"
        case .rejected: return "Rejected"
        case .stars(let n): return "≥ \(n)★"
        }
    }
}

/// The library is one `PhotoSource` (a folder through `FolderSource`, a
/// Photos album through `PhotosSource`). Originals are never written to:
/// every edit is a recipe, held in memory for the open source and
/// persisted as a sidecar (`SidecarStore`, the source's) the moment it
/// changes.
@MainActor
@Observable
final class Library {
    /// The open source; nil shows the Welcome view.
    private(set) var source: (any PhotoSource)?
    /// The open folder when the source is one (`FolderSource`); nil for any
    /// other source and when nothing is open.
    var folder: URL? { (source as? FolderSource)?.folder }
    var photos: [Photo] = []
    /// The grid's filter. Changing it drops hidden photos from the selection
    /// and moves a hidden anchor to the nearest visible photo.
    var filter: PhotoFilter = .all {
        didSet { if filter != oldValue { reconcileSelection() } }
    }
    /// The anchor of the selection: the photo the loupe shows, the one a
    /// shift-click extends from, the source of Sync Settings. Setting it
    /// collapses a multi-selection to that one photo; `click` is the path
    /// that grows the selection.
    var selection: Photo.ID? {
        didSet { if selection != oldValue { selectedIDs = selection.map { [$0] } ?? [] } }
    }
    /// Every selected photo (the grid's multi-selection), anchor included.
    private(set) var selectedIDs: Set<Photo.ID> = []
    /// Loupe (single photo) when true, grid otherwise.
    var loupe = false
    /// Copy Settings: the recipe and the name of the photo it came from.
    private(set) var copiedSettings: (recipe: Recipe, name: String)?
    /// A Sync / Paste Settings sheet the window should show.
    var syncRequest: SyncRequest?
    /// The mask of the last sync, so the next sheet opens the same way.
    var lastSyncMask = SyncMask.look
    /// Edits per photo for the open folder, mirrored to sidecars.
    private(set) var recipes: [Photo.ID: Recipe] = [:]
    /// Flags and ratings per photo (only the non-empty ones), mirrored to the
    /// same sidecars beside the recipe; never an undo step.
    private(set) var marks: [Photo.ID: Marks] = [:]
    /// Before/after: true shows the unadjusted photo in the loupe.
    var showBefore = false
    /// Clipping warning: true paints the loupe's blown pixels red and its
    /// crushed pixels blue (J, or a histogram triangle).
    var showClipping = false
    /// The last sidecar write or read that failed, for the panel to show.
    private(set) var sidecarError: String?
    /// Why the last `open` was refused (a missing path, an album before
    /// Photos access); nil after one succeeds.
    private(set) var openError: String?
    /// The Open Photos Library sheet the window should show.
    var photosSheet = false
    /// Photos whose sidecar exists but could not be decoded; their edits show
    /// as neutral and their sidecars are left alone until the user edits.
    private(set) var unreadableSidecars: Set<Photo.ID> = []

    private var store: SidecarStore?
    private var history: [Photo.ID: EditHistory] = [:]
    /// A slider drag in progress: one undo step from mouse-down to mouse-up.
    private var openEdit: (id: Photo.ID, before: Recipe)?
    private let rememberFolder: Bool
    private let defaults: UserDefaults

    /// The last source, by kind: `lastSourceKind` is `folder` (the path in
    /// `lastFolder`, the key every earlier build wrote) or `photos` (the
    /// album's identifier in `lastPhotosAlbum`).
    private static let lastFolderKey = "lastFolder"
    private static let lastSourceKindKey = "lastSourceKind"
    private static let lastAlbumKey = "lastPhotosAlbum"
    nonisolated static let maxUndoDepth = 100


    /// `rememberFolder: false` keeps the source out of UserDefaults (tests);
    /// `defaults` is where it is remembered when it is.
    init(rememberFolder: Bool = true, defaults: UserDefaults = .standard) {
        self.rememberFolder = rememberFolder
        self.defaults = defaults
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of photos"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Opens a folder; given a file, opens its folder with that photo in the loupe.
    /// Every sidecar in the folder is read here, so a photo opens with its edit.
    /// A path that does not exist is refused: the current folder (or none)
    /// stays, and `openError` says why, so a mistyped argument never opens
    /// its parent or the working directory.
    func open(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            openError = "No such file or folder: \(url.path)"
            return
        }
        let dir = isDir.boolValue ? url : url.deletingLastPathComponent()
        open(FolderSource(dir))
        guard openError == nil else { return }
        if rememberFolder {
            defaults.set(dir.path, forKey: Self.lastFolderKey)
            defaults.set("folder", forKey: Self.lastSourceKindKey)
        }
        if !isDir.boolValue, let hit = photos.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            selection = hit.id
            loupe = true
        }
    }

    /// Asks the window for the Open Photos Library sheet (albums, or the
    /// Allow button when access was never asked for).
    func choosePhotosAlbum() {
        photosSheet = true
    }

    /// Opens a Photos album through `PhotosSource` and remembers it as the
    /// last source. Refused like any source whose listing fails (before
    /// access is allowed, `photos()` throws `PhotosError.notAuthorized`).
    func open(album: PhotosAlbum, access: PhotosAccess = .live) {
        open(access.source(for: album))
        guard openError == nil else { return }
        if rememberFolder {
            defaults.set(album.id, forKey: Self.lastAlbumKey)
            defaults.set("photos", forKey: Self.lastSourceKindKey)
        }
    }

    /// Opens a source: its photos are listed and every sidecar of theirs
    /// read before the first frame, so a photo opens with its edit; the
    /// selection, the open drag and the undo history are reset. A source
    /// whose listing fails is refused the same way as a missing path: the
    /// current source stays and `openError` says why. The shared thumbnail
    /// cache decodes `.asset` ids through the open source from here on.
    func open(_ source: any PhotoSource) {
        let listed: [Photo]
        do {
            listed = try source.photos()
        } catch {
            openError = error.localizedDescription
            return
        }
        openError = nil
        self.source = source
        Thumbnails.shared.source = source
        selection = nil
        loupe = false
        showBefore = false
        openEdit = nil
        history = [:]
        sidecarError = nil
        filter = .all
        photos = listed
        let store = source.sidecars
        self.store = store
        let loaded = store.loadAll(for: photos.map(\.id))
        recipes = loaded.recipes
        marks = loaded.marks
        unreadableSidecars = Set(loaded.unreadable)
        if let first = loaded.unreadable.first {
            sidecarError = "Could not read the edit saved for \(name(for: first))"
        }
    }

    /// The photo's display name as its source gave it (the file name for a
    /// folder); the id's own name for a photo not in the listing.
    func name(for id: Photo.ID) -> String {
        photos.first { $0.id == id }?.name ?? id.defaultName
    }

    /// The file holding the photo's original pixels, from the open source
    /// (a folder photo's own file; an asset's may have to be fetched).
    func originalFile(for id: Photo.ID) async throws -> URL {
        guard let source else { throw PhotoSourceError.notInThisSource(id) }
        return try await source.originalFile(for: id)
    }

    /// Reopens the last source at launch: the folder if it still exists,
    /// or the album if Photos access is already allowed (never a prompt at
    /// launch) and the album is still there. Otherwise the Welcome view.
    func restoreLastSource(access: PhotosAccess = .live) {
        guard source == nil else { return }
        if defaults.string(forKey: Self.lastSourceKindKey) == "photos" {
            guard let id = defaults.string(forKey: Self.lastAlbumKey),
                  access.client.authorizationStatus().canRead,
                  let album = access.client.albums().first(where: { $0.id == id }) else { return }
            open(album: album, access: access)
            return
        }
        guard let path = defaults.string(forKey: Self.lastFolderKey),
              FileManager.default.fileExists(atPath: path) else { return }
        open(URL(fileURLWithPath: path))
    }

    /// The photos the filter admits, in folder order: what the grid shows and
    /// what every selection path walks. Under `.all` it is `photos`.
    var visiblePhotos: [Photo] {
        if filter == .all { return photos }
        return photos.filter { filter.admits(marks(for: $0.id)) }
    }

    func isVisible(_ id: Photo.ID) -> Bool { filter.admits(marks(for: id)) }

    var selectedIndex: Int? {
        guard let selection else { return nil }
        return photos.firstIndex { $0.id == selection }
    }

    /// The anchor's position among the visible photos (the loupe's "n of N").
    var visibleIndex: Int? {
        guard let selection else { return nil }
        return visiblePhotos.firstIndex { $0.id == selection }
    }

    var selectedPhoto: Photo? {
        selectedIndex.map { photos[$0] }
    }

    /// Moves the anchor by `offset` along the visible photos (the arrows and
    /// the loupe walk the filtered list, never a hidden photo).
    func select(offset: Int) {
        let visible = visiblePhotos
        guard !visible.isEmpty else { return }
        let i = visibleIndex ?? 0
        let j = min(max(i + offset, 0), visible.count - 1)
        selection = visible[j].id
    }

    // MARK: Multi-selection

    /// A click in the grid. Plain: that photo alone. `toggling` (⌘): add or
    /// remove it, the anchor moving to it when added. `extending` (⇧): every
    /// visible photo between the anchor and it, the anchor kept. A click on a
    /// photo the filter hides is ignored.
    func click(_ id: Photo.ID, extending: Bool = false, toggling: Bool = false) {
        let visible = visiblePhotos
        guard let i = visible.firstIndex(where: { $0.id == id }) else { return }
        if extending, let a = visible.firstIndex(where: { $0.id == selection }) {
            let range = min(a, i)...max(a, i)
            selectedIDs = Set(visible[range].map(\.id))
        } else if toggling {
            if selectedIDs.contains(id) {
                var rest = selectedIDs
                rest.remove(id)
                // Setting the anchor collapses the set, so move it first.
                if selection == id { selection = photos.first { rest.contains($0.id) }?.id }
                selectedIDs = rest
            } else {
                let keep = selectedIDs
                selection = id
                selectedIDs = keep.union([id])
            }
        } else {
            selection = id
            selectedIDs = [id]
        }
    }

    /// Every visible photo, the anchor kept (or the first visible photo).
    func selectAll() {
        let visible = visiblePhotos
        guard !visible.isEmpty else { return }
        if let anchor = selection, isVisible(anchor) {} else { selection = visible.first?.id }
        selectedIDs = Set(visible.map(\.id))
    }

    /// Back to the anchor alone.
    func collapseSelection() {
        selectedIDs = selection.map { [$0] } ?? []
    }

    /// The photos a batch action targets, in folder order: the multi-selection
    /// when there is one, else the anchor. A photo the filter hides is never a
    /// target, whatever the selection set holds.
    var batchTargets: [Photo.ID] {
        let ids = visiblePhotos.map(\.id).filter { selectedIDs.contains($0) }
        if ids.isEmpty, let selection, isVisible(selection) { return [selection] }
        return ids
    }

    /// After the filter or a mark changed: hidden photos leave the selection,
    /// and a hidden anchor moves to the nearest visible photo after it in
    /// folder order (culling flow: reject under Picks shows the next one),
    /// else the nearest before, else none.
    private func reconcileSelection() {
        let kept = selectedIDs.filter(isVisible)
        if let anchor = selection, !isVisible(anchor) {
            let visible = photos.indices.filter { isVisible(photos[$0].id) }
            let pos = selectedIndex ?? 0
            let next = visible.first { $0 > pos } ?? visible.last { $0 < pos }
            selection = next.map { photos[$0].id }  // collapses selectedIDs
            if selection == nil { loupe = false }
        }
        if let anchor = selection { selectedIDs = kept.union([anchor]) } else { selectedIDs = [] }
    }

    // MARK: Flags and ratings

    func marks(for id: Photo.ID) -> Marks { marks[id] ?? .none }
    func flag(for id: Photo.ID) -> Marks.Flag? { marks(for: id).flag }
    func rating(for id: Photo.ID) -> Int { marks(for: id).rating }

    /// Flags every photo in `ids` (P pick, X reject, U none). Written to the
    /// sidecar at once; not an undo step, and the recipe is untouched.
    func setFlag(_ flag: Marks.Flag?, for ids: [Photo.ID]) {
        for id in ids {
            var m = marks(for: id)
            guard m.flag != flag else { continue }
            m.flag = flag
            setMarks(m, for: id)
        }
        reconcileSelection()
    }

    /// Rates every photo in `ids` 0–5 (0 clears). Same rules as `setFlag`.
    func setRating(_ rating: Int, for ids: [Photo.ID]) {
        let rating = min(max(rating, 0), Marks.maxRating)
        for id in ids {
            var m = marks(for: id)
            guard m.rating != rating else { continue }
            m.rating = rating
            setMarks(m, for: id)
        }
        reconcileSelection()
    }

    private func setMarks(_ m: Marks, for id: Photo.ID) {
        if m.isEmpty { marks.removeValue(forKey: id) } else { marks[id] = m }
        persist(id)
    }

    // MARK: Recipes, undo and sidecars

    func recipe(for id: Photo.ID) -> Recipe { recipes[id] ?? .neutral }

    /// True when the photo has an edit: a recipe other than the default
    /// (`apply` keeps every non-default recipe, a disabled-only one included).
    func isEdited(_ id: Photo.ID) -> Bool { recipes[id] != nil }

    /// Replaces the photo's recipe. Outside a slider drag this is one undo
    /// step and is written to the sidecar at once; inside a drag
    /// (`beginEdit` … `endEdit`) only the in-memory recipe moves and the
    /// drag as a whole becomes the undo step when it ends.
    func setRecipe(_ recipe: Recipe, for id: Photo.ID) {
        setRecipe(recipe, for: id, batch: nil)
    }

    /// `setRecipe` with the step tagged as part of `batch`: steps that share
    /// a tag undo and redo together (see `undo`).
    private func setRecipe(_ recipe: Recipe, for id: Photo.ID, batch: UUID?) {
        let current = self.recipe(for: id)
        guard recipe != current else { return }
        if let openEdit, openEdit.id == id {
            apply(recipe, to: id)
            return
        }
        history[id, default: EditHistory()].push(current, batch: batch)
        apply(recipe, to: id)
        persist(id)
    }

    /// Everything back to neutral: one undo step, and the sidecar is removed.
    func resetRecipe(for id: Photo.ID) { setRecipe(.neutral, for: id) }

    /// Applies a preset to one photo: its look over the photo's own rotation
    /// and crop, through `setRecipe` (one undo step, the sidecar written).
    func apply(_ preset: Preset, to id: Photo.ID) {
        setRecipe(preset.apply(to: recipe(for: id)), for: id)
    }

    // MARK: Batch

    /// Copies the kinds in `mask` from `source` onto every photo in `ids`,
    /// each through `setRecipe` (its own sidecar, written at once). The
    /// whole batch is ONE undo step: ⌘Z on any photo of it takes them all
    /// back. A photo the sync would not change is skipped. Returns how many
    /// photos changed.
    @discardableResult
    func sync(_ source: Recipe, mask: SyncMask, to ids: [Photo.ID]) -> Int {
        let batch = UUID()
        var changed = 0
        for id in ids {
            let current = recipe(for: id)
            let next = current.syncing(mask, from: source)
            guard next != current.normalized else { continue }
            setRecipe(next, for: id, batch: batch)
            changed += 1
        }
        return changed
    }

    /// Applies a preset to many photos as one batch: the preset's look (the
    /// kinds in `mask`, never geometry, which a preset does not carry) over
    /// each photo's own values.
    @discardableResult
    func apply(_ preset: Preset, mask: SyncMask = .look, to ids: [Photo.ID]) -> Int {
        let kinds = mask.kinds.subtracting(AdjustmentKind.geometryKinds)
        return sync(preset.recipe, mask: SyncMask(kinds: kinds), to: ids)
    }

    /// Copy Settings: remembers the photo's recipe for Paste Settings.
    func copySettings(from id: Photo.ID) {
        copiedSettings = (recipe(for: id), name(for: id))
    }

    /// Asks the window for the Sync Settings sheet: the anchor's recipe onto
    /// the other selected photos.
    func requestSync() {
        guard let anchor = selection else { return }
        let targets = batchTargets.filter { $0 != anchor }
        guard !targets.isEmpty else { return }
        syncRequest = SyncRequest(source: recipe(for: anchor), sourceName: name(for: anchor),
                                  targets: targets, mask: lastSyncMask)
    }

    /// Asks the window for the Paste Settings sheet: the copied recipe onto
    /// the selection.
    func requestPaste() {
        guard let copied = copiedSettings, !batchTargets.isEmpty else { return }
        syncRequest = SyncRequest(source: copied.recipe, sourceName: copied.name,
                                  targets: batchTargets, mask: lastSyncMask)
    }

    /// The (file, recipe) pairs an export of `ids` writes, each file the
    /// source's original (`originalFile(for:)`). The recipes are snapshotted
    /// here, when the export sheet opens (`ExportQueue.requestExport` is
    /// called with the result): an edit made while the sheet is up or while
    /// the queue runs does not change what is written for a photo already in it.
    func exportItems(for ids: [Photo.ID]) async throws -> [ExportQueue.Item] {
        var items: [ExportQueue.Item] = []
        for id in ids {
            items.append(ExportQueue.Item(source: try await originalFile(for: id), recipe: recipe(for: id)))
        }
        return items
    }

    /// Marks the start of a continuous edit (a slider drag) on `id`. At most
    /// one edit is open at a time: beginning one on another photo ends the
    /// open one first (its drag persisted and made an undo step), so no
    /// photo is ever left on the mid-drag path with its writes unsaved.
    func beginEdit(_ id: Photo.ID) {
        if let openEdit, openEdit.id == id { return }
        closeOpenEdit()
        openEdit = (id, recipe(for: id))
    }

    /// Ends the continuous edit: if the recipe moved, the value at
    /// `beginEdit` becomes the undo step and the result is written. The `id`
    /// is the caller's photo at mouse-up; whatever edit is open is the one
    /// closed, so a loupe photo changing mid-drag cannot strand the edit.
    func endEdit(_ id: Photo.ID) {
        closeOpenEdit()
    }

    private func closeOpenEdit() {
        guard let edit = openEdit else { return }
        openEdit = nil
        let now = recipe(for: edit.id)
        guard now != edit.before else { return }
        history[edit.id, default: EditHistory()].push(edit.before)
        persist(edit.id)
    }

    var canUndo: Bool { selection.map { history[$0]?.undo.isEmpty == false } ?? false }
    var canRedo: Bool { selection.map { history[$0]?.redo.isEmpty == false } ?? false }

    /// Undoes the last edit of the selected photo. When that edit was part of
    /// a batch, every photo whose latest edit is the same batch goes back
    /// with it (a photo edited again since keeps its later edit).
    func undo() {
        guard let id = selection, let top = history[id]?.undo.last else { return }
        openEdit = nil
        for pid in members(of: top.batch, anchor: id, top: { $0.undo.last }) {
            guard var h = history[pid], let step = h.undo.popLast() else { continue }
            h.redo.append(EditHistory.Step(recipe: recipe(for: pid), batch: step.batch))
            history[pid] = h
            apply(step.recipe, to: pid)
            persist(pid)
        }
    }

    /// Redoes the last undone edit of the selected photo, and of every other
    /// photo whose latest undone edit is the same batch.
    func redo() {
        guard let id = selection, let top = history[id]?.redo.last else { return }
        openEdit = nil
        for pid in members(of: top.batch, anchor: id, top: { $0.redo.last }) {
            guard var h = history[pid], let step = h.redo.popLast() else { continue }
            h.undo.append(EditHistory.Step(recipe: recipe(for: pid), batch: step.batch))
            history[pid] = h
            apply(step.recipe, to: pid)
            persist(pid)
        }
    }

    /// The photos a step acts on: the anchor alone for a single edit, else
    /// every photo whose `top` step carries the same batch tag.
    private func members(of batch: UUID?, anchor: Photo.ID,
                         top: (EditHistory) -> EditHistory.Step?) -> [Photo.ID] {
        guard let batch else { return [anchor] }
        return photos.map(\.id).filter { history[$0].flatMap(top)?.batch == batch }
    }

    /// Only the default recipe is dropped from memory; a recipe that renders
    /// as identity because an entry is disabled keeps its values.
    private func apply(_ recipe: Recipe, to id: Photo.ID) {
        if recipe.isDefault { recipes.removeValue(forKey: id) } else { recipes[id] = recipe }
    }

    /// Writes the photo's sidecar: recipe and marks together, so a reset
    /// keeps the flag and a flag keeps a default recipe's file.
    private func persist(_ id: Photo.ID) {
        guard let store else { return }
        do {
            try store.save(recipe(for: id), marks: marks(for: id), for: id, name: name(for: id))
            unreadableSidecars.remove(id)
            sidecarError = nil
        } catch {
            sidecarError = "Could not save the edit for \(name(for: id)): \(error.localizedDescription)"
        }
    }

    /// Per-photo undo and redo stacks of whole recipes (a recipe is a few
    /// hundred bytes, so whole snapshots are simpler than deltas).
    private struct EditHistory {
        /// One step: the recipe to go back to, and the batch it belongs to
        /// (nil for a single edit).
        struct Step {
            var recipe: Recipe
            var batch: UUID?
        }

        var undo: [Step] = []
        var redo: [Step] = []

        mutating func push(_ recipe: Recipe, batch: UUID? = nil) {
            undo.append(Step(recipe: recipe, batch: batch))
            if undo.count > Library.maxUndoDepth { undo.removeFirst(undo.count - Library.maxUndoDepth) }
            redo.removeAll()
        }
    }

    /// Every regular file under `folder` whose type conforms to `public.image`:
    /// JPEG, HEIC, PNG, TIFF and every RAW format ImageIO knows. Hidden
    /// entries are skipped, which keeps `.photolab/` out of the grid.
    nonisolated static func scan(_ folder: URL) -> [Photo] {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.isRegularFile == true,
                  let type = v.contentType, type.conforms(to: .image) else { continue }
            out.append(url)
        }
        return out.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }.map(Photo.init(url:))
    }
}
