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

/// Where the last Save to Photos stands, per photo.
enum PhotosSaveState: Equatable {
    case idle
    case saving(Photo.ID)
    case saved(Photo.ID)
    case failed(Photo.ID, String)
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
        didSet {
            if filter != oldValue { reconcileSelection() }
            saveViewState()
        }
    }
    /// The grid's order (`PhotoSort`): `photos` is kept sorted by it, so the
    /// grid, the filmstrip and the arrows follow it. Remembered per source
    /// kind (`storedSort(for:)`, in `settings`); a change re-sorts at once
    /// and leaves the selection and the anchor where they are.
    var sort: PhotoSort = .folderDefault {
        didSet {
            guard sort != oldValue, !restoringViewState else { return }
            resort()
            if rememberFolder, source != nil {
                settings.setSort(sort, for: sortKind)
            }
        }
    }
    /// Capture dates read for the `.captureDate` sort, once per photo.
    let captureDates: CaptureDates
    /// Bumped by every `open`: a name read for an earlier source is dropped.
    @ObservationIgnored private var openGeneration = 0
    /// The running `nameEveryPhoto` pass, if any.
    @ObservationIgnored private(set) var namingAll: Task<Void, Never>?
    /// The Info section's header reads, once per photo (`PhotoInfoStore`).
    let photoInfo: PhotoInfoStore
    /// The anchor of the selection: the photo the loupe shows, the one a
    /// shift-click extends from, the source of Sync Settings. Setting it
    /// collapses a multi-selection to that one photo; `click` is the path
    /// that grows the selection.
    var selection: Photo.ID? {
        didSet {
            if selection != oldValue {
                selectedIDs = selection.map { [$0] } ?? []
                loupeZoom = .fit
                cropDragStart = nil
            }
            saveViewState()
        }
    }
    /// Every selected photo (the grid's multi-selection), anchor included.
    private(set) var selectedIDs: Set<Photo.ID> = []
    /// Loupe (single photo) when true, grid otherwise.
    var loupe = false {
        didSet {
            if !loupe { loupeZoom = .fit; cropMode = false }
            saveViewState()
        }
    }
    /// The loupe's zoom: fit, or 1:1 around a centre (Z, a click on the
    /// photo, a drag to pan). Back to fit whenever the photo changes (the
    /// arrows, a filmstrip click, any new anchor) and when the loupe closes;
    /// never remembered.
    var loupeZoom: PreviewZoom = .fit
    /// Crop mode (R, Photo › Crop, the Crop & Rotate section's button): the
    /// loupe shows the rotated, uncropped frame with the crop rectangle and
    /// its eight handles over it (`CropMath`). Entering returns the zoom to
    /// fit and ends compare; Esc, R, Z, compare and leaving the loupe end it.
    /// Kept across photo changes, like the loupe's other modes; never
    /// remembered.
    var cropMode = false {
        didSet {
            guard cropMode != oldValue else { return }
            if cropMode {
                loupeZoom = .fit
                compare = false
            } else {
                cropDragStart = nil
                straightening = false
            }
        }
    }
    /// The crop's aspect lock (the Crop & Rotate section's Aspect picker and
    /// swap): Free, or a ratio a corner drag holds. Tool state like the
    /// zoom: kept across photos, never in a recipe, never remembered.
    /// Changed through `setCropAspect` / `swapCropAspect`, which refit.
    private(set) var cropAspect = CropMath.Aspect.free
    /// The straighten tool is armed (the section's Straighten button): the
    /// next drag on the photo draws a line, and its mouse-up sets rotate so
    /// the line is level (`straighten`). Arming it enters crop mode; leaving
    /// crop mode, Esc, or the line itself disarms it.
    var straightening = false {
        didSet { if straightening, !cropMode { cropMode = true } }
    }
    /// The crop a handle drag started from, while one is in progress.
    private var cropDragStart: CropMath.Crop?
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
    /// Before / After side by side in the loupe (Y, or the toolbar toggle):
    /// the canvas splits into the neutral render and the recipe's.
    var compare = false {
        didSet { if compare { cropMode = false } }
    }
    /// Clipping warning: true paints the loupe's blown pixels red and its
    /// crushed pixels blue (J, or a histogram triangle).
    var showClipping = false
    /// The loupe's filmstrip (View menu, F): `AppSettings.showFilmstrip`,
    /// remembered and kept across sources.
    var showFilmstrip: Bool {
        get { settings.showFilmstrip }
        set { if newValue != settings.showFilmstrip { settings.showFilmstrip = newValue } }
    }
    /// The loupe panel's Info section open (View › Info, ⌘I):
    /// `AppSettings.showInfo`, remembered like the filmstrip.
    var showInfo: Bool {
        get { settings.showInfo }
        set { if newValue != settings.showInfo { settings.showInfo = newValue } }
    }
    /// The last sidecar write or read that failed, for the panel to show.
    private(set) var sidecarError: String?
    /// Why the last `open` was refused (a missing path, an album before
    /// Photos access); nil after one succeeds.
    var openError: String?
    /// The Open Photos Library sheet the window should show.
    var photosSheet = false
    /// Photos whose sidecar exists but could not be decoded, or whose Photos
    /// adjustment data is PhotoLab's at a version this build does not read;
    /// their edits show as neutral and their sidecars are left alone until
    /// the user edits.
    private(set) var unreadableSidecars: Set<Photo.ID> = []
    /// The last Save to Photos: running, done, or why it failed.
    private(set) var photosSave = PhotosSaveState.idle
    /// True while `autoTone` reads its photos (Auto is disabled meanwhile).
    private(set) var autoToning = false

    private var store: SidecarStore?
    private var history: [Photo.ID: EditHistory] = [:]
    /// A slider drag in progress: one undo step from mouse-down to mouse-up.
    private var openEdit: (id: Photo.ID, before: Recipe)?
    /// Everything kept between launches (`AppSettings`): the Settings
    /// window's choices, the view toggles, the sort per kind, the last
    /// source and Open Recent.
    let settings: AppSettings
    /// False keeps the source and every choice out of UserDefaults (tests).
    var rememberFolder: Bool { settings.persistent }
    /// Bumped whenever the recent list changes, so a menu reading it redraws.
    var recentsRevision = 0
    /// True while `open` resets and restores the view state: those writes are
    /// not the user's and must not overwrite the source's remembered state.
    var restoringViewState = false

    nonisolated static let maxUndoDepth = 100


    /// `settings` is what the library remembers into (the app's one
    /// `AppSettings`); without it, one over `defaults` is made, and
    /// `rememberFolder: false` makes it read and write nothing (tests).
    init(rememberFolder: Bool = true, defaults: UserDefaults = .standard,
         settings: AppSettings? = nil,
         captureDates: CaptureDates = CaptureDates()) {
        self.settings = settings ?? AppSettings(defaults: defaults, persistent: rememberFolder)
        self.captureDates = captureDates
        self.photoInfo = PhotoInfoStore(captureDates: captureDates)
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
            settings.lastSource = .folder(path: dir.path)
            noteRecent(RecentSource(kind: .folder, id: dir.path, title: dir.lastPathComponent))
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
            settings.lastSource = .photos(albumID: album.id)
            noteRecent(RecentSource(kind: .photos, id: album.id, title: album.title))
        }
    }

    /// Opens a source: its photos are listed and every sidecar of theirs
    /// read before the first frame, so a photo opens with its edit; the
    /// selection, the open drag and the undo history are reset. A source
    /// whose listing fails is refused the same way as a missing path: the
    /// current source stays and `openError` says why. The shared thumbnail
    /// cache decodes `.asset` ids through the open source from here on. A
    /// pending Sync / Paste sheet is dropped: its targets were the old
    /// source's photos.
    func open(_ source: any PhotoSource) {
        let listed: [Photo]
        do {
            listed = try source.photos()
        } catch {
            openError = error.localizedDescription
            return
        }
        openError = nil
        restoringViewState = true
        defer { restoringViewState = false }
        openGeneration += 1
        namingAll?.cancel()
        namingAll = nil
        self.source = source
        Thumbnails.shared.source = source
        selection = nil
        loupe = false
        showBefore = false
        compare = false
        openEdit = nil
        syncRequest = nil
        history = [:]
        sidecarError = nil
        photosSave = .idle
        filter = .all
        sort = storedSort(for: sortKind)
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
        resort()
        restoreViewState()
    }

    /// The photo's display name as its source gave it (the file name for a
    /// folder); the id's own name for a photo not in the listing or not
    /// named yet (`resolveName(_:)`).
    func name(for id: Photo.ID) -> String {
        photos.first { $0.id == id }?.name ?? id.defaultName
    }

    /// Names one photo the listing left unnamed (a Photos asset): the
    /// source's `name(for:)` runs off the main thread and the name is
    /// written into `photos`. Asked by each visible grid and filmstrip
    /// cell from its `.task`, which SwiftUI cancels when the cell scrolls
    /// away: the cancellation reaches the read, and a read that finishes
    /// for a cancelled cell (or for a source opened since) writes nothing.
    /// A named photo, or one not listed, asks nothing. Also awaited before
    /// an export or a Save to Photos names its output.
    func resolveName(_ id: Photo.ID) async {
        guard let source, photos.contains(where: { $0.id == id && !$0.isNamed }) else { return }
        let generation = openGeneration
        let read = Task.detached(priority: .utility) { source.name(for: id) }
        let name = await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
        guard !Task.isCancelled, generation == openGeneration, let name else { return }
        setNames([id: name])
    }

    /// The sort by name's pass (`resort`): every unnamed photo named in one
    /// detached loop, written in one change, then sorted. Started once per
    /// source; a new `open` cancels it and drops what it read.
    func nameEveryPhoto() {
        guard namingAll == nil, let source else { return }
        let ids = photos.filter { !$0.isNamed }.map(\.id)
        let generation = openGeneration
        namingAll = Task { [weak self] in
            let read = Task.detached(priority: .userInitiated) { () -> [Photo.ID: String] in
                var out: [Photo.ID: String] = [:]
                for id in ids {
                    if Task.isCancelled { break }
                    if let name = source.name(for: id) { out[id] = name }
                }
                return out
            }
            let names = await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
            guard let self, !Task.isCancelled, generation == self.openGeneration else { return }
            self.namingAll = nil
            self.setNames(names)
            if self.sort.key == .name { self.sortNow() }
        }
    }

    /// Writes resolved names into `photos` in one change; the order stays.
    private func setNames(_ names: [Photo.ID: String]) {
        guard !names.isEmpty else { return }
        var updated = photos
        for i in updated.indices where !updated[i].isNamed {
            if let name = names[updated[i].id] { updated[i] = updated[i].named(name) }
        }
        photos = updated
    }

    /// The file holding the photo's original pixels, from the open source
    /// (a folder photo's own file; an asset's may have to be fetched).
    func originalFile(for id: Photo.ID) async throws -> URL {
        guard let source else { throw PhotoSourceError.notInThisSource(id) }
        return try await source.originalFile(for: id)
    }

    /// Reopens the last source at launch: the folder if it still exists,
    /// or the album if Photos access is already allowed (never a prompt at
    /// launch) and the album is still there. Otherwise, and whenever
    /// Settings › Reopen the last folder or album is off
    /// (`AppSettings.reopenLastSource`), the Welcome view.
    func restoreLastSource(access: PhotosAccess = .live) {
        guard source == nil, settings.reopenLastSource else { return }
        switch settings.lastSource {
        case .photos(let id)?:
            guard access.client.authorizationStatus().canRead,
                  let album = access.client.albums().first(where: { $0.id == id }) else { return }
            open(album: album, access: access)
        case .folder(let path)?:
            guard FileManager.default.fileExists(atPath: path) else { return }
            open(URL(fileURLWithPath: path))
        case nil:
            return
        }
    }

    /// The photos the filter admits, in sort order: what the grid shows and
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
        // An arrow at either end moves nothing but still leaves 1:1.
        loupeZoom = .fit
    }

    /// Z: 1:1 at the middle of the photo, or back to fit.
    func toggleZoom() {
        if case .fit = loupeZoom {
            cropMode = false
            loupeZoom = .actual(center: CGPoint(x: 0.5, y: 0.5))
        } else {
            loupeZoom = .fit
        }
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

    /// The photos a batch action targets, in sort order: the multi-selection
    /// when there is one, else the anchor. A photo the filter hides is never a
    /// target, whatever the selection set holds.
    var batchTargets: [Photo.ID] {
        let ids = visiblePhotos.map(\.id).filter { selectedIDs.contains($0) }
        if ids.isEmpty, let selection, isVisible(selection) { return [selection] }
        return ids
    }

    /// What a right-click on `id` acts on: the batch targets when the photo is
    /// one of them (inside the selection), that photo alone when it is not
    /// (Finder's rule); nothing for a photo the filter hides.
    func contextTargets(for id: Photo.ID) -> [Photo.ID] {
        guard isVisible(id) else { return [] }
        let targets = batchTargets
        return targets.contains(id) ? targets : [id]
    }

    /// After the filter or a mark changed: hidden photos leave the selection,
    /// and a hidden anchor moves to the nearest visible photo after it in
    /// sort order (culling flow: reject under Picks shows the next one),
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
        if sort.key == .rating { resort() }
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

    /// The LOAD path for a recipe found outside the sidecar (a Photos
    /// asset's adjustment data, `recoverRecipe`): installed like `open`'s
    /// `recipes = loaded.recipes`, so no undo step is recorded, and written
    /// to the sidecar so the next open reads it from JSON. Not an edit:
    /// `setRecipe` remains the only path that changes one.
    func restore(_ recipe: Recipe, for id: Photo.ID) {
        apply(recipe, to: id)
        persist(id)
    }

    /// When the loupe opens a Photos asset that has no sidecar: if Photos
    /// holds PhotoLab's adjustment data for it, its recipe is installed
    /// through `restore`. Another app's edit is ignored (the original shows);
    /// PhotoLab data of a newer version lists the photo in
    /// `unreadableSidecars`. Nothing is asked for a folder photo, a photo
    /// with a sidecar, an edit or an unreadable mark, and nothing is
    /// installed when the photo was edited, or the source changed, while
    /// the data was read. A read that fails (offline) leaves the photo as is.
    func recoverRecipe(for id: Photo.ID) async {
        guard let source = source as? PhotosSource, let store, !store.exists(for: id),
              recipes[id] == nil, !unreadableSidecars.contains(id) else { return }
        let recovered: Recipe?
        do {
            recovered = try await source.recoverRecipe(for: id)
        } catch let error as SidecarError {
            guard stillRecoverable(id, store: store) else { return }
            unreadableSidecars.insert(id)
            sidecarError = "Could not read the edit saved in Photos for \(name(for: id)): \(error.localizedDescription)"
            return
        } catch {
            return
        }
        guard let recovered, stillRecoverable(id, store: store) else { return }
        restore(recovered, for: id)
    }

    /// True while `id` is in the open listing of the same sidecar store and
    /// still has no sidecar, recipe, history or open drag.
    private func stillRecoverable(_ id: Photo.ID, store: SidecarStore) -> Bool {
        self.store?.directory == store.directory && photos.contains { $0.id == id }
            && !store.exists(for: id) && recipes[id] == nil && history[id] == nil && openEdit?.id != id
    }

    /// Save to Photos is offered for the anchor when it is an edited photo
    /// of a Photos album and no save is running.
    var canSaveToPhotos: Bool {
        guard let id = selection, source is PhotosSource, isEdited(id) else { return false }
        if case .saving = photosSave { return false }
        return true
    }

    /// Writes the anchor's recipe into Photos as the asset's edit
    /// (`PhotosSource.saveEdit`): the adjustment data plus the rendered
    /// full-size JPEG, so Photos shows the edit and can revert it. A slider
    /// drag in progress is closed first. The sidecar is not touched.
    func saveToPhotos() async {
        guard canSaveToPhotos, let id = selection, let source = source as? PhotosSource else { return }
        closeOpenEdit()
        let recipe = recipe(for: id)
        photosSave = .saving(id)
        await resolveName(id)
        do {
            try await source.saveEdit(recipe, for: id, name: name(for: id))
            photosSave = .saved(id)
        } catch {
            photosSave = .failed(id, error.localizedDescription)
        }
    }

    /// Applies a preset to one photo: its look over the photo's own rotation
    /// and crop, through `setRecipe` (one undo step, the sidecar written).
    func apply(_ preset: Preset, to id: Photo.ID) {
        setRecipe(preset.apply(to: recipe(for: id)), for: id)
    }

    // MARK: Batch

    /// Copies the kinds in `mask` from `source` onto every photo in `ids`,
    /// each through `setRecipe` (its own sidecar, written at once). The
    /// whole batch is ONE undo step: ⌘Z on any photo of it takes them all
    /// back. A photo the sync would not change is skipped, and so is one
    /// that is not in the open source (a request made before another source
    /// was opened): its sidecar would land in this source's store. Returns
    /// how many photos changed.
    @discardableResult
    func sync(_ source: Recipe, mask: SyncMask, to ids: [Photo.ID]) -> Int {
        sync(ids.map { (id: $0, source: source) }, mask: mask)
    }

    /// `sync` with a source per photo (Auto's six values, each photo its
    /// own): the same batch, one tag for the lot, the same skips.
    @discardableResult
    func sync(_ sources: [(id: Photo.ID, source: Recipe)], mask: SyncMask) -> Int {
        let batch = UUID()
        let listed = Set(photos.map(\.id))
        var changed = 0
        for (id, source) in sources where listed.contains(id) {
            let current = recipe(for: id)
            let next = current.syncing(mask, from: source)
            guard next != current.normalized else { continue }
            setRecipe(next, for: id, batch: batch)
            changed += 1
        }
        return changed
    }

    /// Auto (`AutoTone`): exposure, contrast, highlights, shadows, whites
    /// and blacks set from each photo's histogram, applied through `sync`
    /// with one batch tag: one undo step for the lot (one photo or the
    /// grid's selection) and one sidecar write per photo changed. Running it
    /// again changes nothing. Returns how many photos changed.
    ///
    /// Each photo's histogram is read from its decoded master
    /// (`Renderer.previewMaster` at `PreviewModel.masterPixelSize`, the
    /// loupe's own decode), never from a camera RAW's embedded first frame:
    /// that preview is the camera's rendering, and Auto on it would not
    /// match the photo once the master replaced it. The decode runs off the
    /// main thread, so a RAW still on its first frame simply takes the
    /// master's time. A photo whose original cannot be read is skipped; a
    /// source opened meanwhile drops the lot (`sync` skips photos it does
    /// not list).
    @discardableResult
    func autoTone(_ ids: [Photo.ID]) async -> Int {
        guard !autoToning, !ids.isEmpty else { return 0 }
        autoToning = true
        defer { autoToning = false }
        var sources: [(id: Photo.ID, source: Recipe)] = []
        for id in ids {
            guard let url = try? await originalFile(for: id) else { continue }
            let recipe = recipe(for: id)
            let values = await Task.detached(priority: .userInitiated) { () -> [AdjustmentKind: Double]? in
                guard let master = Renderer.previewMaster(url, maxPixelSize: PreviewModel.masterPixelSize)
                else { return nil }
                return AutoTone.values(for: master, recipe: recipe)
            }.value
            guard let values else { continue }
            sources.append((id, AutoTone.applying(values, to: .neutral)))
        }
        // A drag left open would fold Auto into its step.
        closeOpenEdit()
        return sync(sources, mask: AutoTone.mask)
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
    func requestPaste(for ids: [Photo.ID]? = nil) {
        let targets = ids ?? batchTargets
        guard let copied = copiedSettings, !targets.isEmpty else { return }
        syncRequest = SyncRequest(source: copied.recipe, sourceName: copied.name,
                                  targets: targets, mask: lastSyncMask)
    }

    /// The (file, recipe) pairs an export of `ids` writes, each file the
    /// source's original (`originalFile(for:)`). The recipes are snapshotted
    /// here, when the export sheet opens (`ExportQueue.requestExport` is
    /// called with the result): an edit made while the sheet is up or while
    /// the queue runs does not change what is written for a photo already in it.
    /// Every item carries the library's originals as `protected`: each
    /// photo's own file plus the files resolved for this export (a Photos
    /// original's cached copy), so an Overwrite never lands on one.
    func exportItems(for ids: [Photo.ID]) async throws -> [ExportQueue.Item] {
        var resolved: [(URL, Recipe, String?)] = []
        for id in ids {
            // A Photos original's cached copy is named by its id: the output
            // takes the photo's own name instead. Folder photos keep theirs.
            var own: String?
            if case .asset = id {
                await resolveName(id)
                own = name(for: id)
            }
            resolved.append((try await originalFile(for: id), recipe(for: id), own))
        }
        let protected = Set(photos.compactMap(\.fileURL)).union(resolved.map(\.0))
        return resolved.map { ExportQueue.Item(source: $0.0, recipe: $0.1, name: $0.2, protected: protected) }
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

    /// A crop handle dragged `translation` view points over a fit frame
    /// `fit` points in size, measured from where the drag started: the crop
    /// edges the handle owns move through `setRecipe`, inside one
    /// `beginEdit` … `endEdit`, so the whole drag is ONE undo step and ONE
    /// sidecar write (at `endCropDrag`). The first call of a drag opens it.
    func dragCrop(_ handle: CropMath.Handle, by translation: CGSize, fit: CGSize, for id: Photo.ID) {
        if cropDragStart == nil {
            beginEdit(id)
            cropDragStart = CropMath.crop(of: recipe(for: id))
        }
        guard let start = cropDragStart else { return }
        // Under an aspect lock a corner holds the ratio of the fit frame
        // (the rotated frame's aspect); `fit` is that frame in points.
        let moved = CropMath.drag(handle, from: start, by: translation, fit: fit,
                                  ratio: cropAspect.normalized(frame: fit))
        var r = recipe(for: id)
        CropMath.write(moved, edges: CropMath.edgesToWrite(handle, from: start, to: moved), into: &r)
        setRecipe(r, for: id)
    }

    /// Picks the crop's aspect. A locked one refits the photo's crop to the
    /// ratio of a frame `frame` in size (the rotated frame's aspect: the
    /// decoded master's, since rotate keeps it) through `setRecipe`, ONE undo
    /// step and one sidecar write; a crop that already holds it, or Free,
    /// changes nothing. With no photo the pick is only remembered.
    func setCropAspect(_ aspect: CropMath.Aspect, frame: CGSize, for id: Photo.ID?) {
        cropAspect = aspect
        guard let id, let k = aspect.normalized(frame: frame) else { return }
        let start = CropMath.crop(of: recipe(for: id))
        guard !CropMath.holds(start, ratio: k) else { return }
        let fitted = CropMath.refit(start, ratio: k)
        var r = recipe(for: id)
        CropMath.write(fitted, edges: CropMath.Edge.allCases.filter { fitted[$0] != start[$0] }, into: &r)
        setRecipe(r, for: id)
    }

    /// The portrait/landscape swap: the same preset turned on its side,
    /// refitted as `setCropAspect` does. Free and 1:1 have nothing to turn.
    func swapCropAspect(frame: CGSize, for id: Photo.ID?) {
        guard cropAspect.canSwap else { return }
        var a = cropAspect
        a.swapped.toggle()
        setCropAspect(a, frame: frame, for: id)
    }

    /// The straighten line's mouse-up: rotate is set so the line from `a`
    /// to `b` (view points over the crop-mode frame) is level, or upright
    /// when it is steeper than 45°, through `setRecipe` (one undo step, one
    /// write). The tool disarms; a line too short to read changes nothing.
    func straighten(from a: CGPoint, to b: CGPoint, for id: Photo.ID) {
        straightening = false
        let current = recipe(for: id)
        guard let value = StraightenMath.rotate(levelling: a, b, current: current.effective(.rotate)) else { return }
        var r = current
        r.set(.rotate, to: value)
        r.setEnabled(.rotate, true)
        setRecipe(r, for: id)
    }

    /// The crop drag's mouse-up: the edit closes (one undo step, one write).
    func endCropDrag(_ id: Photo.ID) {
        cropDragStart = nil
        endEdit(id)
    }

    var canUndo: Bool { selection.map { history[$0]?.undo.isEmpty == false } ?? false }
    var canRedo: Bool { selection.map { history[$0]?.redo.isEmpty == false } ?? false }

    /// Undoes the last edit of the selected photo. When that edit was part of
    /// a batch, every photo whose latest edit is the same batch goes back
    /// with it (a photo edited again since keeps its later edit).
    func undo() {
        guard let id = selection, let top = history[id]?.undo.last else { return }
        openEdit = nil
        cropDragStart = nil
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
        cropDragStart = nil
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
    /// Under the `.edited` sort, a photo gaining or losing its edit moves.
    private func apply(_ recipe: Recipe, to id: Photo.ID) {
        let wasEdited = recipes[id] != nil
        if recipe.isDefault { recipes.removeValue(forKey: id) } else { recipes[id] = recipe }
        if sort.key == .edited, wasEdited != (recipes[id] != nil) { resort() }
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
