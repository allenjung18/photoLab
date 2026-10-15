import Foundation
import AppKit
import Observation
import UniformTypeIdentifiers

struct Photo: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

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

/// The library is a folder. Originals are never written to: every edit is a
/// recipe, held in memory for the open folder and persisted as a sidecar
/// (`SidecarStore`) the moment it changes.
@Observable
final class Library {
    var folder: URL?
    var photos: [Photo] = []
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
    /// Before/after: true shows the unadjusted photo in the loupe.
    var showBefore = false
    /// The last sidecar write or read that failed, for the panel to show.
    private(set) var sidecarError: String?
    /// Photos whose sidecar exists but could not be decoded; their edits show
    /// as neutral and their sidecars are left alone until the user edits.
    private(set) var unreadableSidecars: Set<Photo.ID> = []

    private var store: SidecarStore?
    private var history: [Photo.ID: EditHistory] = [:]
    /// A slider drag in progress: one undo step from mouse-down to mouse-up.
    private var openEdit: (id: Photo.ID, before: Recipe)?
    private let rememberFolder: Bool

    private static let lastFolderKey = "lastFolder"
    static let maxUndoDepth = 100

    /// `rememberFolder: false` keeps the folder out of UserDefaults (tests).
    init(rememberFolder: Bool = true) {
        self.rememberFolder = rememberFolder
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
    func open(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let dir = isDir.boolValue ? url : url.deletingLastPathComponent()
        folder = dir
        selection = nil
        loupe = false
        showBefore = false
        openEdit = nil
        history = [:]
        sidecarError = nil
        photos = Self.scan(dir)
        let store = SidecarStore(folder: dir)
        self.store = store
        let loaded = store.loadAll(for: photos.map(\.url))
        recipes = loaded.recipes
        unreadableSidecars = Set(loaded.unreadable)
        if let first = loaded.unreadable.first {
            sidecarError = "Could not read the edit saved for \(first.lastPathComponent)"
        }
        if rememberFolder { UserDefaults.standard.set(dir.path, forKey: Self.lastFolderKey) }
        if !isDir.boolValue, let hit = photos.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            selection = hit.id
            loupe = true
        }
    }

    func restoreLastFolder() {
        guard folder == nil,
              let path = UserDefaults.standard.string(forKey: Self.lastFolderKey),
              FileManager.default.fileExists(atPath: path) else { return }
        open(URL(fileURLWithPath: path))
    }

    var selectedIndex: Int? {
        guard let selection else { return nil }
        return photos.firstIndex { $0.id == selection }
    }

    var selectedPhoto: Photo? {
        selectedIndex.map { photos[$0] }
    }

    func select(offset: Int) {
        guard !photos.isEmpty else { return }
        let i = selectedIndex ?? 0
        let j = min(max(i + offset, 0), photos.count - 1)
        selection = photos[j].id
    }

    // MARK: Multi-selection

    /// A click in the grid. Plain: that photo alone. `toggling` (⌘): add or
    /// remove it, the anchor moving to it when added. `extending` (⇧): every
    /// photo between the anchor and it, the anchor kept.
    func click(_ id: Photo.ID, extending: Bool = false, toggling: Bool = false) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        if extending, let a = selectedIndex {
            let range = min(a, i)...max(a, i)
            selectedIDs = Set(photos[range].map(\.id))
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

    /// Every photo of the folder, the anchor kept (or the first photo).
    func selectAll() {
        guard !photos.isEmpty else { return }
        if selection == nil { selection = photos.first?.id }
        selectedIDs = Set(photos.map(\.id))
    }

    /// Back to the anchor alone.
    func collapseSelection() {
        selectedIDs = selection.map { [$0] } ?? []
    }

    /// The photos a batch action targets, in folder order: the multi-selection
    /// when there is one, else the anchor.
    var batchTargets: [Photo.ID] {
        let ids = photos.map(\.id).filter { selectedIDs.contains($0) }
        if ids.isEmpty, let selection { return [selection] }
        return ids
    }

    // MARK: Recipes, undo and sidecars

    func recipe(for id: Photo.ID) -> Recipe { recipes[id] ?? .neutral }

    /// True when the photo has an edit (a non-neutral recipe).
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
        copiedSettings = (recipe(for: id), id.lastPathComponent)
    }

    /// Asks the window for the Sync Settings sheet: the anchor's recipe onto
    /// the other selected photos.
    func requestSync() {
        guard let anchor = selection else { return }
        let targets = batchTargets.filter { $0 != anchor }
        guard !targets.isEmpty else { return }
        syncRequest = SyncRequest(source: recipe(for: anchor), sourceName: anchor.lastPathComponent,
                                  targets: targets, mask: lastSyncMask)
    }

    /// Asks the window for the Paste Settings sheet: the copied recipe onto
    /// the selection.
    func requestPaste() {
        guard let copied = copiedSettings, !batchTargets.isEmpty else { return }
        syncRequest = SyncRequest(source: copied.recipe, sourceName: copied.name,
                                  targets: batchTargets, mask: lastSyncMask)
    }

    /// The (photo, recipe) pairs an export of `ids` writes.
    func exportItems(for ids: [Photo.ID]) -> [ExportQueue.Item] {
        ids.map { ExportQueue.Item(source: $0, recipe: recipe(for: $0)) }
    }

    /// Marks the start of a continuous edit (a slider drag) on `id`.
    func beginEdit(_ id: Photo.ID) {
        guard openEdit == nil else { return }
        openEdit = (id, recipe(for: id))
    }

    /// Ends the continuous edit on `id`: if the recipe moved, the value at
    /// `beginEdit` becomes the undo step and the result is written.
    func endEdit(_ id: Photo.ID) {
        guard let edit = openEdit, edit.id == id else { return }
        openEdit = nil
        let now = recipe(for: id)
        guard now != edit.before else { return }
        history[id, default: EditHistory()].push(edit.before)
        persist(id)
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

    private func apply(_ recipe: Recipe, to id: Photo.ID) {
        if recipe.isNeutral { recipes.removeValue(forKey: id) } else { recipes[id] = recipe }
    }

    private func persist(_ id: Photo.ID) {
        guard let store else { return }
        do {
            try store.save(recipe(for: id), for: id)
            unreadableSidecars.remove(id)
            sidecarError = nil
        } catch {
            sidecarError = "Could not save the edit for \(id.lastPathComponent): \(error.localizedDescription)"
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
    static func scan(_ folder: URL) -> [Photo] {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [Photo] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.isRegularFile == true,
                  let type = v.contentType, type.conforms(to: .image) else { continue }
            out.append(Photo(url: url))
        }
        return out.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }
}
