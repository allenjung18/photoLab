import Foundation
import AppKit
import Observation
import UniformTypeIdentifiers

struct Photo: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// The library is a folder. Originals are never written to: every edit is a
/// recipe, held in memory for the open folder and persisted as a sidecar
/// (`SidecarStore`) the moment it changes.
@Observable
final class Library {
    var folder: URL?
    var photos: [Photo] = []
    var selection: Photo.ID?
    /// Loupe (single photo) when true, grid otherwise.
    var loupe = false
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

    // MARK: Recipes, undo and sidecars

    func recipe(for id: Photo.ID) -> Recipe { recipes[id] ?? .neutral }

    /// True when the photo has an edit (a non-neutral recipe).
    func isEdited(_ id: Photo.ID) -> Bool { recipes[id] != nil }

    /// Replaces the photo's recipe. Outside a slider drag this is one undo
    /// step and is written to the sidecar at once; inside a drag
    /// (`beginEdit` … `endEdit`) only the in-memory recipe moves and the
    /// drag as a whole becomes the undo step when it ends.
    func setRecipe(_ recipe: Recipe, for id: Photo.ID) {
        let current = self.recipe(for: id)
        guard recipe != current else { return }
        if let openEdit, openEdit.id == id {
            apply(recipe, to: id)
            return
        }
        history[id, default: EditHistory()].push(current)
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

    /// Undoes the last edit of the selected photo.
    func undo() {
        guard let id = selection, var h = history[id], let previous = h.undo.popLast() else { return }
        openEdit = nil
        h.redo.append(recipe(for: id))
        history[id] = h
        apply(previous, to: id)
        persist(id)
    }

    /// Redoes the last undone edit of the selected photo.
    func redo() {
        guard let id = selection, var h = history[id], let next = h.redo.popLast() else { return }
        openEdit = nil
        h.undo.append(recipe(for: id))
        history[id] = h
        apply(next, to: id)
        persist(id)
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
        var undo: [Recipe] = []
        var redo: [Recipe] = []

        mutating func push(_ recipe: Recipe) {
            undo.append(recipe)
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
