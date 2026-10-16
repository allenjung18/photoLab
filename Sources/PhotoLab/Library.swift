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
    /// The photo the source recipe belongs to, when it is one (nil for a
    /// preset): targets that are its master's virtual copies keep an
    /// automatic mask's bitmap instead of detecting again.
    var sourceID: Photo.ID? = nil
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
/// Photos album through `PhotosSource`, a saved collection through
/// `CollectionSource`). Originals are never written to:
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
    /// The grid's search field (`FilterBar`, focused by ⌘F): a photo shows
    /// only when every term matches its name or one of its keywords
    /// (`PhotoSearch`), on top of the filter. Changing it reconciles the
    /// selection as the filter does; reset to empty by `open`, never
    /// remembered.
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            let next = PhotoSearch(searchText)
            guard next != search else { return }
            search = next
            reconcileSelection()
        }
    }
    /// `searchText` split into its terms.
    private(set) var search = PhotoSearch("")
    /// True while a text field of the main window has focus (the search
    /// field, mirrored from its `FocusState`): every bare-key command is
    /// disabled then (`AppCommand.all`), so P, X, 0–5 and the arrows reach
    /// the field instead of the photos.
    var textEntryActive = false
    /// Set by Search Photos (⌘F); the search field takes focus and clears it.
    var searchFocusRequested = false
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
                finishMaskDrag()
                selectedMask = nil
                // A detection still running is for the photo left behind.
                autoMaskGeneration += 1
                autoMaskMessage = nil
            }
            saveViewState()
        }
    }
    /// Every selected photo (the grid's multi-selection), anchor included.
    private(set) var selectedIDs: Set<Photo.ID> = []
    /// Loupe (single photo) when true, grid otherwise.
    var loupe = false {
        didSet {
            if !loupe { loupeZoom = .fit; cropMode = false; whiteBalancePicking = false; maskBrushArmed = false; maskPlacement = nil }
            if loupe { showMap = false }
            saveViewState()
        }
    }
    /// The map (View › Map, ⌥⌘M) in the grid's place: the visible photos
    /// that carry a GPS position (`PhotoMapView`). Opening it leaves the
    /// loupe and starts the location pass (`PhotoLocations.start`); leaving
    /// it, or the loupe opening, cancels the pass. Not in `SourceViewState`
    /// and reset by `open`, so a source always opens on the grid or the loupe.
    var showMap = false {
        didSet {
            guard showMap != oldValue else { return }
            if showMap {
                loupe = false
                locations.start(photos, store: photoInfo)
            } else {
                locations.cancel()
            }
        }
    }
    /// The map's positions and its location pass.
    let locations = PhotoLocations()
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
                finishMaskDrag()
                loupeZoom = .fit
                compare = false
                whiteBalancePicking = false
                maskBrushArmed = false
                maskPlacement = nil
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
    /// The white-balance eyedropper is armed (W, Photo › White Balance
    /// Picker, the Color section's eyedropper): the next click on the loupe
    /// photo, at fit or 1:1, samples the patch under it and sets temperature
    /// and tint so it renders grey (`pickWhiteBalance`). Tool state like
    /// straightening: never in a recipe, never remembered, kept across
    /// photo changes. Arming it leaves crop mode and ends compare; entering
    /// crop mode or compare, Esc, leaving the loupe and a balanced pick
    /// disarm it.
    var whiteBalancePicking = false {
        didSet {
            guard whiteBalancePicking != oldValue else { return }
            if whiteBalancePicking {
                cropMode = false
                compare = false
                whiteBalanceNote = nil
                maskBrushArmed = false
                maskPlacement = nil
            }
        }
    }
    /// The mask the Masks section shows the sliders of (`LocalMask.id`, in
    /// the selected photo's `Recipe.masks`). Tool state like the crop's
    /// aspect: never in a recipe, never remembered. Cleared when the photo
    /// changes and whenever the photo's recipe stops holding it (an undo of
    /// its add, a delete, a reset, a sync), by `apply`.
    var selectedMask: UUID? {
        didSet {
            guard selectedMask != oldValue else { return }
            if maskDragStart?.mask != selectedMask || brushStrokeMask != nil { finishMaskDrag() }
            // A brush mask selected in the loupe is ready to paint into
            // (`paintingBrush`); an automatic mask waits for K (a click on
            // the photo should not refine a detection by accident); any other
            // selection puts the brush down.
            maskBrushArmed = loupe && selectedMaskShape?.isBrush == true
        }
    }
    /// The selected mask's shape, when it is a mask of the selected photo.
    private var selectedMaskShape: MaskShape? {
        guard let photo = selection, let id = selectedMask else { return nil }
        return recipe(for: photo).masks.first(where: { $0.id == id })?.shape
    }
    /// The selected mask takes brush strokes: a brush mask, or an automatic
    /// mask (whose strokes refine its bitmap, `AutoMask.strokes`).
    var selectedMaskIsPaintable: Bool { selectedMaskShape?.paintStrokes != nil }
    /// The brush is armed on the selected brush or automatic mask (K, Photo ›
    /// Brush, the Masks section's New Brush, or a brush mask picked in the
    /// list): drags on the photo paint into it (`paintBrush`, `Library.paintingBrush`).
    /// Tool state like the eyedropper: arming leaves crop mode, ends compare
    /// and puts the eyedropper down; any of those, another mask selected,
    /// Esc and leaving the loupe disarm it, ending a stroke in progress.
    var maskBrushArmed = false {
        didSet {
            guard maskBrushArmed != oldValue else { return }
            // Put down mid-stroke (Esc): the stroke so far is kept.
            guard maskBrushArmed else { if brushStrokeMask != nil { finishMaskDrag() }; return }
            cropMode = false
            compare = false
            whiteBalancePicking = false
            maskPlacement = nil
        }
    }
    /// New Linear or New Radial is armed (M, Shift-M, the Masks section's
    /// Linear and Radial): the next drag on the loupe photo places a new mask
    /// of that kind (start to end; centre to edge), a click places its
    /// default shape there (`placeMask`), and either selects it and disarms.
    /// Tool state like the brush: arming leaves crop mode, ends compare and
    /// puts the eyedropper and the brush down; any of those, Esc and leaving
    /// the loupe disarm it.
    var maskPlacement: MaskKind? {
        didSet {
            guard maskPlacement != oldValue else { return }
            // A kind switched (or Esc) mid-placement ends that placement.
            finishMaskDrag()
            guard maskPlacement != nil else { return }
            cropMode = false
            compare = false
            whiteBalancePicking = false
            maskBrushArmed = false
        }
    }
    /// Show Mask Overlay (O, View menu, the Masks section's checkbox): the
    /// selected mask tinted red at half strength over the loupe's After
    /// frame (`MaskTint`, composed by `PreviewModel` like the clipping
    /// warning). Never in compare's Before, a thumbnail or an export.
    var showMaskOverlay = false
    /// The brush new strokes are painted with (Size, Feather, Flow in the
    /// selected brush's rows; [ and ] for the size). Tool state: never in a
    /// recipe, never remembered.
    var brush = BrushSettings()
    /// The brush mask a stroke is being painted into, while one is
    /// (`paintBrush` ... `endBrushStroke`).
    @ObservationIgnored var brushStrokeMask: UUID?
    /// Why the last eyedropper click changed nothing (a clipped or too dark
    /// patch, an unreadable photo), for the panel's status line; cleared by
    /// arming the tool again and by a balanced pick.
    private(set) var whiteBalanceNote: String?
    /// True while `pickWhiteBalance` reads a photo: a second click waits.
    private(set) var whiteBalanceReading = false
    /// Why the last Select Subject, Person, Faces or Sky added no mask ("No
    /// subject found", "No person found", "No faces found", "No sky found", an unreadable
    /// photo), for the Masks section; cleared by the next run and by a photo
    /// change.
    private(set) var autoMaskMessage: String?
    /// True while `selectAuto` or `selectFaces` runs a detection: Select
    /// Subject, Select Person, Select Faces and Select Sky (guess) are disabled.
    private(set) var autoMaskDetecting = false
    /// Bumped by a photo change and by opening a source: a detection that
    /// finishes under another generation is dropped (`selectAuto`,
    /// `selectFaces`).
    @ObservationIgnored private var autoMaskGeneration = 0
    /// What finds an automatic mask's pixels (`AutoMaskDetector`): Apple
    /// Vision on this Mac; a test replaces it with a fake.
    @ObservationIgnored var autoMaskDetector: any AutoMaskDetector = VisionDetector()
    /// The crop a handle drag started from, while one is in progress.
    private var cropDragStart: CropMath.Crop?
    /// The mask a handle or placement drag is moving and its shape when the
    /// drag started, while one is in progress.
    private var maskDragStart: (mask: UUID, shape: MaskShape)?
    /// Copy Settings: the recipe and the name of the photo it came from.
    private(set) var copiedSettings: (recipe: Recipe, name: String)?
    /// The photo `copiedSettings` came from (a paste onto one of its virtual
    /// copies keeps an automatic mask's bitmap: same pixels).
    private(set) var copiedFrom: Photo.ID?
    /// A Sync / Paste Settings sheet the window should show.
    var syncRequest: SyncRequest?
    /// A Match Look sheet the window should show (`MatchLookModel`).
    var matchLookRequest: MatchLookModel?
    /// The mask of the last sync, so the next sheet opens the same way.
    var lastSyncMask = SyncMask.look
    /// Edits per photo for the open folder, mirrored to sidecars.
    private(set) var recipes: [Photo.ID: Recipe] = [:]
    /// Flags and ratings per photo (only the non-empty ones), mirrored to the
    /// same sidecars beside the recipe; never an undo step.
    private(set) var marks: [Photo.ID: Marks] = [:]
    /// Keywords per photo (only the non-empty lists, `Keywords.normalized`),
    /// in the same sidecars as the marks and like them never an undo step,
    /// never in a recipe, preset or sync mask; a reset leaves them.
    private(set) var keywords: [Photo.ID: [String]] = [:]
    /// The Keywords sheet the window should show.
    var keywordsRequest: KeywordsRequest?
    /// Before/after: true shows the unadjusted photo in the loupe.
    var showBefore = false {
        didSet { if showBefore { finishMaskDrag() } }
    }
    /// Before / After side by side in the loupe (Y, or the toolbar toggle):
    /// the canvas splits into the neutral render and the recipe's.
    var compare = false {
        didSet { if compare { cropMode = false; whiteBalancePicking = false; maskBrushArmed = false; maskPlacement = nil; finishMaskDrag() } }
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
    /// The loupe panel's History section open: `AppSettings.showHistory`,
    /// remembered like Info.
    var showHistory: Bool {
        get { settings.showHistory }
        set { if newValue != settings.showHistory { settings.showHistory = newValue } }
    }
    /// The last sidecar write or read that failed, for the panel to show.
    private(set) var sidecarError: String?
    /// Why the last `open` was refused (a missing path, an album before
    /// Photos access); nil after one succeeds.
    var openError: String?
    /// The Open Photos Library sheet the window should show.
    var photosSheet = false
    /// The My Edits sheet (View › My Edits…, `MyEditsSheet`).
    var myEditsSheet = false
    /// Photos whose sidecar exists but could not be decoded, or whose Photos
    /// adjustment data is PhotoLab's at a version this build does not read;
    /// their edits show as neutral and their sidecars are left alone until
    /// the user edits.
    private(set) var unreadableSidecars: Set<Photo.ID> = []
    /// The last Save to Photos: running, done, or why it failed.
    private(set) var photosSave = PhotosSaveState.idle
    /// True while `autoTone` reads its photos (Auto is disabled meanwhile).
    private(set) var autoToning = false
    /// Photos `autoTone` has finished reading (measured or skipped) of the
    /// photos it was given; (0, 0) when no Auto is running.
    private(set) var autoProgress: (done: Int, total: Int) = (0, 0)
    /// How far the last `autoTone` got when it ended: photos read of those
    /// given (all of them unless it was cancelled).
    private(set) var autoLastRun: (done: Int, total: Int) = (0, 0)
    /// The last Auto batch's outcome worth saying: photos skipped, or that
    /// it was cancelled and applied nothing; nil when it needs no word.
    private(set) var autoNote: String?
    /// What the running job is called in its bar: "Auto", or "Learning
    /// style" (`learnStyle`).
    private(set) var autoLabel = "Auto"
    /// False when `autoNote` reports a result rather than a problem (Learn
    /// Style's "Learned from n photos").
    private(set) var autoNoteWarns = true
    /// Set by `cancelAuto()`; read as each photo's result arrives.
    @ObservationIgnored private var autoCancelled = false
    /// Reads one photo for Auto: (original, its recipe, white balance
    /// only) to the values to apply, nil when it cannot be read. Runs off
    /// the main thread; a test replaces it to count calls in flight.
    @ObservationIgnored var autoMeasure: @Sendable (URL, Recipe, Bool) -> [AdjustmentKind: Double]? = { url, recipe, whiteBalanceOnly in
        guard let master = Renderer.previewMaster(url, maxPixelSize: PreviewModel.masterPixelSize)
        else { return nil }
        guard whiteBalanceOnly else { return AutoTone.values(for: master, recipe: recipe) }
        return WhiteBalance.auto(for: master, recipe: recipe).map {
            [.temperature: $0.temperature, .tint: $0.tint]
        }
    }
    /// Most photos Auto reads at once: 4, or half the processors if fewer.
    static var autoConcurrency: Int { min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)) }
    /// Where the learned style is kept (`StyleStore`); nil keeps it in
    /// memory only (a library made with `rememberFolder: false` and no store).
    let styleStore: StyleStore?
    /// The learned style, nil when none is saved (or it could not be read).
    private(set) var styleProfile: StyleProfile?
    /// Why the style file could not be read or written; nil when it could.
    private(set) var styleError: String?
    /// The Learn Style confirm the window should show.
    var learnStyleRequest: LearnStyleRequest?
    /// Where collections are saved (`CollectionStore`); nil keeps every
    /// collection command off (a library made without one).
    let collectionStore: CollectionStore?
    /// Bumped whenever a collection is saved or deleted, so a menu or the
    /// Welcome list reading `savedCollections()` redraws.
    var collectionsRevision = 0
    /// The New Collection… name sheet the window should show.
    var newCollectionRequest: NewCollectionRequest?
    /// The Delete Collection… confirm the window should show.
    var deleteCollectionRequest: PhotoCollection?
    /// The last collection save or delete that failed.
    var collectionError: String?
    /// How many members of the open collection are missing on disk
    /// (`CollectionSource.missing`): counted in the subtitle, never dropped.
    private(set) var missingMembers = 0
    /// Sidecar writes made since launch (`persist`), so a test can say an
    /// edit was written once; never shown.
    @ObservationIgnored private(set) var sidecarWrites = 0
    /// Moves files to the Trash and back (`FileTrasher`): the app passes
    /// `LiveFileTrasher`, a test a fake over a temporary directory; nil
    /// keeps Move Rejected Photos to Trash… off.
    let trasher: (any FileTrasher)?
    /// The Move Rejected Photos to Trash… confirm the window should show.
    var trashRequest: TrashRequest?
    /// The Remove Virtual Copy… confirm the window should show.
    var removeCopyRequest: VirtualCopyRemoval?
    /// The last move to the Trash, for Undo; nil after an undo, an `open`
    /// or `closeSource`.
    private(set) var trashUndo: TrashUndo?
    /// The banner over the grid shows `trashUndo` (its own close button
    /// hides it; Edit › Undo Move to Trash stays).
    var trashBannerShown = false
    /// What the last move or undo could not do (one line per file), for the
    /// banner; the rest of the photos went ahead.
    private(set) var trashError: String?
    /// The Rename… sheet the window should show.
    var renameRequest: RenameRequest?
    /// The last Rename… batch, for Undo; nil after an undo, an `open`,
    /// `closeSource` or a move to the Trash.
    private(set) var renameUndo: RenameUndo?
    /// The banner over the grid shows `renameUndo` or `renameError`.
    var renameBannerShown = false
    /// Why the last rename or its undo moved nothing.
    private(set) var renameError: String?

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
         captureDates: CaptureDates = CaptureDates(),
         collections: CollectionStore? = nil,
         style: StyleStore? = nil,
         trasher: (any FileTrasher)? = nil) {
        self.settings = settings ?? AppSettings(defaults: defaults, persistent: rememberFolder)
        self.styleStore = style ?? (rememberFolder ? StyleStore() : nil)
        self.trasher = trasher
        self.captureDates = captureDates
        self.collectionStore = collections
        self.photoInfo = PhotoInfoStore(captureDates: captureDates)
        loadStyle()
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
    /// source's photos. The virtual copies of every listed photo are found
    /// beside their masters' sidecars (`PhotoSource.virtualCopies(of:)`) and
    /// listed with them; a copy file whose master is not listed is ignored
    /// and kept.
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
        showMap = false
        locations.reset()
        loupe = false
        showBefore = false
        compare = false
        openEdit = nil
        syncRequest = nil
        keywordsRequest = nil
        newCollectionRequest = nil
        clearTrash()
        history = [:]
        sidecarError = nil
        whiteBalanceNote = nil
        autoMaskGeneration += 1
        autoMaskMessage = nil
        photosSave = .idle
        filter = .all
        searchText = ""
        sort = storedSort(for: sortKind)
        photos = Self.withVirtualCopies(listed, source: source)
        store = source.sidecars
        missingMembers = (source as? CollectionSource)?.missing.count ?? 0
        let loaded = source.loadSidecars(for: photos.map(\.id))
        recipes = loaded.recipes
        marks = loaded.marks
        keywords = loaded.keywords
        unreadableSidecars = Set(loaded.unreadable)
        if let first = loaded.unreadable.first {
            sidecarError = "Could not read the edit saved for \(name(for: first))"
        }
        resort()
        restoreViewState()
    }

    /// Back to the Welcome view: no source, no photos, nothing selected
    /// (the open collection was deleted).
    func closeSource() {
        restoringViewState = true
        defer { restoringViewState = false }
        openGeneration += 1
        namingAll?.cancel()
        namingAll = nil
        selection = nil
        showMap = false
        locations.reset()
        loupe = false
        compare = false
        openEdit = nil
        syncRequest = nil
        keywordsRequest = nil
        newCollectionRequest = nil
        clearTrash()
        history = [:]
        recipes = [:]
        marks = [:]
        keywords = [:]
        unreadableSidecars = []
        missingMembers = 0
        sidecarError = nil
        photos = []
        store = nil
        source = nil
        Thumbnails.shared.source = nil
    }

    /// The open collection changed on disk (members added or removed): the
    /// source becomes the new one, and a removed member leaves the grid,
    /// the selection and every map. Nothing is re-listed or re-read, so the
    /// view stays where it is; a photo added from elsewhere shows on the
    /// next open.
    func replaceCollection(_ collection: PhotoCollection) {
        guard source is CollectionSource else { return }
        let next = CollectionSource(collection)
        source = next
        Thumbnails.shared.source = next
        let kept = Set(collection.members.map(\.id))
        let gone = Set(photos.map(\.id).filter { !kept.contains($0.master) })
        guard !gone.isEmpty else { return }
        photos.removeAll { gone.contains($0.id) }
        for id in gone {
            recipes.removeValue(forKey: id)
            marks.removeValue(forKey: id)
            keywords.removeValue(forKey: id)
            history.removeValue(forKey: id)
            unreadableSidecars.remove(id)
        }
        if let edit = openEdit, gone.contains(edit.id) { openEdit = nil }
        reconcileSelection()
    }

    /// `listed` plus the virtual copies `source` finds for them, each copy
    /// a `Photo.virtualCopy` of its master (the sort places it, `PhotoSort`).
    private static func withVirtualCopies(_ listed: [Photo], source: any PhotoSource) -> [Photo] {
        let copies = source.virtualCopies(of: listed.map(\.id))
        guard !copies.isEmpty else { return listed }
        let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return listed + copies.compactMap { id in
            guard let n = id.copyNumber, let m = byID[id.master] else { return nil }
            return m.virtualCopy(number: n)
        }
    }

    // MARK: Virtual copies

    /// Makes a virtual copy of `id` (a master, or a copy: the new one is
    /// its master's): the lowest copy number from 2 that no listed copy and
    /// no sidecar file holds, the source photo's current recipe and no
    /// marks or keywords. Its sidecar is written at once, even at the
    /// default recipe (the file is how it exists); it is listed right after
    /// its master and the copies numbered below it, and selected (unless the
    /// filter or the search hides it: the selection then follows
    /// `reconcileSelection`, as for any hidden photo). Nil, with
    /// `sidecarError` set, when the write fails; nil for a photo not listed.
    @discardableResult
    func createVirtualCopy(of id: Photo.ID) -> Photo.ID? {
        guard let source, let master = photos.first(where: { $0.id == id.master }) else { return nil }
        closeOpenEdit()
        let store = source.sidecars(for: master.id)
        let taken = Set(photos.compactMap { $0.id.master == master.id ? $0.id.copyNumber : nil })
        var n = PhotoID.firstCopyNumber
        while taken.contains(n) || store.exists(for: .copy(of: master.id, number: n)) { n += 1 }
        let copy = master.virtualCopy(number: n)
        let recipe = recipe(for: id)
        do {
            try store.save(recipe, marks: .none, keywords: [], for: copy.id, name: copy.name)
            sidecarWrites += 1
            sidecarError = nil
        } catch {
            sidecarError = "Could not make a virtual copy of \(master.name): \(error.localizedDescription)"
            return nil
        }
        if !recipe.isDefault { recipes[copy.id] = recipe }
        let after = photos.lastIndex { $0.id == master.id || ($0.id.master == master.id && ($0.id.copyNumber ?? 0) < n) }
        photos.insert(copy, at: (after ?? photos.count - 1) + 1)
        selection = copy.id
        reconcileSelection()  // a copy the filter or the search hides is not the anchor
        return copy.id
    }

    /// Removes a virtual copy: its sidecar is deleted and it leaves the
    /// photos, the recipes, the marks, the keywords and the undo history;
    /// a selected copy hands the selection to its master (to the nearest
    /// visible photo when the filter or the search hides it). Refused (false)
    /// for a master, a photo not listed, and when the file cannot be
    /// deleted (`sidecarError` says why).
    @discardableResult
    func removeVirtualCopy(_ id: Photo.ID) -> Bool {
        guard id.isCopy, let source, photos.contains(where: { $0.id == id }) else { return false }
        if openEdit?.id == id { openEdit = nil }
        do {
            // An unreadable copy file is moved aside, never deleted.
            let store = source.sidecars(for: id)
            try SidecarStore.backUpIfUnreadable(store.url(for: id), now: Date())
            try store.remove(for: id)
        } catch {
            sidecarError = "Could not remove the virtual copy of \(name(for: id)): \(error.localizedDescription)"
            return false
        }
        photos.removeAll { $0.id == id }
        recipes.removeValue(forKey: id)
        marks.removeValue(forKey: id)
        keywords.removeValue(forKey: id)
        history.removeValue(forKey: id)
        unreadableSidecars.remove(id)
        if selection == id {
            selection = photos.contains(where: { $0.id == id.master }) ? id.master : nil
        } else if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        }
        reconcileSelection()  // a master the filter or the search hides is not the anchor
        if selection == nil { loupe = false }
        return true
    }

    /// True when `id` is a listed virtual copy: Photo › Remove Virtual Copy
    /// is on.
    func canRemoveVirtualCopy(_ id: Photo.ID?) -> Bool {
        guard let id, id.isCopy, source != nil else { return false }
        return photos.contains { $0.id == id }
    }

    /// Asks the window for the confirm before `removeVirtualCopy` (no undo
    /// step takes a removal back). Ignored for a master.
    func requestRemoveVirtualCopy(_ id: Photo.ID) {
        guard canRemoveVirtualCopy(id) else { return }
        removeCopyRequest = VirtualCopyRemoval(id: id, name: name(for: id))
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
        case .collection(let id)?:
            guard let uuid = UUID(uuidString: id), let c = collectionStore?.load(uuid) else { return }
            open(collection: c)
        case nil:
            return
        }
    }

    /// The photos the filter admits and the search matches, in sort order:
    /// what the grid shows and what every selection path walks. Under `.all`
    /// with no search it is `photos`.
    var visiblePhotos: [Photo] {
        if !isNarrowed { return photos }
        return photos.filter(admits)
    }

    func isVisible(_ id: Photo.ID) -> Bool {
        guard filter.admits(marks(for: id)) else { return false }
        if search.isEmpty { return true }
        guard let photo = photos.first(where: { $0.id == id }) else {
            return search.matches(name: nil, keywords: keywords(for: id))
        }
        return search.matches(photo, keywords: keywords(for: id))
    }

    /// The filter admits the photo's marks and the search matches it.
    private func admits(_ photo: Photo) -> Bool {
        filter.admits(marks(for: photo.id))
            && (search.isEmpty || search.matches(photo, keywords: keywords(for: photo.id)))
    }

    /// True when the grid shows fewer than every photo could: a filter other
    /// than All, or a search ("n of N shown").
    var isNarrowed: Bool { filter != .all || !search.isEmpty }

    /// Every keyword on the open source's photos with how many photos hold
    /// it (`Keywords.tally`): the grid bar's Keywords menu.
    var keywordTally: [Keywords.Tally] {
        Keywords.tally(photos.map { keywords(for: $0.id) })
    }

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

    /// Exactly the listed, visible ones of `ids`, the first of them the
    /// anchor (a map pin's photos); nothing when none is.
    func select(_ ids: [Photo.ID]) {
        let listed = Set(photos.map(\.id))
        let shown = ids.filter { listed.contains($0) && isVisible($0) }
        guard let first = shown.first else { return }
        selection = first
        selectedIDs = Set(shown)
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

    /// After the filter, the search, a mark or a keyword changed: hidden
    /// photos leave the selection, and a hidden anchor moves to the nearest
    /// visible photo after it in sort order (culling flow: reject under Picks
    /// shows the next one), else the nearest before, else none.
    private func reconcileSelection() {
        let shown = Set(visiblePhotos.map(\.id))
        let kept = selectedIDs.filter(shown.contains)
        if let anchor = selection, !shown.contains(anchor) {
            let visible = photos.indices.filter { shown.contains(photos[$0].id) }
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

    // MARK: Move to Trash

    /// Every rejected photo of the open source, visible or not, in sort
    /// order: what Move Rejected Photos to Trash… acts on. Folder photos only
    /// (a `FolderSource`, or a collection's members): a Photos album's are
    /// never offered (D-465). A rejected virtual copy is never one: its file
    /// is its master's.
    var rejectedPhotos: [Photo.ID] {
        guard source is FolderSource || source is CollectionSource else { return [] }
        return photos.filter { $0.fileURL != nil && !$0.id.isCopy && marks(for: $0.id).flag == .reject }.map(\.id)
    }

    /// The command is on when there is a trasher and a rejected folder photo.
    var canTrashRejects: Bool { trasher != nil && !rejectedPhotos.isEmpty }

    /// Asks the window for the confirm over every rejected photo.
    func requestTrashRejects() {
        guard canTrashRejects else { return }
        let ids = rejectedPhotos
        trashRequest = TrashRequest(targets: ids, names: ids.map(name(for:)))
    }

    /// Moves `ids` to the Trash through `trasher`: only the ones still listed,
    /// still rejected and files of a folder or a collection (a request made
    /// before a mark changed moves nothing it no longer names). Each sidecar
    /// stays in its `.photolab/`, so Put Back restores the edit and the marks.
    /// A moved photo leaves `photos`, every map, the selection (a moved
    /// anchor goes to the nearest kept visible photo after it, else before)
    /// and the thumbnail cache, and so do its virtual copies (their
    /// sidecars stay too). A file that fails stays, is named in
    /// `trashError`, and the rest go ahead. Returns how many moved.
    @discardableResult
    func moveToTrash(_ ids: [Photo.ID]) -> Int {
        guard let trasher else { return 0 }
        let eligible = Set(rejectedPhotos)
        closeOpenEdit()
        var moved: [TrashedPhoto] = []
        var failures: [String] = []
        for id in ids where eligible.contains(id) {
            guard let photo = photos.first(where: { $0.id == id }), let url = photo.fileURL else { continue }
            do {
                moved.append(TrashedPhoto(photo: photo, trashedURL: try trasher.trash(url)))
            } catch {
                failures.append("Could not move \(photo.name) to the Trash: \(error.localizedDescription)")
            }
        }
        trashError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        guard !moved.isEmpty else { trashBannerShown = !failures.isEmpty; return 0 }
        let masters = Set(moved.map(\.photo.id))
        let gone = Set(photos.map(\.id).filter { masters.contains($0.master) })
        // The anchor's successor is found while the anchor is still listed.
        var anchor = selection
        if let a = anchor, gone.contains(a) {
            let shown = Set(visiblePhotos.map(\.id)).subtracting(gone)
            let pos = selectedIndex ?? 0
            let kept = photos.indices.filter { shown.contains(photos[$0].id) }
            anchor = (kept.first { $0 > pos } ?? kept.last { $0 < pos }).map { photos[$0].id }
        }
        let keptSelection = selectedIDs.subtracting(gone)
        for id in gone {
            Thumbnails.shared.forget(id, recipes: [recipe(for: id)])
            recipes.removeValue(forKey: id)
            marks.removeValue(forKey: id)
            keywords.removeValue(forKey: id)
            history.removeValue(forKey: id)
            unreadableSidecars.remove(id)
        }
        photos.removeAll { gone.contains($0.id) }
        if anchor != selection { selection = anchor }
        if let anchor { selectedIDs = keptSelection.union([anchor]) } else { selectedIDs = [] }
        if selection == nil { loupe = false }
        reconcileSelection()
        missingMembers = (source as? CollectionSource)?.missing.count ?? 0
        trashUndo = TrashUndo(photos: moved)
        trashBannerShown = true
        // One file-level undo at a time: a rename undone after its photos
        // went to the Trash would find nothing to move back.
        clearRename()
        return moved.count
    }

    /// Edit › Undo Move to Trash and the banner's Undo: each photo of the
    /// last move goes back from where the Trash put it to its own path,
    /// unless a file is there now (refused, named in `trashError`, left in
    /// the Trash), and is listed again with its edit, marks and keywords read
    /// from its sidecar, which never moved (the LOAD path, as `open`), with
    /// its virtual copies found again beside it. The selection stays.
    /// Returns how many came back.
    @discardableResult
    func undoMoveToTrash() -> Int {
        guard let undo = trashUndo, let trasher, let source else { return 0 }
        trashUndo = nil
        var back: [Photo] = []
        var failures: [String] = []
        for item in undo.photos {
            guard let original = item.photo.fileURL else { continue }
            do {
                if FileManager.default.fileExists(atPath: original.path) {
                    throw TrashError.pathTaken(original.lastPathComponent)
                }
                try trasher.restore(item.trashedURL, to: original)
                back.append(item.photo)
            } catch {
                failures.append("Could not put \(item.photo.name) back: \(error.localizedDescription)")
            }
        }
        trashError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        trashBannerShown = !failures.isEmpty
        guard !back.isEmpty else { return 0 }
        let listed = Set(photos.map(\.id))
        let added = Self.withVirtualCopies(back.filter { !listed.contains($0.id) }, source: source)
            .filter { !listed.contains($0.id) }
        let loaded = source.loadSidecars(for: added.map(\.id))
        for (id, r) in loaded.recipes { recipes[id] = r }
        for (id, m) in loaded.marks { marks[id] = m }
        for (id, k) in loaded.keywords { keywords[id] = k }
        unreadableSidecars.formUnion(loaded.unreadable)
        photos += added
        resort()
        missingMembers = (source as? CollectionSource)?.missing.count ?? 0
        reconcileSelection()
        return back.count
    }

    /// Drops the undo and the banner (a new source).
    private func clearTrash() {
        trashRequest = nil
        trashUndo = nil
        trashError = nil
        trashBannerShown = false
        clearRename()
    }

    // MARK: Rename in place

    /// Rename… is offered over `ids` when the open source is a folder or a
    /// collection and every one is a listed file photo (never a Photos
    /// asset: D-465). A virtual copy stands for its master: one file.
    func canRename(_ ids: [Photo.ID]) -> Bool {
        guard source is FolderSource || source is CollectionSource, !ids.isEmpty else { return false }
        let listed = Set(photos.map(\.id))
        return ids.allSatisfy { $0.master.fileURL != nil && listed.contains($0.master) }
    }

    /// `ids` with each virtual copy replaced by its master, each once, in
    /// order: the files a rename moves.
    private func renameMasters(_ ids: [Photo.ID]) -> [Photo.ID] {
        var seen = Set<Photo.ID>()
        return ids.map(\.master).filter { seen.insert($0).inserted }
    }

    /// Asks the window for the Rename… sheet over `ids` (the batch targets
    /// when nil).
    func requestRename(for ids: [Photo.ID]? = nil) {
        let targets = ids ?? batchTargets
        guard canRename(targets) else { return }
        renameRequest = RenameRequest(targets: targets)
    }

    /// The batch `ids` under `template`, in the order given, a virtual copy
    /// counted as its master (`{seq}` counts
    /// in it; `{date}` is `captureDates`'): the sheet's preview and what
    /// `rename(_:)` carries out. Refused as a whole for a clash
    /// (`RenameRefusal`), and for photos `canRename` does not offer.
    func renamePlan(_ template: RenameTemplate, for ids: [Photo.ID]) -> RenamePlan {
        guard canRename(ids), let source else { return RenamePlan(entries: [], refusal: .notFiles) }
        let batch = renameMasters(ids).compactMap { id -> (id: PhotoID, file: URL, date: Date?)? in
            guard let photo = photos.first(where: { $0.id == id }), let file = photo.fileURL else { return nil }
            return (id, file, captureDates.date(for: photo))
        }
        let roots = collectionRoots()
        return RenamePlan.make(template, photos: batch) { entry in
            sidecarStores(for: entry.id, source: source, roots: roots).contains {
                RenameMove.sidecarTaken(in: $0, old: entry.old, new: entry.new)
            }
        }
    }

    /// Every saved collection's member roots, by file (one listing).
    private func collectionRoots() -> [URL: [URL]] {
        var out: [URL: [URL]] = [:]
        for c in collectionStore?.loadAll().collections ?? [] {
            for m in c.members { out[m.file.standardizedFileURL, default: []].append(m.root) }
        }
        return out
    }

    /// The stores a rename of `id` moves edits in, each directory once: the
    /// open source's (`sidecars(for:)`), then every folder that may hold an
    /// edit for the file under another name: each saved collection member's
    /// root for it, and each folder above the file (the scan is recursive,
    /// so a parent folder opened once keeps `sub/a.jpg.json`) whose store has
    /// a sidecar or a copy sidecar for it.
    private func sidecarStores(for id: Photo.ID, source: any PhotoSource, roots: [URL: [URL]]) -> [SidecarStore] {
        let primary = source.sidecars(for: id)
        guard let file = id.fileURL else { return [primary] }
        var candidates = (roots[file.standardizedFileURL] ?? []).map { SidecarStore(folder: $0) }
        var dir = file.deletingLastPathComponent().standardizedFileURL
        while true {
            candidates.append(SidecarStore(folder: dir))
            let up = dir.deletingLastPathComponent().standardizedFileURL
            if up.path == dir.path { break }
            dir = up
        }
        var seen: Set<String> = [primary.directory.standardizedFileURL.path]
        var out = [primary]
        for store in candidates where seen.insert(store.directory.standardizedFileURL.path).inserted {
            if store.exists(for: id) || !store.copies(of: [id]).isEmpty { out.append(store) }
        }
        return out
    }

    /// Renames the plan's changing photos in place: each file moved in its
    /// own directory and its sidecar moved with it (`RenameMove`), then
    /// every map keyed by the old id rekeyed to the new one (`rekey`). A
    /// refused or stale plan moves nothing; a move that fails part-way
    /// moves the done ones back, and `renameError` says which failed.
    /// Undo (`undoRename`) is offered until the next open. Returns how many
    /// were renamed.
    @discardableResult
    func rename(_ plan: RenamePlan) -> Int {
        guard plan.refusal == nil, let source else { return 0 }
        guard canRename(plan.entries.map(\.id)) else {
            renameError = RenameRefusal.notFiles.message
            renameBannerShown = true
            return 0
        }
        closeOpenEdit()
        let roots = collectionRoots()
        let moves = plan.changing.map {
            RenameMove(old: $0.old, new: $0.new, stores: sidecarStores(for: $0.id, source: source, roots: roots))
        }
        do {
            try RenameMove.perform(moves)
        } catch {
            renameError = error.localizedDescription + " Nothing was renamed."
            renameBannerShown = true
            return 0
        }
        rekey(moves)
        trashUndo = nil
        trashError = nil
        trashBannerShown = false
        renameUndo = RenameUndo(moves: moves)
        renameError = nil
        renameBannerShown = true
        return moves.count
    }

    /// Edit › Undo Rename and the banner's Undo: every photo of the last
    /// batch back to its old name, sidecar and maps with it, by the same
    /// moves reversed; all or nothing, as `rename`. Returns how many.
    @discardableResult
    func undoRename() -> Int {
        guard let undo = renameUndo else { return 0 }
        let back = undo.moves.map(\.reversed)
        guard canRename(back.map(\.oldID)) else {
            renameError = "Could not undo the rename: a renamed photo is no longer listed."
            renameBannerShown = true
            return 0
        }
        closeOpenEdit()
        do {
            try RenameMove.perform(back)
        } catch {
            renameError = error.localizedDescription + " Nothing was renamed back."
            renameBannerShown = true
            return 0
        }
        rekey(back)
        renameUndo = nil
        renameError = nil
        renameBannerShown = false
        return back.count
    }

    /// Drops the rename's undo and banner.
    private func clearRename() {
        renameRequest = nil
        renameUndo = nil
        renameError = nil
        renameBannerShown = false
    }

    /// Every map keyed by a moved photo's old id now keyed by its new one:
    /// `photos`, recipes, marks, keywords, edit history, unreadable
    /// sidecars, the selection and its anchor, the thumbnail cache, capture
    /// dates, the Info cache, the map's positions, every saved collection's
    /// members (the open one's source too) and every remembered view-state
    /// anchor. Requests made over the old ids are dropped.
    private func rekey(_ moves: [RenameMove]) {
        guard !moves.isEmpty else { return }
        var map = Dictionary(moves.map { ($0.oldID, $0.newID) }, uniquingKeysWith: { a, _ in a })
        // Each listed virtual copy follows its master (its sidecar moved too).
        for p in photos {
            if let n = p.id.copyNumber, let master = map[p.id.master] { map[p.id] = .copy(of: master, number: n) }
        }
        func re<V>(_ d: [Photo.ID: V]) -> [Photo.ID: V] {
            Dictionary(d.map { (map[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        for (old, new) in map {
            Thumbnails.shared.rename(old, to: new, recipes: [recipe(for: old)])
            captureDates.rename(old, to: new)
            photoInfo.rename(old, to: new, name: new.fileURL?.lastPathComponent ?? new.defaultName)
        }
        recipes = re(recipes)
        marks = re(marks)
        keywords = re(keywords)
        history = re(history)
        unreadableSidecars = Set(unreadableSidecars.map { map[$0] ?? $0 })
        photos = photos.map { p in
            guard let id = map[p.id], let file = id.fileURL else { return p }
            return Photo(id: id, name: file.lastPathComponent, captureDate: p.captureDate, location: p.location)
        }
        let ids = Set(selectedIDs.map { map[$0] ?? $0 })
        if let anchor = selection, let moved = map[anchor] { selection = moved }
        selectedIDs = ids
        syncRequest = nil
        keywordsRequest = nil
        trashRequest = nil
        newCollectionRequest = nil
        renameRequest = nil
        removeCopyRequest = nil
        rekeyCollections(map)
        rekeyRecentAnchors(map)
        resort()
        reconcileSelection()
        if showMap { locations.start(photos, store: photoInfo) }
    }

    /// Each saved collection holding a moved file follows it (same root);
    /// the open collection's source is the updated one.
    private func rekeyCollections(_ map: [Photo.ID: Photo.ID]) {
        func moved(_ c: PhotoCollection) -> PhotoCollection? {
            var c = c
            var changed = false
            for i in c.members.indices {
                if let file = map[c.members[i].id]?.fileURL {
                    c.members[i].file = file
                    changed = true
                }
            }
            return changed ? c : nil
        }
        if let collectionStore {
            var saved = false
            for c in collectionStore.loadAll().collections {
                guard let next = moved(c) else { continue }
                do {
                    try collectionStore.save(next)
                    saved = true
                } catch {
                    collectionError = error.localizedDescription
                }
            }
            if saved { collectionsRevision += 1 }
        }
        if let open = openCollection, let next = moved(open) {
            let source = CollectionSource(next)
            self.source = source
            Thumbnails.shared.source = source
        }
    }

    // MARK: Keywords

    /// The photo's keywords, normalized; empty when it has none.
    func keywords(for id: Photo.ID) -> [String] { keywords[id] ?? [] }

    /// Adds `words` to every photo in `ids` (a keyword a photo already has,
    /// in any case, is kept as it was spelled). Written to each changed
    /// photo's sidecar at once; not an undo step, the recipe untouched.
    func addKeywords(_ words: [String], to ids: [Photo.ID]) {
        let words = Keywords.normalized(words)
        guard !words.isEmpty else { return }
        for id in ids {
            let current = keywords(for: id)
            let merged = Keywords.normalized(current + words)
            if merged != current { setKeywords(merged, for: id) }
        }
        reconcileSelection()
    }

    /// Removes `word` (case-insensitively) from every photo in `ids` that has
    /// it. Same rules as `addKeywords`.
    func removeKeyword(_ word: String, from ids: [Photo.ID]) {
        for id in ids {
            let current = keywords(for: id)
            let kept = current.filter { !Keywords.same($0, word) }
            if kept.count != current.count { setKeywords(kept, for: id) }
        }
        reconcileSelection()
    }

    /// Asks the window for the Keywords sheet over `ids` (the batch targets
    /// when nil).
    func requestKeywords(for ids: [Photo.ID]? = nil) {
        let targets = ids ?? batchTargets
        guard !targets.isEmpty else { return }
        keywordsRequest = KeywordsRequest(targets: targets)
    }

    private func setKeywords(_ words: [String], for id: Photo.ID) {
        if words.isEmpty { keywords.removeValue(forKey: id) } else { keywords[id] = words }
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
    /// of a Photos album, not a virtual copy, and no save is running. A copy
    /// never: Photos keeps one edit per asset, so a copy's save would
    /// replace its master's (`saveToPhotosCopyHelp` says so).
    var canSaveToPhotos: Bool {
        guard let id = selection, !id.isCopy, source is PhotosSource, isEdited(id) else { return false }
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

    /// Auto (`AutoTone`): temperature and tint (`WhiteBalance.auto`), then
    /// exposure, contrast, highlights, shadows, whites and blacks set from
    /// each photo's histogram, applied through `sync`
    /// with one batch tag: one undo step for the lot (one photo or the
    /// grid's selection) and one sidecar write per photo changed. Running it
    /// again changes nothing. Returns how many photos changed.
    ///
    /// Each photo's histogram is read from its decoded master
    /// (`Renderer.previewMaster` at `PreviewModel.masterPixelSize`, the
    /// loupe's own decode), never from a camera RAW's embedded first frame:
    /// that preview is the camera's rendering, and Auto on it would not
    /// match the photo once the master replaced it. The reads run off the
    /// main thread, at most `autoConcurrency` at a time in a task group, and
    /// their results are keyed by `Photo.ID`, so the order they finish in
    /// never matters. `autoProgress` counts them. `cancelAuto()` stops it
    /// and applies nothing (`autoNote` says so): all or nothing, never a
    /// partial batch. A photo whose original cannot be read is skipped and
    /// counted in `autoNote`; a source opened meanwhile drops the lot
    /// (`sync` skips photos it does not list). The one `sync` at the end is
    /// the only way the values are applied. `mask`
    /// `AutoTone.whiteBalanceMask` is Auto White Balance: only temperature
    /// and tint, measured the same way.
    @discardableResult
    func autoTone(_ ids: [Photo.ID], mask: SyncMask = AutoTone.mask) async -> Int {
        let whiteBalanceOnly = mask == AutoTone.whiteBalanceMask
        let measure = autoMeasure
        guard let run = await runAutoJob(ids, label: "Auto", measure: { url, recipe in
            measure(url, recipe, whiteBalanceOnly)
        }) else { return 0 }
        if run.cancelled {
            autoNote = "Auto cancelled: nothing changed (one batch, all or nothing)"
            return 0
        }
        if run.unreadable > 0 { autoNote = "Auto: \(run.unreadable) photo\(run.unreadable == 1 ? "" : "s") skipped" }
        // The photo's own recipe underneath: a white balance Auto could
        // not read stays as it is. In the order given, whatever finished first.
        let sources = ids.compactMap { id in
            run.results[id].map { (id, AutoTone.applying($0, to: recipe(for: id))) }
        }
        // A drag left open would fold Auto into its step.
        closeOpenEdit()
        return sync(sources, mask: mask)
    }

    /// The Auto job behind `autoTone` and `learnStyle`: `measure` over each
    /// photo's original and recipe (as they are when the job starts), off
    /// the main thread, at most `autoConcurrency` at a time in a task group,
    /// results keyed by `Photo.ID`. `autoToning` is true and `autoProgress`
    /// counts the reads meanwhile (the bar says "`label` n of N");
    /// `cancelAuto()` ends it with `cancelled` set. A photo whose original
    /// cannot be read, or that `measure` returns nil for, counts in
    /// `unreadable`. Nil when a job is already running or `ids` is empty.
    private func runAutoJob<T: Sendable>(_ ids: [Photo.ID], label: String,
                                         measure: @escaping @Sendable (URL, Recipe) -> T?) async
        -> (results: [Photo.ID: T], unreadable: Int, cancelled: Bool)? {
        guard !autoToning, !ids.isEmpty else { return nil }
        autoToning = true
        autoCancelled = false
        autoNote = nil
        autoNoteWarns = true
        autoLabel = label
        autoProgress = (0, ids.count)
        defer { autoToning = false; autoLastRun = autoProgress; autoProgress = (0, 0) }
        let cap = Self.autoConcurrency
        var results: [Photo.ID: T] = [:]
        var unreadable = 0
        let recipes = Dictionary(ids.map { ($0, recipe(for: $0)) }, uniquingKeysWith: { a, _ in a })
        await withTaskGroup(of: (Photo.ID, T?).self) { group in
            var next = 0
            func start(_ id: Photo.ID) {
                let recipe = recipes[id] ?? .neutral
                group.addTask { [weak self] in
                    guard let self, let url = try? await self.originalFile(for: id) else { return (id, nil) }
                    let value = await Task.detached(priority: .userInitiated) {
                        measure(url, recipe)
                    }.value
                    return (id, value)
                }
            }
            while next < min(cap, ids.count) { start(ids[next]); next += 1 }
            for await (id, value) in group {
                autoProgress = (autoProgress.done + 1, ids.count)
                if let value { results[id] = value } else { unreadable += 1 }
                if autoCancelled { group.cancelAll(); continue }
                if next < ids.count { start(ids[next]); next += 1 }
            }
        }
        return (results, unreadable, autoCancelled)
    }

    /// Match Look (`LookMatch`): the global tone and colour of `reference`
    /// brought to each photo of `ids`. The reference is decoded once
    /// (`Renderer.previewMaster` at `PreviewModel.masterPixelSize`) and measured
    /// with `ImageStats.of(master:recipe:)` under `.neutral`, as the file is,
    /// off the main thread; it is only read, never copied, imported or
    /// written. Each target is then solved (`LookMatch.values`, off the main
    /// thread, at most `autoConcurrency` at a time) and the answers are applied
    /// through `sync` with `LookMatch.mask`: ONE undo step for the lot, the
    /// sidecars holding ordinary slider values. The run shares Auto's flag,
    /// progress and `cancelAuto()`: a cancel applies nothing. Throws
    /// `MatchLookError` (nothing changed) when the reference cannot be read or
    /// another batch is running; a target that cannot be read is skipped and
    /// counted in the outcome.
    func matchLook(reference: URL, to ids: [Photo.ID]) async throws -> MatchLookOutcome {
        guard !autoToning else { throw MatchLookError.busy }
        var seen = Set<Photo.ID>()
        let listed = Set(photos.map(\.id))
        let targets = ids.filter { listed.contains($0) && seen.insert($0).inserted }
        guard !targets.isEmpty else { return MatchLookOutcome(changed: 0, skipped: 0, moved: []) }
        autoToning = true
        autoCancelled = false
        autoNote = nil
        autoProgress = (0, targets.count)
        defer { autoToning = false; autoLastRun = autoProgress; autoProgress = (0, 0) }
        let stats = await Task.detached(priority: .userInitiated) { () -> ImageStats? in
            guard let master = Renderer.previewMaster(reference, maxPixelSize: PreviewModel.masterPixelSize)
            else { return nil }
            return ImageStats.of(master: master, recipe: .neutral)
        }.value
        guard let stats else { throw MatchLookError.unreadable(reference.lastPathComponent) }
        let cap = Self.autoConcurrency
        var solved: [Photo.ID: [AdjustmentKind: Double]] = [:]
        var skipped = 0
        let recipes = Dictionary(targets.map { ($0, recipe(for: $0)) }, uniquingKeysWith: { a, _ in a })
        await withTaskGroup(of: (Photo.ID, [AdjustmentKind: Double]?).self) { group in
            var next = 0
            func start(_ id: Photo.ID) {
                let recipe = recipes[id] ?? .neutral
                group.addTask { [weak self] in
                    guard let self, let url = try? await self.originalFile(for: id) else { return (id, nil) }
                    let values = await Task.detached(priority: .userInitiated) { () -> [AdjustmentKind: Double]? in
                        guard let master = Renderer.previewMaster(url, maxPixelSize: PreviewModel.masterPixelSize)
                        else { return nil }
                        return LookMatch.values(target: stats, master: master, recipe: recipe)
                    }.value
                    return (id, values)
                }
            }
            while next < min(cap, targets.count) { start(targets[next]); next += 1 }
            for await (id, values) in group {
                autoProgress = (autoProgress.done + 1, targets.count)
                if let values { solved[id] = values } else { skipped += 1 }
                if autoCancelled { group.cancelAll(); continue }
                if next < targets.count { start(targets[next]); next += 1 }
            }
        }
        if autoCancelled {
            autoNote = "Match Look cancelled: nothing changed (one batch, all or nothing)"
            throw MatchLookError.cancelled
        }
        if skipped > 0 { autoNote = "Match Look: \(skipped) photo\(skipped == 1 ? "" : "s") skipped" }
        let before = Dictionary(targets.map { ($0, recipe(for: $0)) }, uniquingKeysWith: { a, _ in a })
        let sources = targets.compactMap { id in
            solved[id].map { (id: id, source: LookMatch.applying($0, to: recipe(for: id))) }
        }
        // A drag left open would fold the match into its step.
        closeOpenEdit()
        let changed = sync(sources, mask: LookMatch.mask)
        return MatchLookOutcome(changed: changed, skipped: skipped,
                                moved: MatchLookOutcome.rows(targets.map { (before[$0] ?? .neutral, recipe(for: $0)) }))
    }

    /// Detects the automatic masks `kinds` (`AutoMaskKind`; `.sky` is a
    /// guess, `SkyGuess`, not re-detected here: it is left out, and a sync
    /// copies a sky mask as it was) on each photo of `ids` through
    /// `autoMaskDetector`: the batch entry point `syncRedetecting` uses and
    /// the one a later detect-on-import flow can call. Nothing is written to
    /// a recipe. Each photo is read once (the oriented decode at
    /// `VisionDetector.inputPixelSize`), at most `autoConcurrency` at a time
    /// off the main actor, with `autoProgress` counting them and
    /// `cancelAuto()` stopping the run. The result maps a photo to the kinds
    /// that found something (a blank bitmap, a failure and an unreadable
    /// original all leave the kind out); a photo with nothing has no entry.
    /// Nil when it did not run (an Auto or another detection is running) or
    /// was cancelled (`autoNote` says so).
    func detectAutoMasks(_ kinds: [AutoMaskKind], for ids: [Photo.ID]) async -> [Photo.ID: [AutoMaskKind: MaskBitmap]]? {
        guard !autoToning else { return nil }
        var distinct: [AutoMaskKind] = []
        for k in kinds where k != .sky && !distinct.contains(k) { distinct.append(k) }
        let wanted = distinct
        var seen = Set<Photo.ID>()
        let targets = ids.filter { seen.insert($0).inserted }
        guard !wanted.isEmpty, !targets.isEmpty else { return [:] }
        autoToning = true
        autoCancelled = false
        autoNote = nil
        autoProgress = (0, targets.count)
        defer { autoToning = false; autoLastRun = autoProgress; autoProgress = (0, 0) }
        let detector = autoMaskDetector
        let cap = Self.autoConcurrency
        var found: [Photo.ID: [AutoMaskKind: MaskBitmap]] = [:]
        await withTaskGroup(of: (Photo.ID, [AutoMaskKind: MaskBitmap]).self) { group in
            var next = 0
            func start(_ id: Photo.ID) {
                group.addTask { [weak self] in
                    guard let self, let url = try? await self.originalFile(for: id) else { return (id, [:]) }
                    let result = await Task.detached(priority: .userInitiated) { () -> [AutoMaskKind: MaskBitmap] in
                        guard let image = ImageLoading.downsampledCGImage(url, maxPixelSize: VisionDetector.inputPixelSize)
                        else { return [:] }
                        var out: [AutoMaskKind: MaskBitmap] = [:]
                        for kind in wanted {
                            let bitmap = kind == .person ? try? await detector.person(in: image)
                                                         : try? await detector.subject(in: image)
                            if let bitmap, !bitmap.isBlank { out[kind] = bitmap }
                        }
                        return out
                    }.value
                    return (id, result)
                }
            }
            while next < min(cap, targets.count) { start(targets[next]); next += 1 }
            for await (id, result) in group {
                autoProgress = (autoProgress.done + 1, targets.count)
                if !result.isEmpty { found[id] = result }
                if autoCancelled { group.cancelAll(); continue }
                if next < targets.count { start(targets[next]); next += 1 }
            }
        }
        if autoCancelled {
            autoNote = "Detection cancelled: nothing changed (one batch, all or nothing)"
            return nil
        }
        return found
    }

    /// `sync` for a source that may carry automatic masks. Without
    /// `mask.masks`, or with no `.auto` mask in `source`, it IS `sync`.
    /// Otherwise each `.auto` mask is detected again on each target
    /// (`detectAutoMasks`): the target's own bitmap of that kind, `kind`
    /// and the mask's other fields kept, `strokes` dropped (they were painted
    /// on the source's pixels). A target where the kind finds nothing gets no
    /// such mask and is counted in `autoNote`; the other shapes copy as
    /// `sync` copies them. A target that shares the source's master (a
    /// virtual copy of it, same pixels) keeps the mask as it is. The whole
    /// sync is applied once detection finishes, as ONE undo step (`sync`'s
    /// batch); a cancelled detection applies nothing. Returns how many
    /// photos changed.
    @discardableResult
    func syncRedetecting(_ source: Recipe, mask: SyncMask, from sourceID: Photo.ID? = nil,
                         to ids: [Photo.ID]) async -> Int {
        let masks = source.normalized.masks
        let kinds: [AutoMaskKind] = mask.masks ? masks.compactMap {
            if case .auto(let a) = $0.shape, a.kind != .sky { return a.kind }
            return nil
        } : []
        guard !kinds.isEmpty else { return sync(source, mask: mask, to: ids) }
        guard !autoToning else {
            autoNote = "Sync not applied: another batch is running, try again when it ends"
            return 0
        }
        let same: (Photo.ID) -> Bool = { id in sourceID.map { id.master == $0.master } ?? false }
        guard let found = await detectAutoMasks(kinds, for: ids.filter { !same($0) }) else { return 0 }
        // A drag left open would fold the sync into its step.
        closeOpenEdit()
        var skipped = 0
        let sources: [(id: Photo.ID, source: Recipe)] = ids.map { id in
            guard !same(id) else { return (id, source) }
            var r = source
            r.masks = masks.compactMap { local in
                guard case .auto(let a) = local.shape, a.kind != .sky else { return local }
                guard let bitmap = found[id]?[a.kind] else { skipped += 1; return nil }
                var out = local
                out.shape = .auto(AutoMask(kind: a.kind, bitmap: bitmap))
                return out
            }
            return (id, r)
        }
        if skipped > 0 {
            autoNote = "Sync: \(skipped) automatic mask\(skipped == 1 ? "" : "s") not found on the target, skipped"
        }
        return sync(sources, mask: mask)
    }

    /// Stops a running Auto: nothing is applied (`autoTone` returns 0).
    func cancelAuto() {
        guard autoToning else { return }
        autoCancelled = true
    }

    /// Clears the Auto status line.
    func dismissAutoNote() { autoNote = nil }

    // MARK: Style (Auto in my style, the learning half)

    /// Reads one photo for Learn Style: (original, recipe) to its bucket and
    /// Auto's values with its Basic and white-balance kinds at neutral
    /// (`StyleSample.measure`), from the same decode Auto reads; nil when it
    /// cannot be read. Runs off the main thread; a test may replace it.
    @ObservationIgnored var styleMeasure: @Sendable (URL, Recipe) -> (bucket: StyleBucket, auto: [AdjustmentKind: Double])? = { url, recipe in
        guard let master = Renderer.previewMaster(url, maxPixelSize: PreviewModel.masterPixelSize)
        else { return nil }
        return StyleSample.measure(master: master, recipe: recipe)
    }

    /// Learns the style from `ids` (Photo › Learn Style from Selected
    /// Photos…): one `StyleSample` per photo through `runAutoJob` (Auto's
    /// concurrency, progress and cancel), `StyleProfile.learn(from:)` over
    /// them (`replace`) or over the current samples with them laid on top
    /// (`StyleProfile.merging`), saved by `styleStore`. A photo whose own
    /// values are all neutral or equal Auto's (`StyleSample.skip`), or that
    /// cannot be read, is skipped and counted. `autoNote` says "Learned
    /// from n photos (m skipped)". A cancel, or a run that yields no sample,
    /// leaves the saved style as it was. Returns the samples taken.
    @discardableResult
    func learnStyle(from ids: [Photo.ID], replace: Bool) async -> Int {
        let measure = styleMeasure
        guard let run = await runAutoJob(ids, label: "Learning style", measure: { url, recipe in
            measure(url, recipe).map { (bucket: $0.bucket, auto: $0.auto, recipe: recipe) }
        }) else { return 0 }
        if run.cancelled {
            autoNote = "Learn Style cancelled: nothing changed"
            return 0
        }
        var samples: [StyleSample] = []
        var skipped = run.unreadable
        for id in ids {
            guard let m = run.results[id] else { continue }
            let own = Dictionary(uniqueKeysWithValues: AutoTone.kinds.map { ($0, m.recipe.effective($0)) })
            let sample = StyleSample(photo: id, bucket: m.bucket, auto: m.auto, own: own)
            if sample.skip != nil { skipped += 1 } else { samples.append(sample) }
        }
        let note = "Learned from \(samples.count) photo\(samples.count == 1 ? "" : "s") (\(skipped) skipped)"
        guard !samples.isEmpty else {
            autoNote = note
            return 0
        }
        let all = replace ? samples : StyleProfile.merging(samples, into: styleProfile?.samples ?? [])
        let profile = StyleProfile.learn(from: all)
        do {
            try styleStore?.save(profile)
            styleProfile = profile
            styleError = nil
            autoNote = note
            autoNoteWarns = false
        } catch {
            styleError = error.localizedDescription
            autoNote = "Learn Style could not save: \(error.localizedDescription)"
        }
        return samples.count
    }

    /// Asks the window for the Learn Style confirm over `ids` (Replace /
    /// Add to current samples).
    func requestLearnStyle(_ ids: [Photo.ID]) {
        guard !ids.isEmpty, !autoToning else { return }
        learnStyleRequest = LearnStyleRequest(ids: ids, currentSamples: styleProfile?.sampleCount ?? 0)
    }

    /// Forget Style is offered while there is a profile or a file (an
    /// unreadable one included).
    var canForgetStyle: Bool { styleProfile != nil || (styleStore?.exists ?? false) }

    /// Settings › Forget Style: deletes `style.json` and the profile.
    func forgetStyle() {
        do {
            try styleStore?.remove()
            styleProfile = nil
            styleError = nil
        } catch {
            styleError = error.localizedDescription
        }
    }

    /// Re-reads `style.json` (at launch): a file that cannot be read leaves
    /// no profile and `styleError` set, and stays on disk until a save
    /// moves it aside.
    func loadStyle() {
        guard let styleStore else { styleProfile = nil; return }
        do {
            styleProfile = try styleStore.load()
            styleError = nil
        } catch {
            styleProfile = nil
            styleError = error.localizedDescription
        }
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
        copiedFrom = id
    }

    /// Asks the window for the Sync Settings sheet: the anchor's recipe onto
    /// the other selected photos.
    func requestSync() {
        guard let anchor = selection else { return }
        let targets = batchTargets.filter { $0 != anchor }
        guard !targets.isEmpty else { return }
        syncRequest = SyncRequest(source: recipe(for: anchor), sourceName: name(for: anchor),
                                  targets: targets, mask: lastSyncMask, sourceID: anchor)
    }

    /// Asks the window for the Paste Settings sheet: the copied recipe onto
    /// the selection.
    func requestPaste(for ids: [Photo.ID]? = nil) {
        let targets = ids ?? batchTargets
        guard let copied = copiedSettings, !targets.isEmpty else { return }
        syncRequest = SyncRequest(source: copied.recipe, sourceName: copied.name,
                                  targets: targets, mask: lastSyncMask, sourceID: copiedFrom)
    }

    /// The (file, recipe) pairs an export of `ids` writes, each file the
    /// source's original (`originalFile(for:)`), with the photo's keywords
    /// (written as IPTC Keywords when Keep camera info is on). The recipes and keywords are snapshotted
    /// here, when the export sheet opens (`ExportQueue.requestExport` is
    /// called with the result): an edit made while the sheet is up or while
    /// the queue runs does not change what is written for a photo already in it.
    /// Every item carries the library's originals as `protected`: each
    /// photo's own file plus the files resolved for this export (a Photos
    /// original's cached copy), so an Overwrite never lands on one, and
    /// its capture date (`captureDates`), which a name template's `{date}`
    /// reads.
    func exportItems(for ids: [Photo.ID]) async throws -> [ExportQueue.Item] {
        var resolved: [(URL, Recipe, String?, [String], Date?, Int?)] = []
        for id in ids {
            // A Photos original's cached copy is named by its id: the output
            // takes the photo's own name instead. Folder photos keep theirs.
            var own: String?
            if case .asset = id.master {
                await resolveName(id)
                own = name(for: id)
            }
            let date = photos.first(where: { $0.id == id }).flatMap { captureDates.date(for: $0) }
            resolved.append((try await originalFile(for: id), recipe(for: id), own, keywords(for: id), date,
                             id.copyNumber))
        }
        let protected = Set(photos.compactMap(\.fileURL)).union(resolved.map(\.0))
        return resolved.map {
            ExportQueue.Item(source: $0.0, recipe: $0.1, name: $0.2, protected: protected, keywords: $0.3,
                             captureDate: $0.4, copyNumber: $0.5)
        }
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

    /// True while a continuous edit (`beginEdit`) is open on `id`.
    func isEditOpen(on id: Photo.ID) -> Bool { openEdit?.id == id }

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

    /// The eyedropper's click at `point`, normalised in the shown frame
    /// (after crop and rotate, origin top-left: `ZoomMath.center(forClick:)`
    /// at fit, `ZoomMath.point(forClick:)` at 1:1). The photo's master is
    /// decoded off the main thread (`Renderer.previewMaster` at
    /// `PreviewModel.masterPixelSize`, the loupe's own decode, so a RAW is
    /// read from its master, never its embedded first frame), the
    /// `WhiteBalance.patchSize` patch under the point is rendered with the
    /// recipe up to the white-balance stage (`WhiteBalance.base`), and
    /// `WhiteBalance.neutralising` solves it. Applied by `applyWhiteBalance`.
    /// Returns the solve, nil when the photo could not be read.
    @discardableResult
    func pickWhiteBalance(at point: CGPoint, for id: Photo.ID) async -> WhiteBalance.Solve? {
        guard !whiteBalanceReading else { return nil }
        whiteBalanceReading = true
        defer { whiteBalanceReading = false }
        let base = WhiteBalance.base(recipe(for: id))
        guard let url = try? await originalFile(for: id) else {
            whiteBalanceNote = "White balance: the original could not be read."
            return nil
        }
        let solve = await Task.detached(priority: .userInitiated) { () -> WhiteBalance.Solve? in
            guard let master = Renderer.previewMaster(url, maxPixelSize: PreviewModel.masterPixelSize),
                  let rgb = WhiteBalance.patch(of: master, recipe: base, at: point) else { return nil }
            return WhiteBalance.neutralising(rgb)
        }.value
        guard let solve else {
            whiteBalanceNote = "White balance: the original could not be read."
            return nil
        }
        applyWhiteBalance(solve, for: id)
        return solve
    }

    /// A solve onto the photo: balanced, temperature and tint are set (and
    /// switched on) through `setRecipe`, ONE undo step and one sidecar
    /// write, and the tool disarms; a refusal sets `whiteBalanceNote`,
    /// changes no recipe and leaves the tool armed for another click. A
    /// photo the open source no longer lists is left alone.
    func applyWhiteBalance(_ solve: WhiteBalance.Solve, for id: Photo.ID) {
        guard photos.contains(where: { $0.id == id }) else { return }
        guard case let .balanced(temperature, tint) = solve else {
            whiteBalanceNote = solve.refusal
            return
        }
        whiteBalanceNote = nil
        whiteBalancePicking = false
        // A drag left open would fold the pick into its step.
        closeOpenEdit()
        var r = recipe(for: id)
        r.set(.temperature, to: temperature)
        r.setEnabled(.temperature, true)
        r.set(.tint, to: tint)
        r.setEnabled(.tint, true)
        setRecipe(r, for: id)
    }

    /// Select Subject (`kind` `.subject`) and Select Person (`.person`): the
    /// photo's oriented decode (`ImageLoading.downsampledCGImage` at
    /// `VisionDetector.inputPixelSize`, EXIF applied, so the bitmap lands in
    /// the source frame) goes to `autoMaskDetector` off the main actor
    /// (`subject(in:)` or `person(in:)`), and what it finds becomes ONE new
    /// `.auto` mask of that kind at the end of the list, selected, through
    /// `setRecipe`: one undo step and one sidecar write. Nothing found sets
    /// `autoMaskMessage` "No subject found" / "No person found" and changes
    /// nothing (no step, no write); so does an unreadable original or a
    /// detector error, with its own message. A photo change or a source
    /// opened while it runs drops the result. One run at a time
    /// (`autoMaskDetecting`): a second call meanwhile returns nil. Select Sky
    /// (guess) (`kind` `.sky`) is the same flow with no model: the detector's
    /// `horizon(in:)` (nil when none or when it throws) and `SkyGuess.mask(in:horizon:)` on
    /// the same decode; nothing found is "No sky found". Returns the new
    /// mask's id.
    @discardableResult
    func selectAuto(_ kind: AutoMaskKind, for id: Photo.ID) async -> UUID? {
        let title: String
        switch kind {
        case .subject: title = "Subject"
        case .person: title = "Person"
        case .sky: title = "Sky"
        }
        let detector = autoMaskDetector
        let found: MaskBitmap?? = await runAutoDetection(title, for: id) { image in
            switch kind {
            case .subject: return try await detector.subject(in: image)
            case .person: return try await detector.person(in: image)
            case .sky:
                // A horizon request that fails is a horizon not found: the
                // guess still runs, against the level default.
                let horizon = (try? await detector.horizon(in: image)) ?? nil
                return SkyGuess.mask(in: image, horizon: horizon)
            }
        }
        guard let found else { return nil }
        guard let bitmap = found, !bitmap.isBlank else {
            autoMaskMessage = "No \(title.lowercased()) found"
            return nil
        }
        return appendDetectedMasks([LocalMask(shape: .auto(AutoMask(kind: kind, bitmap: bitmap)))], for: id).first
    }

    /// Select Faces: Vision's face rectangles on the photo's oriented decode
    /// (as `selectAuto`), each turned into a `.radial` mask by
    /// `FaceMasks.radial(for:roll:imageSize:)`, all appended in ONE
    /// `setRecipe` (one undo step, one sidecar write), the first selected.
    /// None found sets `autoMaskMessage` "No faces found" and changes
    /// nothing. Shares `selectAuto`'s run guard, drop rule and messages.
    /// Returns the new masks' ids in face order.
    @discardableResult
    func selectFaces(for id: Photo.ID) async -> [UUID] {
        let detector = autoMaskDetector
        let found: [MaskShape]? = await runAutoDetection("Faces", for: id) { image in
            let size = CGSize(width: image.width, height: image.height)
            return try await detector.faces(in: image).map {
                FaceMasks.radial(for: $0.boundingBox, roll: $0.roll?.doubleValue, imageSize: size)
            }
        }
        guard let found else { return [] }
        guard !found.isEmpty else {
            autoMaskMessage = "No faces found"
            return []
        }
        return appendDetectedMasks(found.map { LocalMask(shape: $0) }, for: id)
    }

    /// The run every detection shares: one at a time (`autoMaskDetecting`),
    /// the oriented decode at `VisionDetector.inputPixelSize` handed to
    /// `detect` off the main actor. Nil when the run did not happen, was
    /// dropped (a photo change or a source opened meanwhile:
    /// `autoMaskGeneration`, the selection) or failed; a failure sets its own
    /// `autoMaskMessage` ("Select <title>: the original could not be read." or
    /// "Select <title> failed: ...").
    private func runAutoDetection<T: Sendable>(_ title: String, for id: Photo.ID,
                                               _ detect: @escaping @Sendable (CGImage) async throws -> T) async -> T? {
        guard !autoMaskDetecting else { return nil }
        autoMaskDetecting = true
        defer { autoMaskDetecting = false }
        autoMaskMessage = nil
        let generation = autoMaskGeneration
        let unreadable = "Select \(title): the original could not be read."
        guard let url = try? await originalFile(for: id) else {
            if generation == autoMaskGeneration { autoMaskMessage = unreadable }
            return nil
        }
        let found: Result<T, Error> = await Task.detached(priority: .userInitiated) {
            guard let image = ImageLoading.downsampledCGImage(url, maxPixelSize: VisionDetector.inputPixelSize) else {
                return .failure(AutoMaskUnreadable())
            }
            do { return .success(try await detect(image)) } catch { return .failure(error) }
        }.value
        guard generation == autoMaskGeneration, selection == id,
              photos.contains(where: { $0.id == id }) else { return nil }
        switch found {
        case .failure(is AutoMaskUnreadable):
            autoMaskMessage = unreadable
            return nil
        case .failure(let error):
            autoMaskMessage = "Select \(title) failed: \(error.localizedDescription)"
            return nil
        case .success(let value):
            return value
        }
    }

    /// `masks` appended to photo `id`'s list in one `setRecipe` (one undo
    /// step, one sidecar write), the first selected, crop mode and the
    /// eyedropper put down. Returns their ids.
    private func appendDetectedMasks(_ masks: [LocalMask], for id: Photo.ID) -> [UUID] {
        guard let first = masks.first else { return [] }
        // A drag left open would fold the new masks into its step.
        closeOpenEdit()
        var r = recipe(for: id)
        r.masks.append(contentsOf: masks)
        setRecipe(r, for: id)
        cropMode = false
        whiteBalancePicking = false
        selectedMask = first.id
        return masks.map(\.id)
    }

    /// The crop drag's mouse-up: the edit closes (one undo step, one write).
    func endCropDrag(_ id: Photo.ID) {
        cropDragStart = nil
        endEdit(id)
    }

    /// A mask handle dragged from `from` to `to` (source points, the
    /// pointer's start and where it is now) over a source of `size`: the
    /// shape moves from where it was when the drag began
    /// (`MaskHandles.drag`), through `setRecipe` inside one `beginEdit` …
    /// `endEdit`, so the whole drag is ONE undo step and ONE sidecar write
    /// (at `endMaskDrag`). The first call of a drag opens it; a mask the
    /// photo does not hold changes nothing.
    func dragMask(_ handle: MaskHandle, _ maskID: UUID, from: MaskPoint, to: MaskPoint, size: CGSize,
                  for id: Photo.ID) {
        if maskDragStart?.mask != maskID {
            guard let mask = mask(maskID, for: id) else { return }
            beginEdit(id)
            maskDragStart = (maskID, mask.shape)
        }
        guard let start = maskDragStart?.shape else { return }
        let shape = MaskHandles.drag(handle, shape: start, from: from, to: to, size: size)
        updateMask(maskID, for: id) { $0.shape = shape }
    }

    /// A placement drag with `kind` armed, from `from` to `to` (source
    /// points): its first call adds the mask inside a `beginEdit`, selected,
    /// and every later one reshapes it (`MaskHandles.placed`), so a placement
    /// is ONE new mask, ONE undo step (undo removes it) and ONE sidecar
    /// write (at `endMaskDrag`, which also disarms).
    func dragPlacement(_ kind: MaskKind, from: MaskPoint, to: MaskPoint, size: CGSize, for id: Photo.ID) {
        guard maskPlacement == kind, let shape = MaskHandles.placed(kind, from: from, to: to, size: size) else { return }
        if let drag = maskDragStart, self.mask(drag.mask, for: id) != nil {
            updateMask(drag.mask, for: id) { $0.shape = shape }
            return
        }
        beginEdit(id)
        let mask = LocalMask(shape: shape)
        var r = recipe(for: id)
        r.masks.append(mask)
        setRecipe(r, for: id)
        // Selected first: a selection change ends any OTHER mask's drag.
        selectedMask = mask.id
        maskDragStart = (mask.id, shape)
    }

    /// A click with `kind` armed: the kind's default shape centred at
    /// `point` (source), selected; one undo step and one write; disarms.
    @discardableResult
    func placeMask(_ kind: MaskKind, at point: MaskPoint, for id: Photo.ID) -> UUID? {
        guard maskPlacement == kind, maskDragStart == nil, let shape = MaskHandles.placed(kind, at: point) else { return nil }
        endEdit(id)
        let mask = LocalMask(shape: shape)
        var r = recipe(for: id)
        r.masks.append(mask)
        setRecipe(r, for: id)
        selectedMask = mask.id
        maskPlacement = nil
        return mask.id
    }

    /// Ends a mask drag or a brush stroke the overlay can no longer finish: SwiftUI cancels a
    /// gesture whose view goes (Esc, compare, crop mode, Before, another
    /// mask or photo, a kind switched mid-placement) without calling its
    /// `onEnded`, so `endMaskDrag` would never come. The edit so far closes
    /// as one undo step and one write, and the next drag starts afresh.
    func finishMaskDrag() {
        guard maskDragStart != nil || brushStrokeMask != nil else { return }
        maskDragStart = nil
        brushStrokeMask = nil
        closeOpenEdit()
    }

    /// A mask handle's or a placement's mouse-up: the edit closes (one undo
    /// step, one write) and a placement disarms.
    func endMaskDrag(_ id: Photo.ID) {
        let placed = maskDragStart != nil && maskPlacement != nil
        maskDragStart = nil
        endEdit(id)
        if placed { maskPlacement = nil }
    }

    var canUndo: Bool { selection.map { history[$0]?.undo.isEmpty == false } ?? false }
    var canRedo: Bool { selection.map { history[$0]?.redo.isEmpty == false } ?? false }

    /// Undoes the last edit of the selected photo. When that edit was part of
    /// a batch, every photo whose latest edit is the same batch goes back
    /// with it (a photo edited again since keeps its later edit).
    func undo() {
        if let id = selection { undo(anchor: id) }
    }

    /// `undo` with `id` as the anchor (the History section's photo).
    private func undo(anchor id: Photo.ID) {
        guard let top = history[id]?.undo.last else { return }
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
        if let id = selection { redo(anchor: id) }
    }

    /// `redo` with `id` as the anchor.
    private func redo(anchor id: Photo.ID) {
        guard let top = history[id]?.redo.last else { return }
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

    // MARK: History

    /// The History section's rows for `id`, oldest first: the Original
    /// (position 0), then one row per undo step and per redo step, each
    /// labelled by `HistoryLabel` from the recipes on either side of it. A
    /// read-only view over the private `EditHistory`; empty while the photo
    /// has no step (as after `open`, which resets the history). During a
    /// slider drag the drag shows as the newest row, live, and the redo rows
    /// it is about to drop are gone already.
    func historyEntries(for id: Photo.ID) -> [HistoryEntry] {
        let h = history[id] ?? EditHistory()
        let current = recipe(for: id)
        var states = h.undo.map(\.recipe)
        var batches = h.undo.map(\.batch)
        let dragging = openEdit.map { $0.id == id && $0.before != current } ?? false
        if dragging, let openEdit {
            states += [openEdit.before, current]
            batches.append(nil)
        } else {
            states.append(current)
            for step in h.redo.reversed() {
                states.append(step.recipe)
                batches.append(step.batch)
            }
        }
        guard states.count > 1 else { return [] }
        let now = h.undo.count + (dragging ? 1 : 0)
        return states.indices.map { i in
            HistoryEntry(position: i,
                         label: i == 0 ? HistoryEntry.originalLabel
                             : HistoryLabel.describe(from: states[i - 1], to: states[i], batch: batches[i - 1]),
                         isCurrent: i == now,
                         isUndone: i > now)
        }
    }

    /// Makes row `position` of `historyEntries(for:)` current by running
    /// undo or redo on `id` until it is, so a batch step takes its batch
    /// with it exactly as ⌘Z does, and an edit after the jump drops the rows
    /// above it (`EditHistory.push` clears redo). A drag still open is
    /// closed first, as the step its live row showed.
    func jumpToHistory(_ position: Int, for id: Photo.ID) {
        closeOpenEdit()
        guard let h = history[id] else { return }
        let target = min(max(position, 0), h.undo.count + h.redo.count)
        while let now = history[id]?.undo.count, now != target {
            if now > target { undo(anchor: id) } else { redo(anchor: id) }
            guard history[id]?.undo.count != now else { break }
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
    /// A selected mask the photo's new recipe no longer holds is deselected.
    private func apply(_ recipe: Recipe, to id: Photo.ID) {
        let wasEdited = recipes[id] != nil
        if recipe.isDefault { recipes.removeValue(forKey: id) } else { recipes[id] = recipe }
        if id == selection, let m = selectedMask, !recipe.masks.contains(where: { $0.id == m }) {
            selectedMask = nil
        }
        if sort.key == .edited, wasEdited != (recipes[id] != nil) { resort() }
    }

    /// Writes the photo's sidecar: recipe, marks and keywords together, so a
    /// reset keeps the flag and the keywords, and a flag or a keyword keeps a
    /// default recipe's file.
    private func persist(_ id: Photo.ID) {
        guard let source else { return }
        let store = source.sidecars(for: id)
        do {
            try store.save(recipe(for: id), marks: marks(for: id), keywords: keywords(for: id),
                           for: id, name: name(for: id))
            sidecarWrites += 1
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
