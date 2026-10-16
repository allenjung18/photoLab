# PhotoLab — features

Each thing the user sees, mapped to the types that implement it, the file
they live in, and what it writes to disk. The README says what each feature
does for the user; `Documentation/Architecture.md` says how the render path,
the data model, the edit path and the export pipeline work underneath. This
document is the layer between: screen to type. Every name in backticks is in
`Sources/PhotoLab/`.

The window is `ContentView` (`ContentView.swift`): the welcome screen while
no source is open (`Library.source` is nil), the loupe while `Library.loupe`
is on and a photo is selected, the map while `Library.showMap` is on, the
grid otherwise; a toolbar with Open Folder,
Open Photos Library (disabled without an app bundle) and a Grid / Loupe / Map picker; the hidden keyboard shortcuts; the export bar at
the bottom when a run is going; and three sheets, Sync, Export and Open
Photos Library. The
title is the source's name (the folder's, or the album's), the subtitle "n of N" in the loupe (with the
photo's flag and stars when it has them) and "N photos · n selected" in the
grid; under a filter or a search (`Library.isNarrowed`) both count the photos shown, "n of N shown".

## Welcome

`WelcomeView` (`ContentView.swift`): an icon, "Open a folder of photos, a
Photos album or a collection to begin", the last open error in red if there
is one, **Open Folder…** (also **Return**: the hidden loupe key is disabled
with no photo, see Menus and shortcuts) and **Open Photos Library…**, then
the saved collections (`CollectionList`, see Collections) and the recent
sources (`RecentList`). Under a
bare `swift run` the Photos button is disabled and a line says to run
`scripts/bundle.sh --open` and use `build/PhotoLab.app`
(`PhotosAccess.hasBundle`): the system grants Photos access to an app
bundle, never to a bare binary.

- **Open Folder…** is `Library.chooseFolder` (`Library.swift`): an
  `NSOpenPanel` for directories only, then `Library.open` with the choice.
  The toolbar button and **⌘O** call the same method from any screen.
- `Library.open(_:)` takes a folder, or a file, in which case it opens the
  file's folder with that photo in the loupe. It scans the folder
  (`Library.scan`, below), reads every sidecar through
  `SidecarStore.loadAll` so each photo opens with its edit, resets the
  selection, the loupe, the before/after state and the undo history, and
  remembers the folder. A path that does not exist is refused: the current
  folder and selection stay, and `openError` carries the message the welcome
  screen shows, so a mistyped launch argument never opens its parent or the
  working directory. Sidecars that exist but cannot be decoded (damaged, or
  a `version` from a newer build) are listed in `unreadableSidecars`, shown
  as neutral, reported in `sidecarError` and left alone until the user edits
  that photo; the first write then moves the old file to a
  `.unreadable-<stamp>` backup beside the new sidecar (`UnreadableBackup`)
  and never over it.
- **Open Photos Library…** is `Library.choosePhotosAlbum` (`Library.swift`),
  which raises `Library.photosSheet`; the File menu's **⇧⌘O** calls the
  same method. The sheet is `PhotosAlbumSheet` (`PhotosSheet.swift`) over a
  `PhotosBrowser` (`Photos.swift`) made with `PhotosAccess.live`:
  - not yet asked (`PhotosAuthorization.notDetermined`): a line of text and
    **Allow Access to Photos…**, the one button that shows the system
    dialog (`PhotosBrowser.requestAccess`). Nothing is fetched before it;
    opening the sheet, or launching, never prompts.
  - refused (`denied`): **Open System Settings…** (`PhotosBrowser.settingsURL`,
    the Privacy & Security › Photos pane) and **Check Again**; `restricted`
    says so and offers nothing.
  - allowed (`authorized` or `limited`): the albums, Recents first with a
    clock, then the regular albums by title, each with its image count;
    select and **Open** (also **Return**, or double-click) calls
    `Library.open(album:access:)`, **Cancel** / **Esc** dismisses. A footer
    says edits made in Photos are not shown: PhotoLab edits the original.
  `Library.open(album:access:)` wraps the album in a `PhotosSource` and goes
  through `Library.open(_:)`: before access is allowed `photos()` throws
  `PhotosError.notAuthorized` and the open is refused like a missing path
  (`openError`). The grid then shows the album in its sort (oldest capture
  first until another is picked, see Grid, Sort): every cell at once from
  the listing (identifiers and capture dates only, `PhotoKitClient.assets(in:)`),
  each photo unnamed (`Photo.isNamed` false, an empty `Photo.caption`) until
  its cell is on screen. A grid or filmstrip cell's `.task(id:)` calls
  `Library.resolveName(_:)`, which reads the original's file name
  (`PhotosSource.name(for:)`) off the main thread and writes it into
  `Library.photos`; SwiftUI cancels the task when the cell scrolls away, the
  cancellation reaches the read, and a read that lands for a cancelled cell
  (or for a source opened since) writes nothing. The thumbnails come from
  Photos through the same per-cell, cancellable path (`Thumbnails.source`,
  Architecture 1).
- **Open Recent and reopening where you left off** (`Recents.swift`). The
  last 10 sources, folders, Photos albums and collections alike
  (`RecentSource.Kind`), are kept most recent
  first and deduped under `recentSources` in the library's `AppSettings`
  (`AppSettings.recents`: `RecentSource`, JSON, beside `lastSourceKind`;
  never a test's real defaults). **File › Open Recent** (`OpenRecentMenu`) and a Recent list on
  the Welcome view (`RecentList`) show them, with **Clear Menu**;
  `Library.recentSources` drops (and forgets) a folder that no longer
  exists or a collection no longer saved (`CollectionStore.load`), and
  hides an album Photos no longer lists, or every album while
  Photos access is not already allowed (it never prompts). Each entry also
  carries the source's `SourceViewState`: the anchor photo, grid or loupe,
  and the filter, saved as they change (`Library.saveViewState`) and
  restored at the end of `Library.open` (`restoreViewState`) whichever way
  the source opens (Open Recent, launch, Open Folder). The filter always
  comes back; the anchor and the loupe only when that photo is still in the
  source and the restored filter admits it, otherwise the grid with nothing
  selected. `restoreLastSource` still never prompts. Window size is
  SwiftUI's own restoration, untouched here.
- **The remembered last source.** `Library.open` stores it as
  `AppSettings.lastSource` (`LastSource`): the kind under `lastSourceKind`
  (`folder`, `photos` or `collection`) with the folder's path under
  `lastFolder`, the album's identifier under `lastPhotosAlbum` or the
  collection's id under `lastCollection` (`AppSettings.Key`), when the
  library was made with `rememberFolder` on (its `AppSettings` is
  `persistent`), which the app's is and a test's
  (`Library(rememberFolder: false)`, or one given its own `defaults`) is
  not. At launch `PhotoLabApp` opens the first non-flag command-line
  argument, else calls `Library.restoreLastSource`, which does nothing while
  Settings › Reopen the last folder or album is off
  (`AppSettings.reopenLastSource`, on by default) and otherwise opens the
  stored folder if it still exists, the stored collection if it is still
  saved, or the stored album if Photos access is already allowed (never a
  prompt at launch) and the album is still there;
  this runs once per process (`launched`), so a window re-created from the
  Dock does not reopen the argument and wipe the selection.

Writes: the last source in UserDefaults. Opening an album writes nothing
until a photo is viewed in the loupe (its original is then copied into
the originals cache, below) or edited (a sidecar under
`~/Library/Application Support/PhotoLab/photos-sidecars/`).

## Grid

`GridView` (`ContentView.swift`): the filter bar above, a `LazyVGrid` of
`ThumbnailCell` over `Library.visiblePhotos`, "No photos in this folder"
when the scan found none and "No photos match the filter" (or "the
search", or "the filter and the search") when they hide them all, with a
**Show All** button that sets the filter to All and clears the search, the batch bar under it while more than one photo is
selected, and under that the thumbnail size strip. Selecting a photo
scrolls it into view.

- **Thumbnail size.** `GridView.columns(for:)` makes one adaptive column
  rule: cells at least `AppSettings.gridThumbnailSize` points wide and at
  most 1.45 times that (rounded), as many as fit. `ThumbnailSizeBar`
  (`ContentView.swift`), the strip under the grid while it has photos,
  shows the count of visible photos and a slider over
  `AppSettings.thumbnailSizes` (120 to 300, `defaultThumbnailSize` 180)
  bound to the same value as the Settings window's slider. The cells'
  image is still the `Thumbnails.pixelSize` (480 px) decode.

- **What is listed.** `Library.scan` (`Library.swift`) enumerates the folder
  and its subfolders with `.skipsHiddenFiles` and `.skipsPackageDescendants`
  and keeps every regular file whose content type conforms to `public.image`
  (JPEG, HEIC, PNG, TIFF and every RAW format ImageIO knows), sorted by path
  with `localizedStandardCompare`; the grid then shows them in the sort order
  (below). Skipping hidden entries is what keeps the
  `.photolab/` sidecar directory out of the grid. The URLs the enumerator
  returns have symlinks resolved (a folder under `/var` comes back under
  `/private/var`); they are the photo ids (`Photo.id`), and every recipe,
  sidecar and selection is keyed by them, never by a URL built elsewhere.
- **The filter bar.** `FilterBar` (`ContentView.swift`) is a segmented
  picker over `PhotoFilter` (`Library.swift`: All, Picks, Unflagged,
  Rejected, and at least one to five stars, `PhotoFilter.stars`) bound to
  `Library.filter`, with the shown count beside it. `Library.visiblePhotos`
  is the folder's photos the filter admits (`PhotoFilter.admits(_:)` over
  each photo's marks), in sort order, and `Library.isVisible` the test for
  one photo; under All it is `Library.photos`. Opening a folder resets the
  filter to All. Changing the filter, or a mark that moves a photo out of
  it, drops hidden photos from the selection and moves a hidden anchor to
  the next visible photo in sort order (else the previous one, else none,
  which also leaves the loupe), so rejecting under Picks shows the next
  candidate.
- **Search** (`Search.swift`). `SearchField`, at the left of `FilterBar`,
  is bound to `Library.searchText`; `Library.search` is that text as a
  `PhotoSearch`, its terms split at whitespace. `Library.visiblePhotos` and
  `Library.isVisible` admit a photo when the filter admits its marks AND
  `PhotoSearch.matches(_:keywords:)` holds: every term is found
  (`PhotoSearch.finds`, a substring ignoring case and diacritics) in the
  photo's name or in one of its keywords (`Library.keywords(for:)`). A
  Photos photo not named yet (`Photo.isNamed` false) matches by its
  keywords only. So Select All, `batchTargets`, the arrows, the filmstrip
  and the counts follow the search as they follow the filter, and changing
  the search, or adding or removing a keyword, reconciles the selection as
  a filter change does. `open` resets the search to empty, and it is not
  part of the remembered view state. **Search Photos** (⌘F, `AppCommand`
  `.search`, Edit menu) leaves the loupe and sets
  `Library.searchFocusRequested`, which `SearchField` turns into focus.
  The field's focus is mirrored into `Library.textEntryActive`, which turns
  off every bare key (see Menus and shortcuts); Esc in the field
  (`onExitCommand`) clears it and drops the focus, Return drops the focus,
  and the field drops it when it leaves the screen.
- **Keywords menu.** `KeywordsMenu`, beside the Sort menu in `FilterBar`,
  lists `Library.keywordTally` (`Keywords.tally` over every photo of the
  open source, shown or not) as "keyword (count)"; picking one sets
  `Library.searchText` to it. Disabled while no photo has a keyword.
- **Sort** (`Sort.swift`). `Library.sort` is a `PhotoSort`: a `SortKey`
  (Capture Date, Name, Rating, Edited) and a direction. `Library.photos`
  is kept in that order (`Library.resort()` over
  `PhotoSort.sorted(_:captureDate:rating:edited:)`, one function for a
  folder and a Photos album), so the grid, `visiblePhotos`, the filmstrip,
  `batchTargets` and the arrows all follow it. Ties go by name ascending
  (Finder's `localizedStandardCompare`), then by id; a photo with no capture
  date sorts after every dated one in either direction. Name compares
  `Photo.name` (the file name), so a folder's subfolders interleave rather
  than group. An unnamed photo (a Photos asset no cell has named yet) sorts
  after every named one in either direction, unnamed ones by id, and loses a
  name tie-break to a named one. A sort by Name never runs over unnamed
  photos: `Library.resort()` keeps the current order and starts
  `Library.nameEveryPhoto()`, one detached pass naming every unnamed photo
  (cancelled by the next `open`), which writes the names in one change and
  sorts once (`Library.sortNow()`). A change re-sorts at once and moves only the order: the
  anchor, the selection and the loupe stay. Under Rating a rating change
  re-sorts (`setRating`), under Edited a photo gaining or losing its edit
  does (`Library.apply`, so undo too). The capture date is
  `Photo.captureDate` when the listing carries one (a Photos asset's
  `creationDate`), else `CaptureDates` reads the file's EXIF
  `DateTimeOriginal` (header only, local time), else its creation date,
  else its modification date, once per photo for the library's lifetime
  (a date the Info section read first is kept, `CaptureDates.remember`).
  The choice is remembered per source kind (`Library.sortKind`: a
  `FolderSource` is `folder`, any other source `photos`) in the library's
  `AppSettings` (`AppSettings.setSort(_:for:)`, under `sort.folder` and
  `sort.photos` as the `PhotoSort.storageKey`), never written by `open`
  itself; the Settings window's two sort rows are the same choice
  (`Library.defaultSort(for:)`, `Library.setDefaultSort(_:for:)`); with nothing
  stored a folder opens `PhotoSort.folderDefault` (Name ascending) and an
  album `PhotoSort.photosDefault` (Capture Date ascending). The choice is
  made in **View › Sort By** or the **Sort** menu at the right of
  `FilterBar`, both built from the command table's `sort` placement.
- **A cell.** `ThumbnailCell` (photo, selected, anchor, edited, marks,
  recipe) draws the thumbnail as the photo's recipe shows it (a spinner
  until it arrives), a ring when selected, heavier for the anchor, a sliders
  badge when `Library.isEdited` says the photo has a saved edit, a flag in
  the top corner (a filled flag for a pick, a cross for a reject, which also
  dims the cell), the stars along the bottom when the photo is rated, and
  the file name. It asks `Thumbnails.shared` from a `.task(id:)` keyed by
  `Thumbnails.Key` (the photo and its recipe): the entry for that key when
  cached, else the plain thumbnail first and the rendered one when it lands
  (`Thumbnails.thumbnail(for:recipe:)`). Because the key carries the recipe,
  a slider release, a batch apply, a sync, an undo or a redo re-keys the
  visible cells and they show the new edit; the badge stays.
- **Thumbnails.** `Thumbnails` (`ImageLoading.swift`) is one `NSCache` of
  `NSImage` at `Thumbnails.pixelSize` on the long side, keyed by
  `Thumbnails.Key`: a `PhotoID` and a recipe, stored by its render identity
  (anything `Recipe.isNeutral` is keyed as `Recipe.neutral`). The plain
  entry is the ImageIO decode, made once and kept as the photo's base; an
  edited entry is that cached base rendered through `Renderer.render` at the
  same size (`Thumbnails.Render`, the one chain, a couple of milliseconds at
  480 px), cached under its own key. A neutral recipe never reaches the
  renderer. Decode and render each run on a detached task with the cell's
  cancellation forwarded in (`withTaskCancellationHandler`) and checked
  inside, so a cell scrolled past before its turn costs nothing and a result
  for a cancelled request is never cached. The decoder and the renderer are
  injected (`Thumbnails.Decoder`, `Thumbnails.Render`,
  `init(decode:render:)`); the app's are `ImageLoading.downsampled` and
  `Renderer.shared`.
- **The decode.** `ImageLoading.thumbnail(from:maxPixelSize:)` asks the
  container for its embedded preview first
  (`ImageLoading.embeddedPreview(from:maxPixelSize:)`,
  `kCGImageSourceCreateThumbnailFromImageIfAbsent`) and accepts it only when
  its long side is at least the requested size: a camera RAW's large
  preview serves a grid cell in a fraction of the full decode's time, while
  an iPhone JPEG's small embedded thumbnail is refused and the image decoded
  (`kCGImageSourceCreateThumbnailFromImageAlways`). `ImageLoading.Source`
  says which happened. The same ImageIO path, at a larger size, is the
  loupe's master (`Renderer.previewMaster`).
- **Selection.** `Library.selection` is the anchor: the photo the loupe
  shows, the one a shift-click extends from, the source of Sync Settings.
  Setting it collapses `Library.selectedIDs` to that one photo;
  `Library.click(_:extending:toggling:)` is the only path that grows the set.
  A cell's single tap reads `NSEvent.modifierFlags` and calls `click` with
  `extending` for **⇧** (every photo between the anchor and it, the anchor
  kept) and `toggling` for **⌘** (add or remove one; the anchor moves to a
  photo added, and off a photo removed); a double tap sets the selection and
  enters the loupe. `Library.selectAll` (**⌘A**) selects every visible photo
  and keeps the anchor, or makes the first visible photo the anchor.
  `Library.collapseSelection` (**Esc** in the grid, **Deselect** in the bar)
  goes back to the anchor alone. `Library.batchTargets` is what a batch acts
  on: the multi-selection in sort order, or the anchor alone when there is
  no multi-selection; the Presets menu, Export, Paste Settings and the flag
  and rating keys all read it. `Library.select(offset:)` moves the anchor by
  one for the arrow keys. Every one of these walks `visiblePhotos`: a click
  on a hidden photo is ignored, a shift-click range spans only visible
  photos, and a photo the filter hides is never a batch target whatever the
  selection set still holds.

Writes: nothing. The thumbnail cache is in memory only.

## Flags and ratings

Culling marks: a flag (pick or reject) and a rating of up to five stars on
each photo, set from the keyboard on whatever is targeted (every selected
photo in the grid, the one photo in the loupe) and read by the filter bar.

- **The keys.** **P** flags a pick, **X** a reject, **U** clears the flag;
  **0** to **5** rate (0 clears), from the keyboard or the Photo menu. They
  are `AppCommand` entries (`HiddenShortcuts` binds the keys) that call `Library.setFlag(_:for:)` and `Library.setRating(_:for:)` with
  `Library.batchTargets`.
- **Clickable.** `FlagStarControl` (`ActionControls.swift`: the loupe panel
  footer for the one photo, the batch bar for `Library.batchTargets`) and
  `PhotoContextMenu` (the grid cell's right-click menu: Pick, Reject, Unflag,
  Rating, Keywords…, Apply Preset, Copy Settings, Paste Settings, Export, Reset Photo,
  and Show in Finder for a folder photo) run the `AppCommand` of the same
  name over a `CommandContext` that pins `targetIDs` and `subjectID`, so a
  key, a menu item and a button share one definition and the same `Library`
  methods; a mark is still not an undo step. `Library.contextTargets(for:)`
  is the rule for a right-click: the batch targets when the photo is one of
  them, that photo alone when it is outside the selection, nothing when the
  filter hides it.
- **The model.** `Marks` (`Sidecar.swift`) is a `Marks.Flag` (`pick` or
  `reject`, or none) and a rating clamped to 0…`Marks.maxRating`;
  `Marks.isEmpty` is no flag and no stars. `Library.marks(for:)` reads a
  photo's marks (`Library.marks` holds only the non-empty ones; `flag(for:)`
  and `rating(for:)` are the parts). A mark is not an edit: it is not an
  undo step, it never enters a `Recipe`, a `Preset`, Copy Settings or a sync
  mask, and Reset leaves it alone. After a flag or rating changes the
  selection is reconciled against the filter as above.
- **Where it shows.** The cell's flag corner and stars, the loupe subtitle
  ("· Pick", "· Rejected", the stars), and the filter bar's counts.

Writes: the photo's sidecar. Marks ride beside the recipe as two optional
keys, `flag` and `rating`, written only when set, so a file written before
them decodes unchanged; the file is removed only when the recipe is the
default and the photo is unmarked (and has no keywords, see Keywords), so a flag on an unedited photo keeps its
sidecar (`SidecarStore.save(_:marks:keywords:for:name:now:)`), and a recipe-only write
keeps whatever marks the file already held.

## Keywords

Words on a photo, kept with the marks and like them not an edit.

- **Editing.** **Keywords…** (`AppCommand` `.keywords`, **⌘K**, Photo
  menu; the item reads **Keywords for n Photos…** over more than one) is
  `Library.requestKeywords(for:)` over the command's targets
  (`Library.batchTargets`, or a right-click's `contextTargets`): it sets
  `Library.keywordsRequest`, a `KeywordsRequest`, which `ContentView`
  presents as `KeywordsSheet` (`Keywords.swift`). The batch bar's
  **Keywords…** and `PhotoContextMenu`'s item reach the same call. The sheet's field
  takes comma-separated keywords (`Keywords.parse`); **Add** or Return
  calls `Library.addKeywords(_:to:)` on every target. Below it, each
  keyword on any target (`Keywords.tally`) with "all" or "n of N"
  (`KeywordsSheet.share(_:of:)`) and a remove button,
  `Library.removeKeyword(_:from:)`. The field lives in a sheet, so typing
  never reaches `HiddenShortcuts`; **Done** (or Esc) closes it.
- **The model.** `Library.keywords` holds each photo's non-empty list,
  read by `Library.keywords(for:)`. Every list is
  `Keywords.normalized`: trimmed, empty ones dropped, de-duplicated ignoring
  case (the first spelling kept, so adding "SUNSET" to a photo with "Sunset"
  changes nothing), sorted ignoring case. A keyword is not an undo step,
  never enters a `Recipe`, a `Preset`, Copy Settings or a sync mask, and
  Reset leaves it.
- **Where it shows.** A Keywords row in the loupe's Info section (see
  Loupe, Info), the grid's search and its Keywords menu (see Grid, Search),
  and the IPTC Keywords of an export with Keep camera info on (see Export).

Writes: the photo's sidecar, through the same `Library.persist` as the
marks. Keywords are one optional key, `keywords`, written only when the list
is not empty, so a file written before them decodes unchanged and a photo
without keywords writes the file it always did; they do not raise the format
version (`Sidecar.version(for:)` reads the recipe alone). The file is kept
while the photo has a keyword, whatever its recipe and marks, and
`SidecarStore.save(_:for:name:now:)` (recipe only) keeps the keywords the
file held. `SidecarStore.loadAll(for:)` returns them on open.

## Collections

A collection (`PhotoCollection`, `Collections.swift`) is a saved set of
folder photos from any number of folders: an `id`, a `name`, `created` and
`members`, each a `PhotoCollection.Member`, the photo's file (the id
`Library.scan` gave it) and its `root`, the folder whose `.photolab/` holds
its sidecar (the open `FolderSource`'s folder when it was added).
`CollectionStore` keeps one `<id>.json` per collection, written atomically,
in an injected directory: the app's is `CollectionStore.app`,
`~/Library/Application Support/PhotoLab/Collections/`, passed as
`Library(collections:)` by `PhotoLabApp`; a library made without one
(`Library.collectionStore` nil) offers no collection command. A file this
build cannot decode (damaged, or a `version` above
`PhotoCollection.currentVersion`) is left out of `CollectionStore.loadAll`
and never written over by a load.

- **Add to Collection** (Photo menu, `AddToCollectionMenu`): each saved
  collection (`Library.savedCollections`, re-read when
  `Library.collectionsRevision` changes) adds the batch targets
  (`Library.addToCollection(_:ids:)`, each photo once), then **New
  Collection…** (`AppCommand` `newCollection`, the `collection` placement)
  raises `Library.newCollectionRequest`, whose sheet (`NewCollectionSheet`)
  asks for a name and calls `Library.createCollection(named:adding:)`; an
  empty name is refused (`CollectionError.emptyName`, shown from
  `Library.collectionError`). The submenu is enabled while
  `Library.canAddToCollection`: a folder or a collection is open. A Photos
  album's assets cannot be added this round. `Library.collectionMembers(for:)`
  makes each member with the open folder as its root, or keeps a member's
  own root when adding from one collection to another.
- **Opening one** (File › Open Collection, `OpenCollectionMenu`; the
  Welcome view's `CollectionList`; Open Recent; the launch reopen):
  `Library.open(collection:)` opens a `CollectionSource` through
  `Library.open(_:)` and remembers it (`LastSource.collection`, a
  `RecentSource` of kind `collection`). `CollectionSource.photos()` lists
  the members whose file exists; the others (`CollectionSource.missing`)
  are counted in `Library.missingMembers` and the window's subtitle ("2
  missing"), never removed from the collection. Thumbnails and originals
  are read as a folder's are. A collection sorts like a folder
  (`Library.sortKind` is `folder`).
- **Edits go to each member's own folder.** `CollectionSource.sidecars(for:)`
  is `SidecarStore(folder: member.root)`, and `Library.persist` writes every
  photo through `PhotoSource.sidecars(for:)`; at open,
  `CollectionSource.loadSidecars(for:)` reads each root's store for its own
  members. So an edit, flag, rating or keyword made in a collection is the
  very sidecar its folder reads, and one made in the folder shows in the
  collection.
- **Remove from Collection** (Photo menu, enabled while a collection is
  open and something is targeted) is `Library.removeFromCollection(_:)`:
  the members leave the collection's file and the grid
  (`Library.replaceCollection`, which also drops them from the selection
  and every map); no photo or sidecar is touched.
- **Delete Collection…** (File menu, the open collection; or the context
  menu of a Welcome list entry) raises `Library.deleteCollectionRequest`;
  the window's alert confirms, then `Library.deleteCollection(_:)` removes
  only `<id>.json` (`CollectionStore.remove`), forgets its Open Recent entry
  (`Library.forgetRecent`) and, when it is the open source, returns to the
  Welcome view (`Library.closeSource`).

Writes: `<id>.json` under the collections directory; a member's edit goes
to its own folder's `.photolab/` as any folder edit does.

## Batch bar

`BatchBar` (`ContentView.swift`) sits under the grid while
`Library.selectedIDs` holds more than one photo: "n selected · anchor
<name>", then five controls.

- **Sync Settings…** is `Library.requestSync`: the anchor's recipe onto the
  other selected photos. It builds a `SyncRequest` (`Library.swift`: the
  source recipe, its photo's name, the target ids and the mask to open with,
  `Library.lastSyncMask`) and sets `Library.syncRequest`, which
  `ContentView` presents as a `SyncSheet`.
- **Apply Preset** is a menu of `PresetLibrary.presets`; a choice calls
  `Library.apply(_:mask:to:)` with `batchTargets` (the preset's look over
  each photo's own crop and rotation, one batch).
- **Keywords…** is `Library.requestKeywords(for:)` over `batchTargets`
  (see Keywords).
- **Export…** is `ExportQueue.requestExport(_:)` with
  `Library.exportItems(for:)` over `batchTargets` (see Export).
- **Deselect** is `Library.collapseSelection`.

`SyncSheet(request:)` (`ContentView.swift`) is the Sync Settings and Paste
Settings sheet: "From <source> onto n photos", the shortcuts **All**,
**None**, **Look** and **Grade** (`SyncMask.everything`, `SyncMask.nothing`,
`SyncMask.look`, `SyncMask.grade` in `Batch.swift`; only All checks
**Masks**), then one
`DisclosureGroup` per `AdjustmentKind.Section` with a checkbox for the
section and, opened, one per adjustment; the HSL section shows its three
channels (`AdjustmentKind.HSLChannel`) rather than twenty-four bands; then
**Masks** (`SyncMask.masks`): checked, each target's local adjustments are
replaced by the source's whole list, unchecked each keeps its own. A
checkbox over a list of kinds reads `SyncMask.state(of:)`: on when all are in
the mask, off when none, "(some)" when mixed. The summary line names the
mask ("… and the masks" when Masks is checked by hand). **Sync n Photos**
(also **Return**, enabled while any adjustment or Masks is checked) stores the mask in
`Library.lastSyncMask` and calls `Library.sync(_:mask:to:)`, which runs
`Recipe.syncing(_:from:)` per target through `Library.setRecipe` with one
batch tag, so the whole sync is one undo step. The same menu item exists in
the Edit menu, enabled from two selected photos.

**Copy Settings / Paste Settings…** (**⇧⌘C** / **⇧⌘V**, Edit menu, in
`PhotoLabApp.swift`): `Library.copySettings(from:)` remembers the selected
photo's recipe and name in `Library.copiedSettings`; `Library.requestPaste`
puts up the same `SyncSheet` with that recipe as the source and
`batchTargets` as the targets, so a look carries between folders.

Writes: one sidecar per photo the sync changed, each through `setRecipe`.
Nothing else; the copied settings live in memory.

## Map

`PhotoMapView` (`PhotoMapView.swift`), in the grid's place while
`Library.showMap` is on (View › Map, **⌥⌘M**, or the toolbar picker's Map
segment): a SwiftUI `Map` (MapKit; Apple's tiles over the network, no key
and no entitlement, the app is not sandboxed; offline the pins draw on a
blank grid) of `Library.visiblePhotos` that have a position.

- **Positions.** `Library.locations`, a `PhotoLocations` (`PhotoMap.swift`):
  `PhotoLocations.start(_:store:)` runs when the map opens over every photo
  of the source. A Photos asset's position is `Photo.location`, from
  `PHAsset.location` in the listing (`PhotosAsset.location`), never a read;
  a photo whose `PhotoInfo` is already cached in `Library.photoInfo` takes
  its GPS from there; every other folder photo is read in one background
  pass, a file at a time, through `PhotoInfoStore.info(for:file:)`, so the
  Info section and the map share each header read. `PhotoLocations.reading`
  is the pass's progress ("Reading locations n of N" in the footer).
  Leaving the map (`showMap` off, including the loupe opening) is
  `PhotoLocations.cancel()`, which stops the pass after the file in flight
  and keeps what it read; `Library.open` is `PhotoLocations.reset()`.
- **Pins.** `MapPins.group(_:cellDegrees:)` buckets the located photos into
  square cells of `MapPins.cellDegrees(latitudeDelta:longitudeDelta:)`, the
  visible span's wider side over `MapPins.cellsAcross` (12), re-read after
  every camera move (`onMapCameraChange`): one `Annotation` per non-empty
  cell at its photos' mean position, `MapPinLabel` drawing the first photo's
  thumbnail (with its edit, `Thumbnails.thumbnail(for:recipe:)`), the count
  when more than one, an accent border when any of them is selected.
- **Framing.** `MapPins.region(fitting:)`: the points' extent times
  `MapPins.padding` (1.3), at least `MapPins.minimumSpanMeters` (1 km) each
  way, so one photo frames its neighbourhood; set when the map appears and
  again when the pass finishes.
- **Clicks.** A click on a pin is `Library.clickPin(_:)`, a double-click
  `Library.openPin(_:)`: both `Library.select(_:)` the pin's listed,
  visible photos with the first as the anchor; the double-click then sets
  `Library.loupe`.
- **Footer and empty state.** The footer says
  `PhotoLocations.summary(located:of:)` ("n of N photos have a location",
  over the visible photos) once no pass runs; with no located photo and no
  pass, the map gives way to "None of these photos has a location".
- **Not remembered.** `showMap` is not in `SourceViewState` and
  `Library.open` turns it off, so a source opens on the grid or the loupe.

Writes: nothing.

## Loupe

`LoupeView(photo:)` (`ContentView.swift`): the rendered photo on the left,
`AdjustmentsPanel` on the right, one `PreviewModel` shared between them.

- **The frame.** `PreviewCanvas` (`ContentView.swift`) measures its view and
  asks for a frame at the view's long side in pixels (minus the padding,
  times the display scale). When the photo changes it calls
  `PreviewModel.load(_:)`; when the recipe or its own pixel size changes it
  calls `PreviewModel.request(url:recipe:maxPixelSize:)`. Until the first
  frame of a photo arrives it shows the grid's cached thumbnail (the edited
  one when the grid has rendered it, else the plain one) under a spinner.
  A photo whose embedded preview is at least
  `PreviewModel.firstFrameMinPixelSize` on its long side and smaller than
  the master (a camera RAW's) gets that preview as its first frame, the
  recipe rendered over it (`PreviewModel.imageIsFirstFrame`), and the
  decoded master's frame replaces it in place (Architecture, The loupe).
  The crop's aspect row waits for the master (`PreviewModel.masterSize`
  is zero until then).
  A Photos asset's file has to be fetched first
  (`Library.originalFile(for:)`, Architecture 2): `LoupeView` keeps an
  `OriginalFetch`, and the canvas shows the thumbnail under
  "Downloading original…" while it is `fetching` (an iCloud-only original
  downloads here, once; the copy lands in `~/Library/Caches/PhotoLab/originals/`)
  and "Original not available" with the reason when it `failed` (offline,
  or the asset gone). `PreviewModel` (`Preview.swift`) decodes the master once at
  `PreviewModel.masterPixelSize` through `Renderer.previewMaster`, renders
  through `Renderer.render` off the main thread, and coalesces requests
  (latest wins, at most one render in flight). **G** or **Esc** go back
  to the grid (a click on the photo zooms, below).
- **1:1 and pan.** `Library.loupeZoom` is a `PreviewZoom`, fit or 1:1
  around a centre; `PreviewCanvas` hands it to `PreviewModel.setZoom(_:)`
  and passes its pane in pixels as `viewPixelSize` on every request (the
  window's size). **Z** (`Library.toggleZoom()`) goes to 1:1 at the middle
  of the photo or back to fit. A click on the photo at fit zooms to 1:1 at
  the pixel clicked (`ZoomMath.center(forClick:frame:pane:)` through the
  fit frame's place in the padded pane; a click on the black around it
  does nothing); a click at 1:1 goes back to fit. A drag at 1:1 pans: the
  picture follows the pointer (`ZoomMath.pan`, view points times the
  display scale in frame pixels), the centre held so the window never
  leaves the frame (`ZoomMath.clamp`). Under 3 points of movement a press
  is a click. Until the first window lands (the full-resolution decode) the
  fit frame stays up under a "1:1" badge with a spinner. A photo whose
  rendered frame fits the view whole goes back to fit by itself
  (`ZoomMath.fits`; 1:1 would only shrink it). The arrows (even at either
  end), any other photo change (`Library.selection`) and leaving the loupe
  return to fit; the zoom is never remembered. In compare mode both halves
  show the same region (`PreviewModel.zoomBeforeImage`, the neutral
  window cut at the After window's region) and either half takes the
  click and the drag. The clipping overlay paints on the window as on the
  fit frame.
  The click used to be a double-click back to the grid: SwiftUI can only
  tell a click from a double-click by waiting out the double-click
  interval, so keeping both would delay every zoom click. **G** and **Esc**
  were already the way back.
- **Crop mode.** **R** (Photo › **Crop**, or **Crop on Photo** at the top
  of the Crop & Rotate section, the same `AppCommand`) toggles
  `Library.cropMode`, in the loupe only. Entering returns the zoom to fit
  and ends compare; **R** again, **Esc** (before it leaves the loupe),
  **Z**, **Y** and leaving the loupe end it; a photo change keeps it.
  While it is on, `PreviewCanvas` renders `CropMath.uncropped(_:)` (the
  recipe without its four crop edges: the rotated frame whole, since the
  chain rotates before it crops) and `CropOverlay` draws the crop over the
  fit frame: the cut-away part dimmed, the kept part outlined with its
  thirds, a handle on each edge and each corner. It waits for a frame
  rendered that way (`PreviewModel.imageRecipe`, `CropMath.isCropFrame`)
  and is hidden at 1:1 and while Show Original is on; the zoom click and
  the pan are off. A handle's drag is `Library.dragCrop(_:by:fit:for:)`:
  the translation in view points over the fit rect's size
  (`ZoomMath.fitRect`, so the display scale never enters) moves the
  handle's edges (`CropMath.drag`, a corner two), each clamped at the
  image's edge and at the slider's 40% (`CropMath.clamp`, which keeps
  `CropMath.minSize` of the frame), written as percent and enabled
  (`CropMath.write`, only the handle's own edges) through
  `Library.setRecipe`, inside `beginEdit` … `endEdit`: the sliders follow
  live, and mouse-up (`Library.endCropDrag(_:)`) makes the drag one undo
  step and one sidecar write. The histogram shows the uncropped frame
  while crop mode is on.
- **Aspect lock.** `Library.cropAspect` (a `CropMath.Aspect`: a `Preset`,
  Original, Free, 1:1, 4:5, 3:2 or 16:9, and `swapped`) is tool state,
  never in a recipe or remembered; Free is the default. The Crop & Rotate
  section's **Aspect** menu calls `Library.setCropAspect(_:frame:for:)` and
  its swap button `Library.swapCropAspect(frame:for:)` (disabled for Free
  and 1:1, `Aspect.canSwap`), with the decoded master's size
  (`PreviewModel.masterSize`) as the frame, since rotate keeps the frame's
  aspect. A locked pick refits the photo's crop through `setRecipe` (one
  undo step, one sidecar write): `CropMath.refit` is the largest rectangle
  of the ratio around the crop's centre inside the image and the sliders'
  40%, or around the frame's centre when that centre leaves none; a crop
  that already holds the ratio is not touched. Under a lock `CropOverlay`
  shows the corners alone (`CropMath.handles(locked:)`) and
  `Library.dragCrop` passes the ratio of the fit frame
  (`Aspect.normalized(frame:)`) to `CropMath.drag(_:from:by:fit:ratio:)`:
  the opposite corner stays, the size follows whichever axis the pointer
  moved further, and both axes are bounded together so the ratio holds; a
  crop that does not hold it (a slider moved it, another photo) is
  refitted first, and every edge that moved is written
  (`CropMath.edgesToWrite`).
- **Straighten.** The section's **Straighten** toggle sets
  `Library.straightening`, which enters crop mode; leaving crop mode,
  **Esc** (before it leaves crop mode) or the line itself clears it. While
  it is on, `CropOverlay` hides the handles and the fit frame takes a drag,
  drawn as a dashed line; mouse-up calls
  `Library.straighten(from:to:for:)`, which sets rotate to
  `StraightenMath.rotate(levelling:_:current:)` through `setRecipe` (one
  undo step, one write, the crop kept). The angle is read in view points,
  y down, folded so a line has no direction; within 45° of horizontal the
  line is levelled, steeper it is made upright (`StraightenMath.tilt`); the
  correction is taken off the current rotate (the frame shown is already
  turned by it) and held in the slider's ±45°. A press under
  `StraightenMath.minLength` points changes nothing.
- **White-balance eyedropper.** **W** (Photo › White Balance Picker,
  `AppCommand.Name.whiteBalance`) or the Color section's **White Balance**
  toggle sets `Library.whiteBalancePicking`: tool state, never in a recipe
  or remembered, kept across photo changes. Arming it leaves crop mode
  and ends compare; entering crop mode or compare, **Esc** (first, before
  straighten, crop mode or the loupe), leaving the loupe and a balanced
  pick clear it. While it is on, the canvas shows a crosshair cursor over
  the photo and a hint capsule, and `PreviewCanvas`'s click samples
  instead of zooming (a drag at 1:1 still pans; a click off the photo, or
  while Show Original is on, does nothing). The click is mapped to a point
  normalised in the rendered frame: at fit by `ZoomMath.center(forClick:)`
  over the fit frame, at 1:1 by `ZoomMath.point(forClick:region:frame:pane:displayScale:)`
  over `PreviewModel.zoomRegion` and `zoomFrameSize` (the pixel clicked,
  at its centre), so both land on the same spot. `Library.pickWhiteBalance(at:for:)`
  decodes the master off the main thread (`Renderer.previewMaster` at
  `PreviewModel.masterPixelSize`; a RAW's master, never its first frame),
  renders the `WhiteBalance.patchSize` (5×5) patch there through
  `Renderer.render` with a `Renderer.Region` over `WhiteBalance.base` (the
  recipe with every kind from temperature on at neutral and no masks: the
  white-balance stage's own input), averages it in sRGB (`WhiteBalance.meanSRGB`) and
  hands it to `WhiteBalance.neutralising`. `Library.applyWhiteBalance`
  sets temperature and tint (switched on) through `setRecipe`: one undo
  step and one sidecar write, and the tool disarms. A patch with any
  channel at or above `WhiteBalance.clippedLevel` (0.98) or below
  `WhiteBalance.darkLevel` (0.02) is refused: no recipe change,
  `Library.whiteBalanceNote` is shown in the hint and under the button,
  and the tool stays armed. A second click while one is read
  (`Library.whiteBalanceReading`) is ignored.
- **Before.** `BeforeButton(isPressed:)` (`ContentView.swift`) is a
  press-and-hold bound to `Library.showBefore`; `\` toggles the same flag.
  While it is on, `PreviewCanvas` substitutes `Recipe.neutral` for the
  photo's recipe and shows a "Before" badge; nothing else changes, and the
  recipe on disk is untouched.
- **Before / After side by side.** **Y** or the toolbar's **Before / After**
  toggle flips `Library.compare` (off again whenever a source opens).
  `PreviewCanvas` then splits into two equal halves, Before on the left
  (`PreviewModel.beforeImage`, the neutral render, the plain thumbnail
  until it lands) and After on the right (the recipe), each labelled and
  each rendered at one half's pixel size from the one master
  (`PreviewModel.setCompare(_:)`). Holding **Before** or `\` still works
  and shows the original in the After half too. From the grid, **Y** opens
  the loupe on the selection in compare mode.
- **Moving through the folder.** **←** and **→** are `Library.select(offset:)`,
  which walks the filtered list (`Library.visiblePhotos`), so the loupe
  never lands on a hidden photo and "n of N" counts the visible ones;
  **Esc** leaves the loupe; **Return** and **E** enter it; **G** goes to the grid
  (see Menus and shortcuts).
- **Save to Photos.** For a photo of a Photos album the toolbar gains
  **Save to Photos** (the File menu has it too), enabled by
  `Library.canSaveToPhotos` (the photo is edited, no save running); it runs
  `Library.saveToPhotos()` (Architecture 2, Adjustment data), and the
  panel's last line says "Saving to Photos…", "Saved to Photos" or why it
  could not (`Library.photosSave`). Photos may ask to allow the change.
- **A recipe from Photos.** Each time a photo opens, `LoupeView` also runs
  `Library.recoverRecipe(for:)`: a Photos asset with no sidecar whose edit
  in Photos is PhotoLab's gets that recipe back (no undo step), and its
  sidecar is written.

Writes: nothing to the photo. The loupe reads the recipe; for a Photos
asset it fills the originals cache (Architecture 2), writes the sidecar of
a recipe recovered from Photos, and Save to Photos writes the asset's edit
in the library (the rendered JPEG and PhotoLab's adjustment data).

## Adjustments panel

`AdjustmentsPanel(photo:preview:)` (`ContentView.swift`): the histogram, the
Info section (closed by default), the History section (closed by default),
the Presets strip, the Masks section, one `DisclosureGroup` per `AdjustmentKind.Section` in
declaration order (Basic open by default), each with a dot when any of its
kinds is not a no-op (`Adjustment.isNoop`), then a footer with Before, undo,
redo, Reset, the render time and any sidecar error.

- **Filmstrip** (`Filmstrip.swift`). A lazy horizontal strip under the loupe
  canvas over `Library.visiblePhotos`, so a filter shapes it as it shapes the
  grid. Each cell shows what a grid cell does (thumbnail, flag, stars, edited
  badge) and keys the grid's one cache with `Thumbnails.Key(photo, recipe)`,
  never a second cache. The anchor is ringed and scrolled into view; a click
  goes through `Library.click` with the grid's `⇧` and `⌘` rules, so a batch
  can be built from the loupe. **View › Filmstrip** (`F`, an `AppCommand`)
  shows or hides it; `Library.showFilmstrip` is `AppSettings.showFilmstrip`,
  remembered under `showFilmstrip`, shown by default. The item
  list and the click live in `Filmstrip` (`FilmstripItem`), tested apart
  from the view (`FilmstripTests`).
- **Info** (`Info.swift`). `InfoSection` is a `DisclosureGroup` under the
  histogram, open while `Library.showInfo` is on (**View › Info**, `⌘I`, an
  `AppCommand` that from the grid also opens the loupe; `Library.showInfo`
  is `AppSettings.showInfo`, remembered under `showInfo`, closed by
  default). It shows
  `PhotoInfo.rows(edited:keywords:)`, one row per present field in `PhotoInfo.labels`
  order (Camera, Lens, Focal Length, Aperture, Shutter, ISO, Dimensions,
  File, Size, Folder, Captured, GPS, Keywords, Edited): a missing or empty field has no
  row, Keywords is `Library.keywords(for:)` joined with commas, and Edited (`Library.isEdited`) is always there. `PhotoInfo.read`
  reads a file's header once (`CaptureDates.properties(of:)`, never the
  pixels) plus its size, through `PhotoInfoStore` (`Library.photoInfo`) off
  the main thread, once per photo for the library's lifetime. The capture
  date is the sort's (`CaptureDates.date(properties:url:)`, and a date the
  sort already has wins; the store hands its own to
  `CaptureDates.remember`, so a later Capture Date sort reads nothing). A
  Photos asset shows its name (no File row while it is unnamed; the row
  follows `Photo.name` when the name lands) and `creationDate` at once, then the
  header fields of the original the loupe fetched, with no Folder row (that
  copy is the originals cache). Writes nothing.
- **History** (`History.swift`). `HistoryList` is a `DisclosureGroup` under
  Info, open while `Library.showHistory` is on (`AppSettings.showHistory`,
  remembered under `showHistory`, closed by default). It lists
  `Library.historyEntries(for:)` newest on top: one `HistoryEntry` per
  undo and redo step of the photo, the current row tinted, the undone rows
  (`isUndone`) greyed above it, and the Original (position 0) at the
  bottom; with no step it says so. Labels are derived, never stored:
  `HistoryLabel.describe(from:to:batch:)` diffs the recipes on either side
  of the step by `AdjustmentKind` — to the default recipe is "Reset"; one
  kind is its name (`AccessibleName.adjustment`) and new value
  (`AdjustmentKind.format`), or "on" / "off" when only its switch moved; any
  geometry kind is "Crop"; two names are both, more are the first two in
  chain order and "+N more"; a change to `Recipe.masks` (an add, a
  delete, a mask's slider or switch) adds the one name "Mask" after the
  kinds; a change outside the adjustments and the masks is "Edit";
  a batch-tagged step (`Library.sync`: Sync Settings, a preset on many
  photos, Auto) is prefixed "Sync: ". A slider drag shows live as the
  newest row. A click is `Library.jumpToHistory(_:for:)`, which closes an
  open drag and then runs undo or redo on that photo until the row is
  current, so it moves exactly what `⌘Z` / `⇧⌘Z` would (a batch step its
  whole batch) and writes each step's sidecar as they do; the next edit
  drops the greyed rows (`EditHistory.push` clears redo). The history is in
  memory only, reset by `Library.open`, at most `Library.maxUndoDepth`
  steps (past that the bottom row is the oldest step kept, not the opened
  recipe).
- **Masks** (`MasksPanel.swift`). `MasksSection(photo:)` is a
  `DisclosureGroup` after the Presets strip (open, with a dot while the
  photo has a mask). **Linear**, **Radial** and **Brush** run the Photo
  menu's commands (**M**, **⇧M**, **K**) through
  `Library.addMask(_:for:)`: one mask at the end of `Recipe.masks` at its
  `MaskKind.defaultShape` (no on-canvas handles yet: a linear from the top
  edge to 40% down, `(0.5, 0)` to `(0.5, 0.4)`; a radial at `(1/3, 1/3)`
  with radii 0.2 × 0.15 of the long side, feather 0.5; an empty brush),
  selected, crop mode and the eyedropper put down; one undo step and one
  sidecar write. A new mask has every adjustment at neutral, so it renders
  as nothing until a slider moves. The list names each mask by kind and
  order, "Linear 1", "Radial 1", "Linear 2" (`MaskKind.names(of:)`,
  derived, so a delete renumbers); a click selects it, again deselects.
  `Library.selectedMask` is tool state: never in a recipe, cleared when the
  photo changes and whenever the photo's recipe stops holding it (an undo
  of its add, a delete, a reset, a sync), by `Library.apply`. The selected
  mask shows its switch (`LocalMask.enabled`), **Invert**, **Duplicate**
  (`Library.duplicateMask(_:for:)`: a copy with a new id right after it,
  selected), **Delete** (`Library.deleteMask(_:for:)`) and one slider per
  `LocalMask.kinds` (`MaskSliderRow`: the name, double-click to reset, the
  value, the slider over `AdjustmentKind.range`); each switch and button is
  one `Library.updateMask` / `setRecipe` step, and each slider goes
  through `MaskSliderEdit`, which calls `beginEdit` on mouse-down and
  `endEdit` on mouse-up, so a drag is one undo step and one sidecar write.
  **Brush** (`K`) adds an empty brush mask and arms it
  (`Library.maskBrushArmed`: arming leaves crop mode, ends compare and puts
  the eyedropper down; `K` again, `Esc`, another mask selected, crop mode,
  compare, the eyedropper and leaving the loupe disarm it). Painting on the
  photo is not built yet: an armed brush does nothing on a drag.
  **Show Overlay** is **View › Show Mask Overlay** (**O**,
  `Library.showMaskOverlay`, off by default and not remembered): the loupe
  tints the selected mask red at half strength (`MaskTint.compose`, the
  mask drawn and placed by `MaskRender.placedImage` over the same scaled
  source extent the render used, so the tint sits on the pixels the mask
  changes, under any rotate and crop and in the 1:1 window), composed by
  `PreviewModel` after the clipping overlay in the same hop
  (`PreviewModel.setMaskOverlay(_:)` renders the newest request again).
  Compare's Before, thumbnails, the preset strip and exports never carry
  it.
- **Histogram and clipping.** `HistogramView` (`HistogramView.swift`) at the
  top of the panel draws `PreviewModel.histogram`, a `Histogram`
  (`Histogram.swift`) of the latest rendered frame: 256 bins of red, green,
  blue and luminance, computed off the main thread after each frame. Its two
  corner triangles are the clipping warnings, lit when more than a tenth of
  a percent of the frame's pixels are blown (any channel ≥ 254,
  `Histogram.highlightLevel`) or crushed (any channel ≤ 1,
  `Histogram.shadowLevel`). Either triangle, or **J**, toggles
  `Library.showClipping`: the loupe paints the blown pixels red and the
  crushed ones blue (`ClippingOverlay.compose(over:context:)`, one stage over
  the finished frame, so the overlay marks exactly the pixels the triangles
  count); `PreviewModel.setClipping(_:)` re-composes the kept frame without
  a render. Nothing of this touches the recipe.

- **A row.** `AdjustmentRow(kind:recipe:onEditingChanged:)` is one
  adjustment: a checkbox bound to `Recipe.setEnabled(_:_:)` (off dims the
  row and disables the slider; the value is kept), the label
  (`AdjustmentKind.label`; double-click calls `Recipe.reset(_:)`), the
  formatted value (`AdjustmentKind.format`), and a slider over
  `AdjustmentKind.range` bound to `Recipe.set(_:to:)`. The panel's recipe
  binding reads `Library.recipe(for:)` and writes `Library.setRecipe(_:for:)`,
  so every checkbox and slider change is the one writer. The slider's
  editing-changed callback calls `Library.beginEdit(_:)` on mouse-down and
  `Library.endEdit(_:)` on mouse-up, so a drag is one undo step and one
  sidecar write.
- **Sections.** `AdjustmentKind.Section` (`Adjustments.swift`) gives each
  kind its section (`section`) and each section its `title` and `kinds`.
  Basic opens with **Auto** (the **Auto Tone** command, `⌘U`, on this
  photo; a small spinner while `Library.autoToning`; see Auto below).
  Color opens with the **White Balance** eyedropper toggle (the **White
  Balance Picker** command, **W**; see Loupe, White-balance eyedropper),
  with the last refusal under it.
  Crop & Rotate opens with **Crop on Photo** / **Done Cropping**, which
  runs the **Crop** command (see Loupe, Crop mode), then the **Aspect**
  menu, its swap button and the **Straighten** toggle (see Loupe, Aspect
  lock and Straighten).
  The HSL section is different: a segmented `AdjustmentKind.HSLChannel`
  picker (hue, saturation, luminance), then one row per
  `AdjustmentKind.HSLBand` for that channel, the kind looked up with
  `AdjustmentKind.hsl(_:_:)`, so eight rows stand in for twenty-four.
  Color Grading (`AdjustmentKind.Section.grading`, between HSL and Detail,
  `AdjustmentsPanel.gradingSection`) opens on three `GradeWheel`s side by
  side, one per `AdjustmentKind.GradeRange` (captioned Shadows, Midtones,
  Highlights), then the three luminance rows and Balance, then a **Hue &
  Saturation** disclosure (closed by default) with the six hue (`format`
  in degrees, 0…360) and saturation (0…100) rows for exact values. A
  wheel is a hue disc (an `AngularGradient` listed from 360° down so the
  hue runs counter-clockwise, white toward the centre) with a puck at the
  range's hue (angle, red at 3 o'clock) and saturation (radius), placed
  by `GradeWheelMath.point(for:side:)`. Dragging on it is a
  `GradeWheelDrag`: the first move calls `Library.beginEdit`, every move
  maps the pointer through `GradeWheelMath.puck(at:side:hueAtCentre:)`
  (clamped to 100 at the rim) and sets the range's hue and saturation
  through `Library.setRecipe`, mouse-up calls `Library.endEdit`, so a
  drag is one undo step and one sidecar write. A double-click is
  `GradeWheelDrag.reset` (`GradeWheelMath.resetting`: the range's hue and
  saturation to 0, its luminance kept), one step. A wheel whose hue or
  saturation is unchecked is dimmed and takes no drag. The Sync sheet
  lists the ten kinds as checkboxes under Color Grading.
- **Footer.** Undo and redo call `Library.undo()` and `Library.redo()`,
  enabled by `Library.canUndo` / `Library.canRedo`. **Reset** is
  `Library.resetRecipe(for:)` (one undo step; the sidecar is removed unless
  the photo carries a flag or rating, which stay), disabled while the recipe
  `isDefault`. The render line is
  `PreviewModel.renderMilliseconds` with the frame's pixel size and
  `PreviewModel.masterSize` (or "of the embedded preview" while
  `PreviewModel.imageIsFirstFrame`). `Library.sidecarError`, when set, is the last
  sidecar write or read that failed (a read-only folder, an unreadable
  file).

- **Auto** (`AutoTone.swift`, `Library.autoTone(_:)`). For each photo its
  original (`Library.originalFile(for:)`) is decoded off the main thread at
  `PreviewModel.masterPixelSize` (`Renderer.previewMaster`, the loupe's own
  master decode: a camera RAW is read from its decoded master, never from
  the embedded first frame the loupe shows while that decodes; Auto waits
  for its own decode). The recipe with the six Basic kinds at neutral
  (`AutoTone.base`) is rendered over it at `AutoTone.analysisPixelSize`
  through `Renderer.render` and counted by `Histogram.compute`, and
  `AutoTone.values(from:)`, a pure function of that `Histogram`, gives
  exposure, contrast, highlights, shadows, whites and blacks. Because the
  measured frame never carries the six, a second Auto reads the same
  histogram and sets the same values (`Library.sync` then skips the photo).
  `AutoTone.base` keeps the photo's masks, so Auto measures the picture with
  its local adjustments rendered; Auto never changes them, so that holds.
  The values go on through `Library.sync(_:mask:)` with `AutoTone.mask`:
  one batch tag for every photo given, so one `⌘Z` takes the lot back, and
  one sidecar write per photo changed. The command (`AppCommand.Name.autoTone`)
  acts on `CommandContext.targets`, so in the grid it is every selected
  photo, each with its own values; it is disabled while `Library.autoToning`.

Writes: the photo's sidecar, through `setRecipe`, once per change and once
per drag; the default recipe removes it.

## Presets strip and menu

`PresetStrip(photo:)` (`PresetBrowser.swift`) is the strip at the top of the
panel: a horizontal row of live thumbnails, **Save…**, a `…` menu and the
last preset error.

- **Thumbnails.** `PresetThumbnails` (`PresetBrowser.swift`) decodes the
  current photo once at `PresetThumbnails.masterPixelSize` and renders every
  preset over it at `PresetThumbnails.cellPixelSize` through the one
  renderer (`PresetThumbnails.render(master:presets:base:pixelSize:renderer:)`,
  each cell `Preset.apply(to:)` over the photo's current recipe). Requests
  coalesce like the loupe's. The strip re-requests when the photo changes,
  when the preset list changes, when the photo's geometry changes
  (`geometryKey`: rotate and the crop edges are the only kinds an apply
  keeps) and when its local adjustments change (`masksKey`: an apply keeps
  the photo's masks, and they render), the only edits that change a
  preset's thumbnail.
- **A cell.** Click applies: `Library.apply(_:to:)`, one undo step, the
  sidecar written. The ring is heavier on the preset the photo already
  shows (`Preset.matches(_:)`). The context menu has **Apply**, **Update
  with Current Settings** (`PresetLibrary.save(_:as:)` under the same
  name), **Rename…** (`PresetLibrary.rename(_:to:)`) and **Delete…**
  (`PresetLibrary.delete(_:)`, after a confirmation).
- **Save…** sets `PresetLibrary.saveRequested`, as do **⇧⌘P** and Presets ›
  Save Preset…; the alert takes a name and calls `PresetLibrary.save(_:as:)`
  with the photo's recipe. A preset of the same name is replaced.
- **The `…` menu.** **Restore Starter Presets** is
  `PresetLibrary.restoreStarters` (`PresetStore.writeStarters`, which
  rewrites every entry of `Preset.starters`); **Show Presets Folder in
  Finder** reveals `PresetStore.directory`.
- **The library and the store.** `PresetLibrary` (`Presets.swift`) is the
  store read into memory, re-read (`PresetLibrary.reload`) after every save,
  rename, delete or restore, with the last failure in `PresetLibrary.error`
  for the strip to show (a failed operation's message is not replaced by the
  standing "could not read" one; that comes back after the next success). `PresetStore(directory:)` is one JSON per preset at
  `<directory>/<name>.json` (`PresetStore.url(for:)` replaces the two
  characters a file name cannot carry); the default directory is
  `PresetStore.defaultDirectory`, `~/Library/Application Support/PhotoLab/presets/`.
  `PresetStore.validated` trims the name and refuses an empty one, a leading
  dot, one over `PresetStore.maxNameLength` or one holding a control
  character (`PresetError.emptyName`, `PresetError.invalidName`); `save`
  refuses a different name that maps onto an existing file
  (`PresetError.fileNameCollision`); `rename` refuses a taken name
  (`PresetError.nameExists`; taken by file identity, so a case-only change
  of a preset's own name is allowed) and `remove` a missing one
  (`PresetError.notFound`). `PresetStore.seedStartersIfMissing` writes the
  starter set only when the directory does not exist yet, so a deleted
  starter stays deleted. A file that cannot be decoded (damaged, or a
  `version` from a newer build, `PresetError.unsupportedVersion`) is listed
  as unreadable and still counts as stored (`PresetStore.exists`); a save
  under its name moves it to a `.unreadable-<stamp>` backup
  (`UnreadableBackup`) and never writes over it.
- **The Presets menu** (`PhotoLabApp.swift`): **Save Preset…** (loupe only),
  then every preset by name; a choice applies it to `Library.batchTargets`
  through `Library.apply(_:mask:to:)`, so in the grid it is a batch and in
  the loupe it is the one photo.

Writes: the preset files under `PresetStore.defaultDirectory` (save, update,
rename, delete, restore). Applying a preset writes the photo's sidecar
through `setRecipe`, never a preset file.

## Export

**Export…** comes from the batch bar, from **⇧⌘E** or the File menu (the item
reads **Export n Photos…** when more than one photo is targeted), always
over `Library.batchTargets`: the grid's selection, or the loupe's photo.

- **The request.** `ExportQueue.requestExport(_:)` (`Batch.swift`) takes
  the `ExportQueue.Item` list from `Library.exportItems(for:)` (each a
  source URL, its recipe, its keywords (`Library.keywords(for:)`) and, for a Photos photo, its own file name: the
  output is `<original name><suffix>.<ext>`, never the cached copy's id;
  a folder photo keeps its file's name) and sets `ExportQueue.request`; `ContentView`
  presents `ExportSheet(request:options:folder:album:toPhotos:)` for it with
  the last options, folder, album and target kind. Ignored while a run is
  going.
- **The sheet.** `ExportSheet` (`ExportSheet.swift`) edits one
  `ExportOptions` through its `ExportForm` (`ExportPresets.swift`: the
  options plus the Size and Watermark controls, folded by
  `ExportForm.resolved`): **Format** (`ExportOptions.Format`: JPEG, HEIC, TIFF)
  with a quality slider for the lossy two; **Size** as edited, an exact
  long side or a percentage (`OutputSize.longSide`, `OutputSize.percent`,
  nil for as edited; never upscaled); **File**: a name suffix with a live
  preview from `ExportOptions.fileName(for:)`, what to do when the file
  exists (`ExportOptions.Collision`: add a number, skip, overwrite) and
  **Keep camera info** (`keepMetadata`); **Watermark**: a toggle, then the
  text, a position (`Watermark.Position`: the four corners or the centre),
  size (`Watermark.size`, the text height as a share of the output's short
  side, `Watermark.sizeRange`) and opacity (`Watermark.opacityRange`)
  sliders; off or blank text gives `ExportOptions.watermark` nil
  (`ExportForm.resolved`), so the fields typed while it is off are not kept
  after the sheet closes; **Export to**: **Folder** or
  **Photos library** (`ExportTarget`; Photos disabled under a bare binary,
  which has no bundle for TCC). For a folder, **Choose…** is
  `ExportPanel.chooseFolder(count:format:from:)`, an `NSOpenPanel` that can
  create directories. For Photos, an **Album** field (default "PhotoLab",
  created if missing; empty = the library only), the line that every export
  is a new photo and a Photos-sourced one comes back beside its original,
  the collision picker hidden, and the access row from
  `ExportQueue.photos.authorizationStatus()`: **Allow Access to Photos…**
  (`requestAuthorization()`, the only prompt) when not yet asked, **Open
  System Settings** and **Check Again** when denied. **Export n Photos**
  (also **Return**) is enabled once a folder is chosen, or for Photos once
  reading is allowed; it calls `ExportQueue.keep(target:options:)` and then
  `ExportQueue.start(_:to:options:)`.
- **Export presets.** A **Preset** row at the top of the sheet: a menu
  titled `ExportForm.presetLabel` ("None", the picked preset's name, or
  "<name> (edited)" once `ExportForm.isEdited`, the resolved options
  differing from the preset's). It lists every `ExportPreset` read by
  `ExportPresetLibrary` from `ExportPresetStore` (a check on the picked
  one) and every unreadable file as "<file> (unreadable)", disabled, with
  the library's error line under the row. A pick is `ExportForm.pick(_:)`:
  every field is replaced from the preset's `options`, the watermark
  section included (switched off when the preset has none); the
  destination, album and folder are not touched. **Save Current as
  Preset…** prompts for a name (the picked one offered) and saves
  `ExportForm.resolved` through `ExportPresetLibrary.save(_:as:)`; when
  `ExportPresetLibrary.exists(_:)` finds a file of that name a dialog asks
  before replacing it. **Delete Preset** (enabled while the picked preset
  is in the list) asks, then `ExportPresetLibrary.delete(_:)` removes that
  one file; the fields stay. A pick or a save sets
  `AppSettings.exportPreset`, a delete of that name clears it, and the next
  sheet shows the remembered name over the last run's options
  (`restorePick`, fields unchanged, so "(edited)" when they differ). No
  built-in presets are seeded.
- **The run.** `ExportQueue.start` hands each item to `Exporter.export`
  (`Batch.swift`) one at a time off the main thread: the full-resolution
  decode, the one render chain with the resize and then the watermark
  last (`Renderer.render(_:recipe:maxPixelSize:resize:region:watermark:)`), the format's writer
  with the source's metadata when asked (and then, for a photo with
  keywords, IPTC Keywords set to them, replacing the source's and keeping
  the rest of its IPTC block: `ExportMetadata.setting(keywords:in:)`), a hidden `.partial` file moved into
  place when complete. The collision policy and the refused writes (the
  photo's own file, `Exporter.Failure.isTheOriginal`; any other original of
  the open library, `Exporter.Failure.isALibraryOriginal`, matched by
  `Exporter.isSameFile` against the item's `protected` set) are in
  `Exporter.destination(for:in:options:)` and `Exporter.export`. A refused
  photo counts as failed and the bar shows its message. A Photos run
  writes each file into its staging directory the same way, hands it to
  `PhotosWriter.importImage(at:intoAlbum:)` and removes it.
- **The bar.** `ExportBar` (`ContentView.swift`) appears at the bottom of
  the window while `ExportQueue.state` is not idle: a progress bar,
  "Exporting i of n", the file in flight (`ExportQueue.current`) and
  **Cancel** (`ExportQueue.cancel()`, which stops after that file; what is
  written stays). When the run finishes or is cancelled it shows the count
  written (`done`), skipped (`skipped`) and failed (`failures`, the first
  message under it), **Show in Finder** on the written files
  (`ExportQueue.exported`) or the folder for a folder run, **Open Photos**
  for a Photos run (`ExportQueue.target`), and **Done** (`ExportQueue.dismiss()`).

Writes: the output files in the chosen folder, through `Exporter.export`;
and, because `PhotoLabApp` makes its queue over the app's `AppSettings`
(`ExportQueue(settings:)`), the last folder, options, target kind and album
in `UserDefaults` under `exportFolder`, `exportOptions`, `exportTarget` and
`exportPhotosAlbum` (`AppSettings.exportFolder` and its neighbours), and
the last picked export preset's name under `exportPreset`
(`AppSettings.exportPreset`), read back at launch so the next sheet opens the same way. A Photos run
writes new assets into the library (and the album) and nothing else.
A queue made without `remember:` (every test) keeps them in memory only.
A preset save writes `<name>.json` into
`ExportPresetStore.defaultDirectory`
(`~/Library/Application Support/PhotoLab/export-presets/`, beside the
develop presets' `presets/`, never inside it), on `PresetStore`'s rules:
`PresetStore.validated` names, `/` and `:` as `-` in the file name, an
atomic write, a different name on the same file refused
(`ExportPresetError.fileNameCollision`), and a file that does not decode
(or whose `version` is above `ExportPreset.currentVersion`) moved aside by
`UnreadableBackup.moveAside` first; a delete removes that one file.

## Settings

`SettingsView` (`SettingsView.swift`), the window of SwiftUI's `Settings`
scene in `PhotoLabApp`: PhotoLab › Settings…, `⌘,` (the system's key, not
an `AppCommand`; `CommandsTests` keeps the table off it). A grouped form
over the library's `AppSettings`; every control applies at once and is
remembered.

- **Grid › Thumbnail size**: a slider over `AppSettings.gridThumbnailSize`
  with its value in points, the same value as the strip under the grid
  (Grid, above).
- **Loupe › Preview quality**: `AppSettings.previewQuality`, a
  `PreviewQuality` (Full, Balanced, Fast). `PreviewCanvas` asks for its fit
  frame at `PreviewQuality.pixelSize(_:)` of the pane's longest side (1,
  0.75 or 0.5 of it, `PreviewQuality.scale`) and draws it scaled to fit
  (the histogram is counted on that frame); the 1:1 window and every export
  are unchanged.
- **Launch › Reopen the last folder or album**:
  `AppSettings.reopenLastSource`, read by `Library.restoreLastSource`
  (Welcome, above).
- **Sort › Folders / Photos albums**: a key and a direction per source
  kind. `Library.defaultSort(for:)` shows the open source's own sort for its
  kind and the remembered one for the other; `Library.setDefaultSort(_:for:)`
  sets `Library.sort` (a re-sort at once) when the open source is of that
  kind, and only remembers it otherwise (`AppSettings.setSort(_:for:)`).

`AppSettings` (`Settings.swift`) is the one store for everything kept
between launches: these four, the filmstrip and Info toggles, the last
source and Open Recent, and the export sheet's last choices, each under the
key earlier builds wrote (`AppSettings.Key`), so an upgrade loses no saved
value. `PhotoLabApp` makes one and hands it to `Library(settings:)` and
`ExportQueue(settings:)`; a `Library(rememberFolder: false)` gets one that
is not `persistent` (reads and writes nothing).

Writes: those keys in UserDefaults, nothing else.

## Menus and shortcuts

One table defines every key: `AppCommand.all` (`Commands.swift`), each
entry a title, a key and its modifiers, a placement (the menu group it sits
in, or `keysOnly`), `isEnabled` and `perform` over a `CommandContext` (the
`Library`, plus the `PresetLibrary` and `ExportQueue` for Save Preset and
Export). The menus and the hidden shortcuts are both built from it, so no
key is typed anywhere else; the README's Keys table is the user's list.

- **Bare keys stay off the menus.** A key with modifiers is bound on its
  menu item. A key without, or with Shift alone (⇧M types an "M";
  `AppCommand.isBareKey`), is bound only on
  `HiddenShortcuts` and written after the menu item's title ("Pick (P)",
  `AppCommand.menuTitle(_:)`): a menu key equivalent is global to the app
  and would take the letter from a text field in a sheet or an alert (the
  Save Preset name, the export suffix), while the hidden buttons sit in the
  main window and never see those keystrokes. The main window's own text
  field, the grid's search, is covered by the table itself: `AppCommand.all`
  is the entries passed through `AppCommand.offWhileTyping`, which makes
  every bare key's `isEnabled` false while `Library.textEntryActive`, so
  the hidden buttons and the menu items are disabled together while the
  user types.
- **Menus** are the `.commands` of `PhotoLabApp` (`PhotoLabApp.swift`),
  each a `CommandGroup` or `CommandMenu` holding `CommandItems` for one
  placement (table order, a divider between sections; an entry with an
  `isOn` state is a checkable item). `AppCommand.Placement.menuTitle` names
  each placement's menu and `addsMenu` says whether the app adds it: only
  Photo and Presets are a `CommandMenu`, titled from the table; File, Edit
  and View are the menus SwiftUI supplies (`Placement.suppliedMenus`), so
  their items are a `CommandGroup` there and the menu bar has one of each:
  - File: **Open Folder…** **⌘O** (`Library.chooseFolder`) and **Open
    Photos Library…** **⇧⌘O** (`Library.choosePhotosAlbum`), then **Open
    Collection** (`OpenCollectionMenu`) and **Open Recent**
    (`OpenRecentMenu`), then **Delete Collection…** (section 1 of
    `.newItem`, drawn after the two submenus through `CommandItems`'
    `sections`) replace `.newItem`; **Export…** **⇧⌘E** (`ExportQueue.requestExport(_:)` over
    `batchTargets`, disabled with nothing targeted or a run going) and
    **Save to Photos** (`Library.saveToPhotos()`, enabled by
    `Library.canSaveToPhotos`) replace `.importExport`.
  - Edit, after `.pasteboard`: **Copy Settings** **⇧⌘C**
    (`Library.copySettings(from:)`), **Paste Settings…** **⇧⌘V**
    (`Library.requestPaste`), **Sync Settings…** (`Library.requestSync`,
    from two selected), **Select All Photos** **⌘A** (`Library.selectAll`,
    grid only); then **Search Photos** **⌘F** (see Grid, Search), enabled
    while the source has photos.
  - Edit, replacing `.undoRedo`: **Undo** **⌘Z** and **Redo** **⇧⌘Z**
    (`Library.undo()`, `Library.redo()`; the window's own undo manager is
    unused).
  - **Presets**: **Save Preset…** **⇧⌘P** and the preset names (see Presets).
  - **View**, after `.toolbar` in SwiftUI's own View menu: **Grid** **G**, **Loupe** **E**, **Map** **⌥⌘M**
    (`Library.showMap`, toggled; see Map), **Zoom to 1:1** **Z**
    (`Library.toggleZoom()`, loupe only), **Before and After** **Y**,
    **Show Original** **\\**, **Clipping Warning** **J**, **Show Mask Overlay**
    **O** (`Library.showMaskOverlay`, see Adjustments panel, Masks), **Filmstrip** **F**,
    **Info** **⌘I** (`Library.showInfo`), **Previous Photo**
    **←** and **Next Photo** **→** (the keys below); then **Show** (the
    filter) and **Sort By**, the `sort` placement's items with no keys:
    **Capture Date**, **Name**, **Rating**, **Edited** (one checked,
    `Library.sort.key`), then **Ascending** / **Descending**
    (`Library.sort.ascending`), enabled while a source is open.
  - **Photo**: **Pick** **P**, **Reject** **X**, **Unflag** **U**, **No
    Rating** **0** to **5 Stars** **5**, then **Crop** **R**
    (`Library.cropMode`, loupe only), **White Balance Picker** **W**
    (`Library.whiteBalancePicking`, loupe only), **Auto Tone** **⌘U**
    (`Library.autoTone(_:)` over the batch targets, see Adjustments panel,
    Auto) and **Reset Photo** **⇧⌘R**
    (`Library.resetRecipe(for:)`, enabled when the photo is edited); then
    **Keywords…** **⌘K** (`Library.requestKeywords(for:)` over the batch
    targets, see Keywords); then **Add to Collection**, a submenu
    (`AddToCollectionMenu`: the saved collections, then the `collection`
    placement's **New Collection…**), and **Remove from Collection**
    (`Library.removeFromCollection(_:)`), see Collections. A submenu
    placement (`Placement.isSubmenu`: `sort`, `collection`) sits inside a
    menu the app adds or SwiftUI supplies. Then **New Linear Gradient** **M**, **New
    Radial Gradient** **⇧M** and **Brush** **K** (`Library.addMask(_:for:)`
    on the loupe photo, loupe only; Brush is checked while
    `Library.maskBrushArmed` and, checked, puts the brush down; see
    Adjustments panel, Masks).
- **The bare keys** are `HiddenShortcuts` (`Commands.swift`), a `ForEach`
  over the table's bare keys: invisible zero-size buttons in the window's
  background, so they work whatever has focus in the window. **G** leaves the loupe and the map; **E** and **Return** enter it
  (selecting the first photo when none is), and both are disabled while
  `Library.visiblePhotos` is empty, so on the Welcome view **Return** is its
  **Open Folder…** default button; **Esc** clears
  `Library.whiteBalancePicking`, else `Library.maskBrushArmed`, else `Library.straightening`, else leaves crop mode, else the
  loupe or, in the grid, collapses the selection; **R** toggles
  `Library.cropMode` in the loupe; **W** toggles
  `Library.whiteBalancePicking` in the loupe; **←** / **→** are `Library.select(offset:)`;
  **Z** toggles `Library.loupeZoom` in the loupe;
  `\` toggles `Library.showBefore`; **Y** toggles `Library.compare` (and
  from the grid enters the loupe with it on); **J** toggles `Library.showClipping`
  (the clipping overlay, see Adjustments panel); **O** toggles
  `Library.showMaskOverlay`; **M** / **⇧M** / **K** add a mask in the
  loupe; **P** / **X** / **U** flag
  and **0**–**5** rate the batch targets (`Library.setFlag(_:for:)`,
  `Library.setRating(_:for:)`). **Return** and **Esc** have no menu item
  (`keysOnly`). A new key is a new `AppCommand.Name` and a table entry;
  `CommandsTests` fails on a key two entries share.
- **Toolbar**: **Open Folder**, the **Grid / Loupe / Map** segmented picker
  (which selects the first photo when entering the loupe with none
  selected; Map is `Library.showMap`), the **Before / After** toggle (`Library.compare`, the same
  as **Y**) and, in the loupe of a Photos album, **Save to Photos**.
- **Launch**: `PhotoLabApp` opens the first command-line argument that does
  not start with `-` (a folder, or a file to open in the loupe), else the
  remembered source (`Library.restoreLastSource`); the process is made a
  regular foreground app so a `swift run` without a bundle still gets a
  window and a menu bar (but no Photos access: see Welcome).

Writes: nothing directly; each command's target is listed in its own
section above.
