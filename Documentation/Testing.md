# PhotoLab — testing

What the test suite proves, how to run it, and how to work with it. The
tests are XCTest, in `Tests/PhotoLabTests/`, built against the app target
with `@testable import PhotoLab`.

## Running

    swift test                                   # the whole suite
    swift test --filter SidecarTests             # one test class
    swift test --filter ToneSetTests/testRotateIsClockwiseAndKeepsTheAspectWithoutEmptyCorners

The filter is a regular expression over `Class/test`. Build with Xcode
selected (README, Run): the Command Line Tools toolchain cannot build the
SwiftUI target. A green run prints the executed count with its failures and
skips; eight tests skip by design (the two snapshot tests, below, the two real-RAW timings, and the four
real-PhotoKit tests: two in `PhotosTests`, which run only in a process that
is already authorized for Photos, and the import in `ExportTests` and the
edit in `AdjustmentDataTests`, which also need `PHOTOLAB_PHOTOS_WRITE=1`),
and a timed gate that misses on a
swamped box skips rather than fails (Load sensitivity, below). A known
defect that is not fixed yet is pinned with `XCTExpectFailure("<what>")`:
the run stays green while it fails as described, and goes red the day it
is fixed, so the pin is removed with the fix (one today: contrast,
`RendererTests`). The timed
tests print a `BENCH` line with their numbers beside the verdict; read it,
not only the pass.

## What each file proves

- `RendererTests.swift` — the recipe model (every kind once, in chain order;
  JSON round trip), the neutral recipe is the identity, a disabled entry
  changes nothing, the direction of exposure, temperature, tint and
  saturation, the preview fit (down, never up), and the timed slider step on
  a 24 MP photo. `testContrastLeavesMiddleGrayWhereItIs` is pinned with
  `XCTExpectFailure`: contrast pivots at 0.5 in the linear working space
  (about sRGB 188), so +50 takes a flat sRGB 128 gray to 77 and −50 to 161;
  + contrast darkens a whole photo.
- `ToneSetTests.swift` — the direction tests for the whole tone set (below),
  the sidecar shape holding one entry per kind, the timed sweep of every
  slider over an everything-on recipe, and the load guard's own test
  (`FrameBudgetGuardTests`: the bound holds when quiet, scales when busy,
  skips only when unmeasurable, and a quiet miss is a red).
- `SidecarTests.swift` — a recipe saved for a photo comes back when the
  folder is opened again in a new `Library`, two originals that differ only
  by extension never share a sidecar, the original is untouched, the default
  recipe removes the file, an unreadable sidecar throws and is not
  overwritten, a sidecar from a newer build is refused and kept as the
  `.unreadable-<stamp>` backup of the next save, a junk sidecar survives an
  edit through the `Library` as that backup, undo and redo walk the history
  and persist each step, and a slider drag is one undo step written once at
  the end; so is a crop handle drag (`Library.dragCrop`): the crop follows
  live with no sidecar write until `endCropDrag`, one undo takes the whole
  drag back, and a corner writes only its two edges. Shown to bite by
  dropping the drag's `beginEdit` (a write mid-drag).
- `EditStateTests.swift` — `Recipe.isNeutral` versus `Recipe.isDefault`: a
  disabled-only edit renders as identity but is still an edit, in memory and
  on disk; `Library.endEdit` closes whatever edit is open and `beginEdit` on
  another photo closes the first; `Library.open` of a missing path (or a
  flag-like argument) opens nothing and keeps the current folder; and
  `Library.maxUndoDepth` (100) caps the undo stack, dropping the oldest
  steps and keeping the newest in order.
- `SourceTests.swift` — the `PhotoSource` seam: a fake source of three
  assets opens in the sort order (no dates, so by name) with its names and title, a recipe on an
  asset persists under the flat naming (`A/L0/001` as `A_L0_001.json` in
  the injected directory) and reloads through a fresh `Library`, export
  items and the loupe take their file from the source, a source whose
  listing fails is refused and the open folder stays, a folder opens
  through `FolderSource` with its sidecars at `.photolab/<relative
  path>.json`, the two namings map ids to files, and `PhotoID` round trips
  through JSON and keys one thumbnail cache.
- `PhotosTests.swift` — `PhotosSource` behind `FakePhotoKit`, a complete
  in-memory `PhotoKitClient` (status, albums, assets, a 4 px thumbnail that
  can be held on a semaphore, an original that can be held or made to
  fail, every call counted): nothing is fetched before access is allowed
  (`PhotosBrowser` lists no albums, `photos()` throws
  `PhotosError.notAuthorized`, `Library.open(album:access:)` is refused,
  no thumbnail is asked) and `PhotosBrowser.requestAccess` is the one
  prompt, after which the albums come; a denied grant lists nothing;
  Recents is first and an album opens in the client's order with the
  originals' file names and flat sidecars in the injected directory;
  `PhotoKitLive.assetFetchOptions()` is images only by `creationDate`
  ascending; the shared decoder rule sends an `.asset` id to
  `Thumbnails.source` and a `.file` id to ImageIO, and a request cancelled
  while the client is at work sees the cancellation inside the client and
  caches nothing (the control decodes once); an original is written once
  over two calls as `<safe-id>.<ext>` in the injected directory, two
  concurrent asks share one write, a fresh source finds the copy, a failed
  write leaves nothing and is retried, an unlisted id throws; the last
  source is remembered by kind in an injected `UserDefaults` suite and
  restored, and a launch before access is allowed opens nothing and never
  prompts. Two real tests, `testRealLibraryListsRecentsFirst` and
  `testRealOriginalIsCachedUnderTheOriginalsDirectory`, call PhotoKit
  itself: they `throw XCTSkip` unless
  `PHPhotoLibrary.authorizationStatus(for: .readWrite)` is already
  `.authorized` (never `requestAuthorization`; the `xctest` host under
  `swift test` is not, so they skip there and say so).
- `AdjustmentDataTests.swift` — Save to Photos and the recipe read back,
  behind `FakeEditingPhotoKit` (an authorized one-album library whose
  originals are mid-gray PNGs, one adjustment per asset in memory, the JPEG
  each save rendered kept, a read that can be held): a save holds
  `local.photolab.recipe`, version `1` and recipe-only JSON that decodes to
  the saved recipe, its rendered content is a full-size JPEG brighter than
  the original under exposure +1, and the sidecar is unchanged; a second
  save replaces the data and the render; Save is offered only for an edited
  photo of a Photos album and a refused save is reported and can be tried
  again; `PhotosAdjustment.canHandle` is our identifier at an integer
  version this build reads. Reopen: no sidecar plus PhotoLab's data restores
  the recipe, writes the sidecar and leaves `canUndo` false, and the next
  open reads the sidecar; a sidecar wins and an unedited asset is never
  asked; another app's data gives neutral and writes nothing; version 2 (or
  version-2 JSON under a version-1 label) is refused and the photo listed in
  `unreadableSidecars`; an edit made while the data is read wins.
  `testRealSaveOntoATestAssetReadsBack` imports a 16 px JPEG into "PhotoLab
  Tests", saves an edit onto that asset and reads the data back; it skips
  unless `PHOTOLAB_PHOTOS_WRITE=1` AND the host is already authorized.
- `CullingTests.swift` — a flag and rating on a neutral recipe round trip
  through a fresh `Library` (the sidecar kept for the marks alone), Reset
  keeps the flag while an unmarked reset removes the file, marks never enter
  a sync, a preset or copied settings, the filter returns the subset in
  folder order and `batchTargets` never holds a hidden photo, and a sidecar
  written before the marks existed still decodes
  (`testChunkThreeSidecarStillDecodes`).
- `PresetTests.swift` — the starter set is distinct looks without geometry,
  saving drops geometry and applying keeps the photo's own, a preset round
  trips through a fresh `PresetStore`, file names are sanitised and names
  validated, rename keeps the recipe and refuses a taken name (taken by file
  identity: a case-only change of a preset's own name is allowed), an unreadable
  preset file is listed and left alone, an undecodable preset is not an
  empty slot and becomes the backup of a save (Restore Starters included),
  a preset from a newer build is refused, listed unreadable and kept on
  save, a fresh directory is seeded once,
  `PresetLibrary` reports errors and recovers and a failed operation's
  message is not masked by the standing unreadable-file one, a saved preset applied to
  another photo after a reopen reproduces the edit, applying the preset a
  photo already shows is no step, the preset `save` returns equals the one
  read back (`updated` kept to the whole second the file holds), and the
  timed strip.
- `BatchTests.swift` — `Recipe.syncing` takes only the masked kinds, a
  preset applied to a multi-selection writes one sidecar per photo and one
  undo takes them all back, a later single edit sits on top of a batch, the
  grade mask keeps each photo's own exposure and crop, the click / shift /
  command / select-all rules, and the export queue writing every photo
  through the renderer and stopping after the item in flight on cancel.
- `ExportTests.swift` — JPEG quality moves the file size monotonically,
  resize gives an exact long side, works in percent and never upscales, a
  rotated export resized to a 2048 px long side keeps every border pixel at
  the source's gray at four angles (the rotate inset is applied at render
  size; the resize after it must not bring the rotated edge back), the
  camera EXIF travels with the orientation reset in every format, HEIC and
  TIFF round trip, the collision policy (number, skip, overwrite) and the
  original is never written, not even under a case-variant name on a
  case-insensitive volume, an Overwrite onto another library original (by
  name, case variant or hard link) fails in the queue with the file named
  and both originals byte-identical, the queue counts skipped files and passes the
  options through, the file name, suffix, extension and options round
  trip, and the preview and the export agree on colour: `Renderer.previewMaster`
  rendered at loupe size and `Renderer.fullResolution` exported as a TIFF,
  on a Display P3 HEIC and an sRGB JPEG under one recipe that moves every
  channel, have the same mean colour to within 1/255 (the "one render path"
  claim, pinned). The Photos target runs against `FakePhotosWriter`, which
  reads each file it is handed and counts the files staged beside it:
  three items give three imported ids, all in the named album, rendered per
  the options (name suffix, long side), one staged file at a time and an
  empty staging directory after; a writer failure is a failure and the run
  goes on, the refused file removed too; no album means the library only,
  and `keep(target:options:)` remembers the album and the kind but never
  touches the folder. `testRealImportAddsA16PixelJPEGToTheTestAlbum` imports
  a real 16 px JPEG into an album "PhotoLab Tests" and SKIPS unless
  `PHOTOLAB_PHOTOS_WRITE=1` AND the status is already `.authorized` (it
  adds a photo to the library, so it never runs by accident; under
  `swift test` the host is not authorized and it skips).
- `ThumbnailTests.swift` — the embedded-preview size rule (a small embedded
  thumbnail is refused and the image decoded; a request at or under its
  size is served from it), the timed folder of synthetic JPEGs, the
  real-RAW timing (skipped unless asked for), the cancellation proof (a
  request cancelled before its decode decodes nothing, one cancelled in
  flight sees the cancellation inside the decode and caches nothing), and
  the edited thumbnails: an exposure +2 recipe gives a thumbnail brighter
  than the plain one at the same size from one decode and one render with
  the plain entry still the base, the same (photo, recipe) comes back as the
  same object with no second render while another recipe is its own entry,
  the neutral recipe and a disabled-only one never call the renderer and
  share the plain entry, a cancelled edited request renders and caches
  nothing, and the timed render from the cached base.
- `RawFirstFrameTests.swift` — the loupe's first frame, with the decodes
  injected (`PreviewModel.Decoders`) so the master can be held back: the
  embedded preview's frame arrives first with the recipe applied (exposure
  brightens it) and the master's replaces it with exactly one more frame;
  an edit made over the preview is what the master renders; a master that
  lands first cancels the preview, whose late result neither shows nor
  feeds the next render; a photo change cancels both of the old photo's
  decodes (each sees the cancellation inside its body) and neither result
  shows; a failed master takes the preview's frame down. The rule
  (`ImageLoading.firstFrame`) on real JPEGs: the 160 px EXIF thumbnail is
  returned as stored between the bounds and refused outside them, and a
  file with no embedded preview gives nil, not a decode. The real-RAW
  first-frame timing (`PHOTOLAB_BENCH_RAW`, printed as BENCH-FIRST-FRAME,
  not gated) skips unless asked for.
- `HistogramTests.swift` — a frame with a 25 % white block reports a quarter
  of its pixels blown and none crushed, the warning lights above a tenth of
  a percent and not at it, the bins sum to the pixel count and match a
  plain-Swift count, one clipped channel counts the pixel, the timed
  preview-sized frame, and the overlay flags exactly the clipped pixels of a
  frame holding every 8-bit level and of a rendered frame, agreeing with
  that frame's histogram.
- `CompareTests.swift` — compare mode in `PreviewModel`: Before and After
  come out at equal pixel size from one master, Before equal to the neutral
  render (maxDiff 0) and After to the recipe's; no second frame outside
  compare mode; turning it on renders Before for the shown request; a
  slider drag re-renders After only (latest wins) while a new size renders
  both again; Before lands during a sustained drag rather than after it;
  leaving compare mode drops the second frame, and a Before from an
  earlier compare session never shows; opening a folder turns it off; at
  1:1 both halves show the same region (Before the neutral window, maxDiff
  0) at a centre and at a corner, and leaving compare drops only the
  Before window.
- `ZoomTests.swift` — 1:1 in `PreviewModel`: on a synthetic 24 MP photo
  with clarity, sharpening and vignette on, the window at a centre and at a
  corner equals the same crop of a full-resolution render of the whole
  image (maxDiff at most 1), and again with crop and rotate on (moderate
  detail amounts; Architecture, The loupe at 1:1), so the centre is in the
  rendered frame's coordinates; `image` and the histogram stay the fit
  frame's; `Region.rect(in:)` slides the window inside the frame; the
  full-resolution master is decoded on the first 1:1, kept by fit, and
  dropped (with the window) when the photo changes, the new photo decoding
  its own; a window still rendering when fit returns never lands; a drag
  while zoomed ends on the newest recipe in both frames; the timed region
  step; a photo whose frame fits the view goes back to fit with no window,
  one wider than the view zooms; the clipping overlay on the window is the
  same compose over the plain window, before and after a pan. Shown to
  bite by rendering the cropped input (maxDiff 114 at the centre, 63 at
  the corner).
- `ZoomMathTests.swift` — the loupe's zoom arithmetic (`ZoomMath`): the
  fit rect in the padded pane; a click maps to the centre of the 1:1 window
  at display scale 1 and 2 (and a click off the photo maps to nothing);
  the clamp holds the window inside the frame at all four edges and agrees
  with `Region.rect(in:)`; a photo that fits the view stays at fit; a pan
  moves the window by the drag times the display scale and stops at the
  edge. Shown to bite by removing the clamp (7 failures in 2 tests).
- `CropMathTests.swift` — crop mode's arithmetic (`CropMath`): a handle
  dragged in view points maps to the same normalised crop at display scale
  1 and 2 (the fit rect is in points) and the handle lands under the
  pointer; every inset is clamped at the image's edge; an edge dragged
  across the other stops at the slider's 40%, holding `CropMath.minSize`;
  a corner moves its two edges and no other; a written crop is the
  recipe's percent and leaves the edges the handle does not own alone; and
  crop mode's frame is the recipe uncropped at the same rotation. Shown to
  bite by removing the clamp (9 failures in 2 tests).
- `AspectMathTests.swift` — the crop's aspect lock (`CropMath.Aspect`,
  `CropMath.refit`, `CropMath.drag(_:from:by:fit:ratio:)`): every locked
  preset, each way round, on a 24 MP frame landscape and portrait, holds
  its ratio to within 1 px after six drags of each corner, read back from
  the recipe's percent too, with the opposite corner fixed and every inset
  in bounds, and the renderer cuts that size to within 2 px (`integral`);
  a locked corner follows the axis the pointer moved further; the swap
  inverts the ratio and the title, and 1:1 and Free cannot swap; a refit
  from five starting crops stays inside the image and the 40% bound, holds
  the ratio and touches an edge; under a lock the edge handles are hidden
  and inert; through `Library`, a pick refits as one undo step and one
  write, the same pick or Free adds none, and a locked drag holds 5:4 and
  is one step. Mutants (failures over both files): the drag's width not
  locked (996), the refit's bound check removed (36), the swap a no-op
  (8), `Library.dragCrop` passing no ratio (1).
- `StraightenTests.swift` — `StraightenMath` and `Library.straighten`: a
  line at +3.2° (y down) gives rotate -3.2 drawn either way, -2° gives
  +2; near-vertical lines (87°, -86°) are made upright and 45° is the last
  angle read as a horizon; the correction adds to the current rotate and
  stops at ±45°; a press is not a line; the renderer itself levels a line
  drawn at +3.2° in a test image at the rotate the tool computes (ends
  within a row; ~17 rows apart before); through `Library`, arming enters
  crop mode, the line is one undo step and one write with the crop kept
  and disarms the tool, and Esc disarms it before leaving crop mode.
  Mutants: the sign flipped (11 failures, the renderer check among them)
  and the upright fold removed (5).
- `PhotosLazyTests.swift` — a large Photos album behind `LazyPhotoKit`, a
  fake that lists 5,000 unnamed assets and counts every name read (50 µs
  each, optionally held on a semaphore): `Library.open(album:access:)`
  returns inside a 50 ms `assertFrameBudget` with no name read, every photo
  unnamed, in capture order, and the one sidecar found; names are read only
  for the cells asked (`Library.resolveName`), once each, never on the main
  thread; a cell cancelled while its read is held writes nothing, and a read
  for a source reopened meanwhile is dropped; a sort by Name keeps the order
  until `nameEveryPhoto` has named all, then sorts once; unnamed photos sort
  last by id in either direction; an export names its output from the
  asset's own name though no cell asked. Mutants: every name read in
  `PhotosSource.photos()` (13 failures in the 4 ungated tests, the open at
  349 ms against 50; the 2 gated tests hang on the held read), the
  cancellation check dropped from `resolveName` (2), the Name sort's
  naming rule dropped from `resort` (2).
- `SortTests.swift` — `PhotoSort`: each key in both directions over a mix
  of file and asset ids through the one function, ties by name ascending
  then id, undated photos last in either direction, the order independent
  of the input order, and the storage key round trip; `CaptureDates` reads
  EXIF `DateTimeOriginal`, falls back to the file's date, and reads each
  file once (an injected counting reader); a folder and an album-like source
  open in their kind's default and sort through the same rule; a re-sort
  keeps the anchor, the multi-selection and the loupe while the filmstrip,
  `batchTargets` and the arrows follow the new order; a rating under Rating
  and an edit (and its undo) under Edited move the photo at once; the
  choice is remembered per source kind in the injected defaults and never
  with `rememberFolder: false`; and the `sort` placement's commands check
  and set the choice.
- `SettingsTests.swift` — `AppSettings`: its defaults (180 pt, Full,
  reopen on, filmstrip shown, Info closed, each kind's default sort) and a
  read that writes nothing; a round trip of every value through an injected
  `UserDefaults` suite, the thumbnail size clamped in memory and on disk;
  the keys earlier builds wrote (`showFilmstrip`, `showInfo`, `sort.*`,
  `lastFolder`, `recentSources`, `export*`) read back by a `Library` and an
  `ExportQueue` unchanged; `GridView.columns(for:)` takes its minimum from
  the size; `PreviewQuality.pixelSize(_:)`; Reopen off leaves
  `restoreLastSource` on the Welcome view while Open Recent still lists the
  folder (and on reopens it); the Settings sort rows remember a kind with
  nothing open, re-sort the open kind at once, leave the other kind's grid
  alone, and follow the grid's own Sort; a store that is not `persistent`
  reads and writes nothing. Shown to bite by four mutants (no reopen guard,
  the grid ignoring the size, a renamed `showFilmstrip` key, the Settings
  sort never applied live), one or more failures each.
- `InfoTests.swift` — `PhotoInfo` over a JPEG tagged with a camera, lens,
  exposure, capture date, west-longitude GPS and orientation 6: every row
  formatted, in order, dimensions as displayed; a PNG with no EXIF shows
  only dimensions, file, size, folder, captured and edited, and empty or
  zero header values have no row; the units (camera make not repeated,
  focal length, aperture, shutter under and over a second, Finder sizes,
  S/E coordinates); `PhotoInfoStore` reads a header once for three asks
  (two at once), never on the main thread, and hands the capture date to
  `CaptureDates` so the sort reads nothing, while a date the sort already
  has wins; a Photos asset shows the listing's name and date, no folder,
  and the rest from its original; the Edited row follows `Library.isEdited`;
  View › Info (`⌘I`) opens the loupe from the grid, toggles in it and is
  remembered. Shown to bite by six mutants (a blank value shown, the W
  reference ignored, no `remember`, no in-flight dedupe, no orientation
  turn, an asset's folder kept), one or more failures each.
- `CommandsTests.swift` — the command table (`AppCommand.all`): no two
  entries share a key and modifiers, and none takes a system menu key
  (⌘Q, ⌘W, ⌘H, ⌘M, ⌘, and the clipboard's); every `HiddenShortcuts` button
  is one of the table's bare keys, and they are every key the window had; no
  `.keyboardShortcut` with a key is typed in any other source file (the
  test reads them); the View and Photo menus list every bare key but Return
  and Esc, whose names a menu title spells out ("Pick (P)"); no placement
  adds a `CommandMenu` of a menu SwiftUI supplies (one View menu), and every
  `CommandMenu(` in the sources takes its title from the table; Return
  (Open in Loupe) is disabled with no photo, so the Welcome view's Open
  Folder… holds it; and each
  command's `perform` on a library over a temporary folder does what its
  title says (P, X, U and 0–5 mark every batch target, Y from the grid opens
  the loupe in compare, J and backslash toggle their overlays, the arrows,
  G, E, Esc and Return move the view, Reset Photo, Undo, Redo, Copy
  Settings and Select All act on the selection; Z toggles 1:1 in the loupe
  only, and the arrows, even at either end, a click on another photo and
  leaving the loupe all return to fit; R toggles crop mode in the loupe
  only, entering it returns to fit and ends compare, Esc leaves it before
  the loupe, and Z, Y and leaving the loupe end it; Esc putting the
  straighten tool down first is in `StraightenTests`).
- `WorkflowTests.swift` — one photographer's session through the real
  model layer, nothing faked but the Photos writer (`FakePhotosWriter`):
  six synthetic JPEGs and PNGs (one portrait) open in natural order with a
  plain thumbnail each; an Exposure drag on one photo is one undo step and
  one sidecar, and its thumbnail is brighter; its look saved as a preset
  and applied to another photo keeps that photo's rotation and crop; flags
  and ratings, and a reset that takes the edit and keeps the marks; the
  Picks filter moves a hidden anchor to the next pick with the loupe up,
  and the arrows, Select All and the batch targets see the picks only; a
  shift-click under the filter skips the hidden reject, and a Grade sync
  keeps each target's exposure and framing and leaves every other photo
  alone; one undo takes the whole sync back, redo returns it, and a rating
  is not an undo step; the picks export to a folder (suffix, long side,
  exactly the exporter's pixels for each recipe, the hidden reject not
  written) and to Photos (album, names, nothing left staged); Copy Settings
  pastes with the last mask onto a photo of another folder; a fresh
  `Library` and `PresetLibrary` read every recipe, mark and preset back
  with no undo history, and a trip to another folder and back keeps it all.
  Each failure names its step. A second test pins a seam the session
  found: a Sync sheet left up while another folder opens is dropped, and a
  sync naming another source's photos writes nothing into the new folder
  (it used to overwrite a namesake photo's sidecar there).
- `TestImages.swift` — no tests; the shared helpers. `syntheticImage(width:height:space:)`
  draws the photo every pixel test reads (a luminance ramp with coloured
  bands, so both neutral and saturated pixels are present; sRGB unless a
  colour space is passed), `meanRGB` and `maxDiff` measure a rendered frame,
  `bench24MPImageURL()` is the 24 MP source for the timed tests, and
  `loadAverage()` / `assertFrameBudget` are the one load guard every timed
  test gates through.

## The snapshot harness

`Tests/PhotoLabTests/Snapshots/` renders the app's main-window states to PNG
in-process, light and dark, so a design review can read the screens without
anyone driving the app. It is skipped unless an output directory is passed:

    PHOTOLAB_SNAPSHOTS=<output dir> swift test --filter UISnapshotTests

The directory is the caller's (never a default, and keep it outside the
repo: the PNGs are not committed). It gets `light/`, `dark/` (one
`<nn>-<state>.png` per state) and `index.txt`, one line per state with what
it shows, the model state it was set to, and its offscreen caveat.

How it works: each state's view is hosted in a titled `NSWindow` that is
never ordered on screen (no `orderFront`, no activation, no screen capture),
through an `NSHostingController` with `sceneBridgingOptions = .all`, so the
window toolbar and title draw into the frame view's bitmap
(`cacheDisplay`, 2x). The harness waits with `Task.sleep` (a blocking
run-loop spin starves the main actor, and the grid's thumbnail tasks never
resume), and writes a state only once its model is ready and three
successive captures are identical; a state that has not settled in 45 s
fails by name. Everything is injected: `Library(rememberFolder: false)`, a
temp `PresetStore`, an `ExportQueue` with `FakePhotosWriter` (and a held or
failing worker for the export bar), `PhotosTests.FakePhotoKit` for Photos
sources, and a temp folder of synthetic photos per state (12 JPEGs, a PNG,
a junk `.JPG` and a junk sidecar where a state needs them). One production
seams exist for it, each with the app's behavior as the default:
`PanelStart` (an environment value, unset in the app) opens the adjustments
panel with chosen sections expanded; `hasBundle` (an environment value
defaulting to `PhotosAccess.hasBundle`) lets the Welcome view, the toolbar
and the Export sheet be hosted with or without an app bundle; and
`PhotosAlbumSheet(access:)` takes a fake Photos access. The Sync, Export and
Photos-album sheets are each hosted as their own root view at their fitting
size (no window dimming or sheet chrome); no state ever calls
`requestAuthorization`. `PHOTOLAB_SNAPSHOT_GROUP=main|sheets` takes one
group while iterating (its index is `index-<group>.txt`).

The gate with the variable set: every state is written in both modes, none
is a single flat color, none times out. Without it the tests skip and the
suite is as fast as before. The grid is lazy, so a state's thumbnails load
only for the cells in the viewport, as in the app; materials may render
flatter than on screen (read `index.txt`); system alerts, file panels and
the menu bar are not part of the catalogue.

## The direction tests

`ToneSetTests` pins the sign of every kind: each test moves one slider on
the neutral recipe and reads pixels back, so a kind cannot quietly act the
wrong way.

- Highlights and shadows move their end of the ramp more than the other;
  whites and blacks move their end and leave the other; each tone-curve
  point moves its own zone.
- HSL, per band: saturation of a band desaturates that band only, luminance
  lightens that band only, hue rotates that band only; a gray image is left
  alone by every HSL slider.
- Clarity raises and lowers local contrast; sharpening raises edge contrast;
  grain adds noise to flat areas and keeps the size; vignette darkens or
  brightens the corners and not the centre.
- Rotate is clockwise, keeps the aspect and leaves no empty corners; each
  crop edge removes its own side and no other.

`RendererTests` does the same for exposure, temperature, tint and
saturation.

**Proving one bites.** Before trusting a direction test, show it can fail.
Locally, never committed: in `Renderer.swift`, find the kind's branch in
`stage` (or its parameters in `groupStage` for a crop, tone or HSL kind) and
flip the sign, or neutralise the branch by returning the input image. Run
that kind's test alone:

    swift test --filter ToneSetTests/testVignetteDarkensOrBrightensTheCornersNotTheCenter

Watch it go red with the assertion naming the kind, then put the file back:

    git checkout -- Sources/PhotoLab/Renderer.swift

and run the test again green. A test that stays green under its mutant is
not a direction test; fix the test before the code.

## The timed renders

The timed tests cover the render path, the thumbnails and the histogram;
each prints a `BENCH` line and fails above a bound.

- `testSliderStepRenderTimeOn24MP` (`RendererTests`): a sweep of exposure
  steps at loupe size over a 24 MP master; the median step must fit one
  60 Hz frame.
- `testEverySliderStepRenderTimeOn24MP` (`ToneSetTests`): the same gate for
  every kind, each stepped over an everything-on recipe. A crop or rotate
  step changes the output size, and Core Image charges extra the first time
  it meets a size; those kinds are measured twice over the same sizes and
  gated on the second pass, the first printed beside it.
- `testPresetThumbnailsRenderUnder50msEachOn24MP` (`PresetTests`): the strip
  of starters over the current photo, each cell under its bound.
- `test500SyntheticJPEGsThumbnailConcurrentlyUnder3s` and
  `testRealRAWThumbnailsFromEmbeddedPreviewUnder100msCold` (`ThumbnailTests`):
  a folder of synthetic JPEGs thumbnailed cold and concurrently, and a real
  camera RAW through its embedded preview. The RAW test throws `XCTSkip`
  unless `PHOTOLAB_BENCH_RAW` names a file.
- `testEditedThumbnailRendersUnder20msFromTheCachedBase` (`ThumbnailTests`):
  an exposure recipe rendered over the cached 480 px plain thumbnail, the
  real decoder and renderer; the process's first render warms Core Image
  and is printed beside the gated number, not gated.
- `testPreviewSizedFrameUnderTwentyMilliseconds` (`HistogramTests`): the
  histogram of a preview-sized frame after one warm-up.
- `testRegionStepRendersWithinTheFrameBudget` (`ZoomTests`): a sweep of
  exposure steps rendering a 2600×1600 1:1 window of the 24 MP
  full-resolution master with clarity, sharpening and vignette on; the
  median step must fit one 60 Hz frame.

The source for the render timings is `PHOTOLAB_BENCH_IMAGE` when set (a real
photo, through the loupe's own master decode), else a synthetic 6000×4000
JPEG written once to the temporary directory (`bench24MPImageURL()`).
`PHOTOLAB_BENCH_TARGET` overrides the loupe's long side in pixels.

**Load sensitivity.** These numbers double on a busy box (a sibling build,
Spotlight, another test run). Every timed test reads the 1-minute load
average and prints it beside its number, and every one gates through
`assertFrameBudget` (there is no second load guard): the bound is as
written up to a load of 4 (a clean box idles at 2–4; on 2026-10-15 every red
of the 16 ms gate came at a load of 7.3 or more from sibling builds and every
pass at 5.3 or less, with the render path unchanged), scales with
`load / 4` above it (load 8 is 32 ms), and above a load of 12 a miss throws
`XCTSkip` with the numbers in its message, never a red, because the box
cannot measure a frame budget then. Each gate measures up to three times
and the best sweep counts (a sibling build's compile burst is seconds long
and rarely covers three sweeps; a slower chain misses all three; the `BENCH`
line says "best of n" when it retried), except the two that time a cold
path and so measure once: the 500-JPEG folder and the real RAW, where a
second pass would be warm. A pass at any load stands,
and a miss under the cap is a red whatever the load. So a skipped or scaled timing is
read from its `BENCH` line and re-run on a quiet box before anything is
changed; a documentation or test-only change cannot have caused a red.

## Injected directories

No test touches a user folder, the user's presets or UserDefaults. Every
place the app writes is injected:

- `PresetStore(directory:)`: every test's store points at a temporary
  directory, never `PresetStore.defaultDirectory`.
- `SidecarStore(folder:)` and `Library.open`: the photo folder is a
  temporary directory the test makes and fills with small synthetic images,
  so its `.photolab/` sidecars are the test's own. A source without a
  folder gets `SidecarStore(directory:naming:)` with a temporary directory
  (the fake source in `SourceTests`).
- `Library(rememberFolder: false)`: the opened source and every choice stay
  out of UserDefaults (its `AppSettings` is not `persistent`);
  `Library(rememberFolder:defaults:)` and `AppSettings(defaults:)` take a
  `UserDefaults(suiteName:)` the test removes afterwards when remembering
  is what is tested.
- `PhotosAccess(client:sidecarDirectory:originalsDirectory:)`: the fake
  client and two temporary directories; `PhotosAccess.live` (the real
  client, `~/Library/Application Support/PhotoLab/photos-sidecars/` and
  `~/Library/Caches/PhotoLab/originals/`) is the app's alone. No test calls
  `requestAuthorization`: the permission dialog is the user's click, from
  the bundled app. `AdjustmentDataTests` injects its own fake the same way,
  plus a temporary directory for the JPEGs its saves render.
- `ExportQueue`: `init(remember:settings:worker:)` leaves `remember:` off
  and `settings:` out (the folder and options stay in memory) and takes a `ExportQueue.Worker`, so a test
  can count, slow or fail jobs without rendering; exports that do render go
  into a temporary output directory.
- `Thumbnails`: `init(decode:render:)` takes the decoder and the renderer,
  so a test can count calls, block a decode or report what it saw, and prove
  a neutral recipe never renders.

Each class makes its directories in `setUpWithError` under
`FileManager.default.temporaryDirectory` and removes them in
`tearDownWithError`. Keep it that way: a test that points any of these at a
real folder is a bug.

## Adding an adjustment

The checklist, with the test it ends in:

1. A new `AdjustmentKind` case in `Adjustments.swift`, placed where it
   applies in the chain (kinds render in declaration order, not recipe
   order), with a `section` for the panel, a `label`, a `range` and a
   `format`. A kind that renders together with others joins a `group`.
2. One `stage` branch in `Renderer.swift` (or its parameters in `groupStage`
   for a grouped kind). Nothing else: no second renderer, no special case in
   the preview or the export.
3. One direction test in `ToneSetTests.swift` that moves the slider and
   reads pixels back the way the slider's name says, then the mutant check
   above to show it bites.

The recipe tests then hold on their own: the neutral recipe still lists
every kind once, and the sidecar shape test fails if the kind is missing
from the written file.
