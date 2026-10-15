# PhotoLab — architecture

How the app is put together, from the source. Every name in backticks is a
type, method or constant in `Sources/PhotoLab/`; the README says what the
app does, this document says how. Four mechanisms carry everything:

1. **One render path.** `Renderer.apply(_:to:)` is the Core Image chain for
   a recipe. The loupe, the preset strip and the export all go through it;
   only the input image and the output size differ.
2. **Edits are data.** A `Recipe` is a list of `Adjustment` values; the
   sidecar persists it, a `Preset` names one, a batch copies parts of one.
3. **One writer.** `Library.setRecipe(_:for:)` is the only path that changes
   a photo's edit: it records the undo step and writes the sidecar.
   `Library.open` and `Library.restore` are the load path: they install a
   recipe read from a sidecar or a Photos asset's adjustment data, with no
   undo step.
4. **One export path.** `ExportQueue` feeds `Exporter.export` one item at a
   time; `Exporter.export` renders through the same chain and writes the
   file per `ExportOptions`.

## 1. One render path

### The chain

`Renderer.apply(_:to:)` (`Renderer.swift`) takes a `Recipe` and a `CIImage`
and returns the adjusted `CIImage`. It walks `AdjustmentKind.allCases`, so
kinds apply in the order the enum declares them (geometry, then exposure and
white balance, tone, color, per-band HSL, detail, effects) whatever order the
recipe happens to list them in. An entry that is disabled or at its neutral
value (`Adjustment.isNoop`) is skipped, so the neutral recipe is the identity.

Some kinds render together as one stage. `AdjustmentKind.Group` names the
three: `crop` (the four edges are one `cropped(to:)`), `tone` (highlights,
shadows, whites, blacks and the five tone-curve points are one per-channel
lookup) and `hsl` (the 24 hue / saturation / luminance sliders are one 3D
color cube). `apply` reaches a group when it meets its first member and
renders it once through `groupStage`, provided any member is not a no-op;
the other members' own `stage` branch is a pass-through.

The two lookups are built on the CPU in `ColorCubes` (`ColorCubes.swift`,
Accelerate): `ColorCubes.toneLUT` samples the tone curve and
`ColorCubes.toneCube` turns it into cube data; `ColorCubes.hslCube` builds
the HSL cube, weighted by each pixel's own saturation so grays never move.
Both are `ColorCubes.dimension` samples per axis and are applied through
`colorCubeWithColorSpace` in sRGB gamma space on purpose, where tone and
lightness read the way the sliders suggest. `CubeCache` keys a built cube by
its parameter values: dragging an unrelated slider reuses the cube, a step of
one of the cube's own sliders builds a new one.

Every spatial parameter in `stage` (the clarity and blur radius, the
sharpening radius, the grain cell, the vignette radius) is a fraction of the
image's own long side, so a preview and an export of the same recipe look the
same at their different sizes.

### The two inputs

- `Renderer.previewMaster(_:maxPixelSize:)` is the loupe's input: an ImageIO
  downsample (`ImageLoading.downsampledCGImage`, fast, orientation-aware,
  reads RAW and HEIC) wrapped as a `CIImage`. `PreviewModel` asks for it at
  `PreviewModel.masterPixelSize` (3200 px on the long side). Behind it,
  `ImageLoading.thumbnail(from:maxPixelSize:)` asks the container for its
  embedded preview first and accepts it only when its long side is at least
  the requested size, otherwise it decodes the image (`ImageLoading.Source`
  says which happened); at the loupe's size that is a decode for most files,
  at the strip's and the grid's sizes a camera RAW's embedded preview usually
  serves.
- `Renderer.fullResolution(_:)` is the export's input: `CIImage(contentsOf:)`
  with the orientation property applied, the whole file.

### Output

`Renderer.render(_:recipe:maxPixelSize:resize:)` is the one place a chain is
run to pixels. It scales the source down to `maxPixelSize` first (never up;
nil renders at source size), applies the recipe, then, if `resize` is given,
sizes the output: `OutputSize` is an exact long side (`longSide`) or a
percentage (`percent`) of the rendered, cropped size, and
`OutputSize.size(fitting:)` returns nil for any target at or above the
rendered size, so an export is never upscaled. That resize is a Lanczos
scale, the last step of the chain, done once. The result is an 8-bit
`CGImage` in the source's color space, returned as `Renderer.Result` with the
wall time of the whole step in `milliseconds` (the loupe's footer and the
tests read it). `render` is synchronous; every caller runs it off the main
thread.

### The loupe

`PreviewModel` (`Preview.swift`) holds one photo's master and renders the
current recipe at the view's pixel size. `PreviewModel.load(_:)` decodes the
master off the main thread; `PreviewModel.request(url:recipe:maxPixelSize:)`
records a request; `pump` runs at most one render at a time and the newest
request replaces any waiting one (latest wins), so a fast slider never queues
stale frames. `PreviewCanvas` (`ContentView.swift`) is the view: it calls
`load` when the photo changes and `request` when the recipe or its own pixel
size changes, and substitutes `Recipe.neutral` while `Library.showBefore` is
on, which is all the Before button does.

Compare mode (`Library.compare`, `Y`) is the same model with a second
request. `PreviewModel.setCompare(_:)` turns it on; from then on each
`request` also records a neutral request of the same url at the same pixel
size (`requestBefore`), which `pump` renders through the same
`Renderer.render` from the same master into `beforeImage` / `beforeURL`.
The canvas passes one half's longest side while compare is on, so Before
and After come out at equal pixel size. A waiting Before goes before a
waiting After (it is asked for once per photo or size, so a drag cannot
starve it), it is not rendered again for a request equal to the one shown
or rendering (a slider move re-renders After only), and it never carries
the clipping overlay; the histogram stays the After frame's. Leaving compare
mode drops `beforeImage` and clears the in-flight request, so a Before
still rendering then finds itself unwanted and is discarded.

### The histogram and the clipping overlay

`Histogram` (`Histogram.swift`) is read off the finished 8-bit preview
frame, never a second render. `Histogram.compute(_:)` runs vImage over the
frame's bytes off the main thread and returns 256 bins per channel (`red`,
`green`, `blue`) and for Rec. 709 luminance (`luminance`), exact integer
counts that sum to `pixelCount`, with two fractions: `highlightClipping`,
the share of pixels with any channel at or above `Histogram.highlightLevel`
(254), and `shadowClipping`, the share with any channel at or below
`Histogram.shadowLevel` (1). `highlightsClipped` and `shadowsClipped` light
the two triangles above `Histogram.warningThreshold` (a tenth of a percent
of the pixels). `PreviewModel` publishes `histogram` after each frame, one
compute in flight and the newest frame winning. The J overlay is one stage
over the same frame: `ClippingOverlay.compose(over:context:)` paints
`ClippingOverlay.blown` (red) over the pixels the highlight rule counts and
`ClippingOverlay.crushed` (blue) over the shadow rule's, every other pixel
byte-identical, so the triangles and the overlay agree pixel for pixel.
`PreviewModel.setClipping(_:)` re-composes the kept plain frame without a
render, and a frame rendered while `showClipping` is on carries the overlay
in the same hop. `HistogramView` (`HistogramView.swift`) draws it at the top
of the adjustments panel; its triangles are buttons on
`Library.showClipping`, the flag `J` toggles.

### The preset strip

`PresetThumbnails.render(master:presets:base:pixelSize:renderer:)`
(`PresetBrowser.swift`) is the same chain at strip size: for each preset,
`Preset.apply(to:)` over the photo's current recipe, rendered through
`Renderer.render` at `PresetThumbnails.cellPixelSize` from a master decoded
at `PresetThumbnails.masterPixelSize`. Requests coalesce like the loupe's.
The grid's thumbnails take the same chain only when there is an edit to
show: `Thumbnails` (`ImageLoading.swift`) is one `NSCache` keyed by
`Thumbnails.Key`, a `PhotoID` and a recipe stored by its render identity
(anything `Recipe.isNeutral` is keyed as `Recipe.neutral`). The plain entry
is the ImageIO downsample at `Thumbnails.pixelSize`, decoded once and kept
as the photo's base; `Thumbnails.thumbnail(for:recipe:)` renders a
non-neutral recipe over that cached base through `Renderer.render` at the
same size and caches the result under its own key, so a slider release, a
batch apply, a sync, an undo or a redo re-keys the visible cells and each
shows its edit after a render of a few milliseconds, without a decode. A
neutral recipe never reaches the renderer. The cell's cancellation is
forwarded into the detached decode and the detached render alike, so a
cell scrolled past costs nothing and nothing is cached for it; the decoder
and the renderer are injected (`Thumbnails.Decoder`, a `PhotoID` in and an
image out; `Thumbnails.Render`, a base image and a recipe in) so a test
can count or block either. Without an injected decoder (the app's
`Thumbnails.shared`) the plain entry follows one rule: a `PhotoID.file` is
the ImageIO downsample, a `PhotoID.asset` is asked of `Thumbnails.source`,
the open `PhotoSource`, which `Library.open(_:)` sets, so a Photos album's
thumbnails come from the same cache through
`PhotosSource.thumbnail(for:maxPixelSize:)`, never a second one. The
loupe's master and the export decode the file the source names for the
photo (`Library.originalFile(for:)`,
`PhotoSource.originalFile(for:)`): a folder photo's own file, known at once
(`Photo.fileURL`), or a Photos asset's cached copy, fetched when the loupe
opens it; `LoupeView` resolves it and hands it to the canvas, the panel and
the strip, with an `OriginalFetch` state (`fetching` shows the thumbnail
under "Downloading original…", `failed` the source's reason) until it is
there.

## 2. Data model

All of it is in `Adjustments.swift`, `Sidecar.swift`, `Presets.swift`,
`Export.swift`, `PhotoSource.swift` and `Photos.swift`.

### `PhotoID`, `Photo` and `PhotoSource`

A photo's identity is a `PhotoID` (`PhotoSource.swift`): `PhotoID.file`,
the file URL of a photo in a folder, or `PhotoID.asset`, a library asset's
identifier (`UUID/L0/001`). Every `Library` map (`recipes`, `marks`, the
undo history, the selection) is keyed by it, and a `Photo` is the id, the
display `name` the source gave it and `Photo.fileURL`, the file when the
id is one (nil for an asset until its source produces a file). The three
places the library shows a photo's name (Copy Settings, the Sync sheet,
the sidecar error) read `Library.name(for:)`, never the id.

Where photos come from is a `PhotoSource`: `title` (the window title),
`photos()` (the grid's order), `sidecars` (the `SidecarStore` its edits
persist to), `thumbnail(for:maxPixelSize:)` (a downsample of the
unadjusted original, synchronous, run off the main thread by `Thumbnails`)
and `originalFile(for:)` (the one file the loupe master and the export
decode; async, since a source may have to fetch it). `FolderSource` is the
folder: `Library.scan` lists it, `SidecarStore(folder:)` keeps the edits
under `.photolab/`, `ImageLoading.downsampled` makes the thumbnails, and a
photo's original is its own file. `Library.open(_:)` takes a source, or a
URL that it wraps in a `FolderSource` (a folder, or a file whose folder
opens with that photo in the loupe), and `Library.open(album:access:)` an
album wrapped in a `PhotosSource`; `Library.source` is the open one and
`Library.folder` its folder when it is a `FolderSource`. A source whose
`photos()` throws is refused like a missing path: the open source stays and
`openError` says why.

### `PhotosSource` and `PhotoKitClient`

A Photos album is a `PhotosSource` (`Photos.swift`): a `PhotosAlbum` (the
collection's identifier, title, image count, and whether it is Recents)
plus a `PhotosAccess`, the three things the source is given rather than
finds: the `PhotoKitClient`, the `sidecarDirectory` and the
`originalsDirectory`. `PhotoKitClient` is everything the source asks of
PhotoKit, so the test fake is complete and no `PHAsset` leaves
`PhotoKitLive`: `authorizationStatus()` (never a prompt),
`requestAuthorization()` (the Allow button and nothing else calls it),
`albums()` (Recents, then the regular albums by title), `assets(in:)`
(images only, oldest capture first: `PhotoKitLive.assetFetchOptions()`),
`thumbnail(for:maxPixelSize:)`, `writeOriginal(of:to:)`, and the three
calls of the adjustment data (below): `hasAdjustments(_:)`,
`adjustment(of:)` and `saveEdit(_:to:render:)`. The live
client needs an app bundle: the system keys Photos access to a bundle
identifier and a usage string, both written by `scripts/bundle.sh`; under a
bare `swift run` it never fetches, and `PhotosAccess.hasBundle` is what the
Welcome view checks before offering the album sheet.

`PhotosSource.photos()` throws `PhotosError.notAuthorized` until the status
reads (`PhotosAuthorization.canRead`: authorized or limited), so `Library`
refuses the open and nothing is fetched; it lists the album through the
client and names each photo by its original's file name
(`PhotosAsset.originalFilename`). Thumbnails come from Photos' own cache:
the live client asks `PHImageManager` synchronously (480 px aspect-fit,
version unadjusted, high quality, fast resize, iCloud allowed) from inside
`Thumbnails`' detached decode, and a request cancelled while it waits is
dropped the same way as a file's. The original is the only input, as for a
folder: `PhotosSource.originalFile(for:)` hands the asset to an
`OriginalsCache`, which writes the asset's original resource once (the RAW
of a RAW+JPEG pair when there is one, `PhotoKitLive.originalResource(of:)`,
else the photo) through `PHAssetResourceManager` into
`<originalsDirectory>/<safe-id>.<ext>`, `safe-id` the identifier with its
slashes as underscores (`SidecarStore.flatName`) and `ext` the original file
name's; the write goes to a `.part` file moved into place when complete, so
a copy on disk is always whole, two concurrent asks share one write, and a
copy that exists is returned at once by any later source. The directory is a
cache (`~/Library/Caches/PhotoLab/originals/` in the app,
`PhotosAccess.defaultOriginalsDirectory`): deleting it costs a download,
never an edit, and `Renderer.previewMaster`, `Renderer.fullResolution` and
the export's metadata read the copy like any file. Sidecars of Photos
assets take the flat naming under `PhotosAccess.defaultSidecarDirectory`
(`~/Library/Application Support/PhotoLab/photos-sidecars/`). Photos' own
edits are not stacked: the unadjusted original is what the grid, the loupe
and the export show.

### Adjustment data (`PhotosAdjustment`)

Save to Photos writes a PhotoLab edit into the library non-destructively.
`PhotosAdjustment` is the edit as Photos stores it: format identifier
`local.photolab.recipe`, format version `Sidecar.currentVersion`, and as
data the recipe-only sidecar JSON (`SidecarStore.encode`, no flag or
rating). `Library.saveToPhotos()` (enabled by `canSaveToPhotos`: the
anchor is an edited photo of a Photos album and no save is running; the
state is `photosSave`) closes an open drag and calls
`PhotosSource.saveEdit(_:for:name:)`, which takes the cached original
(`originalFile(for:)`) and hands `PhotoKitClient.saveEdit` the data and a
render closure: `Exporter.write` with `PhotosSource.saveOptions` (JPEG,
full size, metadata kept), the same render and write path as an export.
`PhotoKitLive.saveEdit` asks a content-editing input with
`canHandleAdjustmentData` = `PhotosAdjustment.canHandle` (PhotoLab's
identifier at a version this build reads), builds a
`PHContentEditingOutput` with the data, runs the closure into
`renderedContentURL(for: .jpeg)` (never reading the input's own image,
which for another app's edit is that app's render) and commits
`PHAssetChangeRequest(for:).contentEditingOutput` in one `performChanges`.
Photos keeps the original (Revert to Original) and one edit per asset, so a
second save replaces the first. The sidecar is untouched: it is the
primary record, and a revert in Photos does not change it.

Reading back is lazy and per photo. When the loupe opens a photo,
`Library.recoverRecipe(for:)` runs; for a Photos asset with no sidecar, no
recipe and no unreadable mark it asks `PhotosSource.recoverRecipe(for:)`,
which returns nil unless reading is allowed and the asset
`hasAdjustments` (so an unedited asset never costs a content-editing
input), then `adjustment(of:)` (the live client accepts PhotoLab's
identifier at any version) and `PhotosAdjustment.recipe()`: nil for another
app's identifier, `SidecarError.unsupportedVersion` for a format version or
a JSON version above `Sidecar.currentVersion`. A recipe is installed
through `Library.restore(_:for:)` (the load path: no undo step, the sidecar
written so the next open reads JSON) only if, after the read, the photo is
still in the listing of the same store and still has no sidecar, recipe,
history or open drag, so an edit made meanwhile wins. A newer version puts
the photo in `unreadableSidecars` with a `sidecarError`; a read that fails
leaves the photo as it was.

### `AdjustmentKind`

One case per slider, declared in chain order; `Codable` by its raw string
("exposure", "cropLeft", "hueRed", and so on), which is what a sidecar stores.
Each kind has a `label`, a `range`, a `format`, a `section` (the panel
section: `basic`, `color`, `curve`, `hsl`, `detail`, `effects`, `geometry`)
and a `neutral` value, the value at which it does nothing (zero for every
kind). `AdjustmentKind.geometryKinds` is rotate plus the four crop edges: the
kinds a preset never carries and a `.look` sync never copies. `group` is the
render grouping above; `hsl` and `curveX` give the HSL kinds their channel
and band and the curve kinds their x position.

### `Adjustment`

One entry of a recipe: `kind`, `value` (in the slider's own units: EV,
degrees, percent of the frame, or a -100…100 / 0…100 amount) and `enabled`.
The checkbox next to a slider flips `enabled` without losing `value`.
`isNoop` is true when applying the entry would change nothing: disabled, or
at the kind's neutral value.

### `Recipe`

The whole edit of one photo: `adjustments`, an array of `Adjustment`.
`Recipe.neutral` is every kind at its neutral value, enabled. The subscript
by kind reads the entry for that kind, or a neutral one when the kind is
missing (an older sidecar), and writes in place or appends; `effective(_:)`
is the value the renderer uses (neutral when disabled). `normalized` is the
canonical form: every kind present exactly once, in chain order, so two
recipes that render the same compare equal whatever a sidecar listed;
presets and batch results are built in that form.

Two questions about a recipe have two answers. `isNeutral` is the render
side: true when every entry is a no-op, so applying the recipe changes
nothing. `isDefault` is the edit side: true when `normalized` equals
`Recipe.neutral`, every kind at its neutral value and enabled. They differ
on a disabled-only edit, a value kept but switched off: it renders as the
identity, so it is neutral, but it is not the default, so it stays in
memory, keeps its sidecar, counts as edited and comes back when the checkbox
is ticked again. Everything below that asks "is there an edit" asks
`isDefault`.

### `Sidecar` and `SidecarStore`

A `Sidecar` is the on-disk form of one photo's edit: `version`
(`Sidecar.currentVersion`), `original` (the photo's file name, for a human
reading the directory), `updated` and `recipe`, plus two optional keys,
`flag` and `rating`, the culling marks (`Marks`, below), absent when unset
so a file written before they existed decodes unchanged. `SidecarStore` reads and
writes the sidecars of one source: a `directory` and a `SidecarStore.Naming`
from a `PhotoID` to a file name in it (`SidecarStore.relativeName(for:)`).
A folder's store, `SidecarStore(folder:)`, is `<folder>/.photolab/`
(`SidecarStore.directoryName`, `SidecarStore.fileExtension`) with the
folder naming, `<path relative to the folder>.json`: the file name keeps
the original's extension, so `IMG_0001.JPG` and `IMG_0001.HEIC` never share
one, and a photo in a subfolder keeps its relative path under `.photolab/`.
The directory is hidden, so `Library.scan` (which skips hidden entries)
never lists it, and deleting it wipes every edit in the folder. A source
without a folder injects its own directory with the flat naming
(`SidecarStore(directory:naming:)`, `SidecarStore.Naming.flat`):
`<id with every / as _>.json`, so the asset `UUID/L0/001` is
`UUID_L0_001.json` (`SidecarStore.flatName`). The JSON, the version gate and the backup rule
are the same under both namings; every method takes a `PhotoID`, and the
URL forms (`SidecarStore.url(for:)` of a file URL, and the rest) are
`PhotoID.file` of it.

- `SidecarStore.save(_:marks:for:name:now:)` writes the recipe and the marks
  atomically (temp file and rename); `name` is the `original` the file
  records (the photo's name from its source; the id's own when not given). The file is removed instead when there
  is nothing to keep, the default recipe (`Recipe.isDefault`) and no marks,
  so a reset of an unmarked photo leaves no trace while a flag or rating on
  a default recipe keeps its file; a recipe that only differs by a disabled
  entry is still written. `SidecarStore.save(_:for:now:)` is the
  recipe-only form: it keeps whatever marks the file already holds.
- `SidecarStore.read(for:)` returns the whole sidecar, nil when there is
  none, and throws when the file cannot be decoded, so the caller can tell
  "no edit" from "an edit this build cannot read"; `SidecarStore.load(for:)`
  is its recipe. `SidecarStore.decode` also refuses a `version` above
  `Sidecar.currentVersion` (`SidecarError.unsupportedVersion`): a file a
  newer build wrote reads as unreadable rather than losing the fields this
  build does not know. `loadAll(for:)` returns the non-default recipes, the
  non-empty marks and the list of unreadable photos. `Library` shows those
  as neutral, reports the first in `sidecarError`, and leaves the file alone
  until the user edits that photo.
- An unreadable file is never overwritten. Before the first write or
  removal at its path, `save` calls `SidecarStore.backUpIfUnreadable`, which
  moves it to `<file>.unreadable-<yyyymmdd-hhmmss>` beside the new sidecar
  (`UnreadableBackup.moveAside`, `Sidecar.swift`; a suffix when that second
  is taken). The backup keeps the original bytes, is never deleted by the
  app, and is listed by neither store (its extension is not `json`) nor the
  folder scan (`.photolab` is hidden).

The shape of a sidecar, with the field names from the structs above and the
encoder settings in `SidecarStore.save` (pretty-printed, keys sorted, dates
ISO 8601, slashes unescaped); the real file lists every kind:

```json
{
  "flag" : "pick",
  "original" : "IMG_0001.JPG",
  "rating" : 3,
  "recipe" : {
    "adjustments" : [
      { "enabled" : true,  "kind" : "exposure",   "value" : 0.3 },
      { "enabled" : true,  "kind" : "highlights", "value" : -20 },
      { "enabled" : false, "kind" : "vignette",   "value" : -25 },
      { "enabled" : true,  "kind" : "cropLeft",   "value" : 5 }
    ]
  },
  "updated" : "2026-10-15T20:14:07Z",
  "version" : 1
}
```

### `Marks`

What culling leaves on a photo (`Sidecar.swift`): a `Marks.Flag`, `pick` or
`reject` or none, and a `rating` clamped to 0…`Marks.maxRating`;
`Marks.isEmpty` is neither. Marks sit beside the recipe in the sidecar and
never inside it: they are not an edit, so they are not undo steps and never
enter a `Recipe`, a `Preset` or a `SyncMask` (the types do not meet).
`Library.marks` holds the non-empty ones for the open folder;
`Library.setFlag(_:for:)` and `Library.setRating(_:for:)` change them for a
list of photos and write each sidecar at once through the same `persist`
that writes a recipe, so a reset keeps the flag and a flag keeps a default
recipe's file. `PhotoFilter` (`Library.swift`) reads them for the grid.

### `Preset` and `PresetStore`

A `Preset` is a named recipe: `version` (`Preset.currentVersion`), `name`,
`updated`, `recipe`. Its initialiser `Preset(name:from:updated:)` normalises
the recipe and sets every geometry kind to neutral, so a look travels and a
crop or rotation does not. `Preset.apply(to:)` is the inverse at apply time:
the preset's look over the photo's own geometry, taken from the current
recipe. `Preset.matches(_:)` tells the strip which preset the photo already
shows. `Preset.starters` is the starter set, a data table of slider values on
the neutral recipe with a fixed `updated` date so the files are identical
across installs.

`PresetStore` is one JSON file per preset, `<directory>/<name>.json`, with
the two characters a file name cannot carry replaced; the directory is
injected (`PresetStore(directory:)`, default `PresetStore.defaultDirectory`
under the user's Application Support), so tests never touch the user's
folder. `save(_:)` validates the name (`PresetStore.validated`), writes
atomically and replaces a preset of the same name, but refuses a different
name that would map onto the same file (`PresetError.fileNameCollision`).
`rename(_:to:)` never silently replaces another preset, where "another" is
by file identity: on a case-insensitive volume a rename that changes only
the case of the name (`Mine` → `mine`) is the preset's own file, re-spelled
and rewritten in place. `PresetStore.decode`
refuses a `version` above `Preset.currentVersion`
(`PresetError.unsupportedVersion`), so `loadAll()` returns the readable
presets sorted by name plus the files it could not decode, which are left
alone; `PresetStore.exists` is "a file is stored under this name" whether or
not this build can read it, so an undecodable preset is the user's, never
an empty slot. `save` over such a file moves it aside first, the same
`UnreadableBackup` as a sidecar's, and never replaces it. `seedStartersIfMissing()` writes `Preset.starters` only
when the directory does not exist yet, so a starter the user deleted stays
deleted; `writeStarters()` is the strip's Restore Starter Presets.
`PresetLibrary` is the store read into memory for the views, re-read after
every change, with the last error for the panel to show.

### `ExportOptions`

One value per export run, carried unchanged through the queue to every item:

- `format`, an `ExportOptions.Format`: `jpeg`, `heic` or `tiff`, each with
  its `fileExtension`, `utType` and `isLossy` (TIFF is lossless LZW, so
  `quality` means nothing to it).
- `quality`, clamped to `ExportOptions.qualityRange` by `clampedQuality`.
- `resize`, an optional `OutputSize`; nil writes the rendered size.
- `suffix`, appended to the original's stem (`fileName(for:)` gives
  `<stem><suffix>.<ext>`), cleaned of anything a file name cannot hold.
- `collision`, an `ExportOptions.Collision`: `number`, `skip` or
  `overwrite` (section 4).
- `keepMetadata`, whether the source's camera metadata travels.

`ExportQueue` keeps the last run's folder, target kind, Photos album and
options between runs, and in UserDefaults across launches when it was made
with `remember` on (the app passes true; tests never do).

### `ExportTarget`

`ExportTarget` (`Export.swift`) is where a run goes: `.folder(URL)` or
`.photosLibrary(album: String?)` (nil = the library only;
`ExportTarget.defaultAlbum` is "PhotoLab"). `album(from:)` turns the sheet's
field into an album (trimmed, empty = nil) and `displayName` is what the
export bar names.

## 3. The edit path

`Library` (`Library.swift`) holds the open source (`Library.source`, a
`PhotoSource`; a folder through `FolderSource`, an album through
`PhotosSource`): its photos, the selection,
and `recipes`, the edits of the source keyed by `PhotoID`, mirrored to the
source's sidecars. `Library.open(_:)` fills it from a source, or from a URL
(a folder, or a file's folder with that file in the loupe); the source is
listed and every sidecar read (`SidecarStore.loadAll`) before the first
frame, and the selection, the open drag and the undo history are reset. A
path that does not exist, or a source whose listing fails, is refused: the
current source and selection stay and `openError` says why, so a mistyped
launch argument never opens its parent or the working directory.
Every change to an edit goes through one method.

### `Library.setRecipe(_:for:)`

The only writer. Given a recipe that differs from the photo's current one, it
pushes the current recipe onto that photo's `EditHistory` as the undo step,
replaces the recipe in memory (only the default recipe, `Recipe.isDefault`,
is dropped from `recipes`, which is what `isEdited(_:)` reads; a
disabled-only recipe keeps its values there) and writes the sidecar at once through
`SidecarStore.save`; a write that fails lands in `sidecarError` for the
panel. `resetRecipe(for:)` is `setRecipe` with `Recipe.neutral`, so a reset
is one undo step and removes the sidecar. Applying a preset to one photo,
`Library.apply(_:to:)`, is `setRecipe` with `Preset.apply(to:)`, so it undoes
like a slider move. The adjustments panel binds every slider and checkbox to
`setRecipe`; the Presets menu, the strip, Sync and Paste all end in it. The
load path is the one other way a recipe lands in `recipes`: `open` reads
the sidecars, and `restore(_:for:)` installs a recipe recovered from a
Photos asset's adjustment data and writes its sidecar, neither recording
a step. There is no path that writes a sidecar or a recipe around them.

### A drag is one step

A slider drag wraps its changes in `Library.beginEdit(_:)` and
`Library.endEdit(_:)`. While an edit is open on a photo, `setRecipe` only
moves the in-memory recipe (the loupe follows live) and records nothing; on
`endEdit`, if the recipe moved, the value at `beginEdit` becomes the one undo
step and the sidecar is written once. At most one edit is open at a time:
`beginEdit` on another photo closes the open one first (its drag persisted
and made a step), and `endEdit` closes whatever edit is open regardless of
the id it is handed, so a loupe photo that changes mid-drag cannot leave an
edit on the unsaved path. `undo` and `redo` drop an open edit too.

### Undo and redo

`EditHistory` is per photo, kept for the open folder: an `undo` and a `redo`
stack of whole recipes (a recipe is a few hundred bytes, so snapshots beat
deltas), capped at `Library.maxUndoDepth`. Each `Step` carries the recipe to
go back to and an optional batch tag. `Library.undo()` and `Library.redo()`
act on the selected photo; when its top step carries a batch tag, every photo
whose top step carries the same tag goes with it, and a photo edited again
since keeps its later edit until that is undone first.

### Batch

`SyncMask` (`Batch.swift`) is a set of kinds: `.look` is every kind but
geometry (what applying a preset does), `.grade` is the look without
exposure (each photo keeps its own brightness), `.everything` and `.nothing`
are the sheet's All and None. `Recipe.syncing(_:from:)` is the one batch
primitive: the receiver with every kind in the mask taken from the source,
value and enabled flag alike, the other kinds kept, in normalized form.

`Library.sync(_:mask:to:)` runs that primitive over the target photos,
each through `setRecipe` with one shared batch tag (a `UUID` made for the
call), skipping a photo the sync would not change and returning how many
changed; because the tag is shared, `undo` from any photo of the batch takes
the whole batch back. `Library.apply(_:mask:to:)` applies a preset to many
photos as the same operation: `sync` with the preset's recipe and the mask
minus the geometry kinds. Sync Settings (`requestSync`, the anchor's recipe
onto the other selected photos) and Paste Settings (`requestPaste`, the
recipe `copySettings(from:)` remembered) both put up a `SyncRequest`, which
the `SyncSheet` turns into one `sync` call with the mask the user ticked;
`batchTargets` is the folder-ordered list a batch acts on.

## 4. Export pipeline

### `ExportQueue`

`ExportQueue` (`Batch.swift`) is one per app. `requestExport(_:)` puts up the
options sheet for a list of `ExportQueue.Item` (a source URL, its recipe and
`protected`, the open library's originals, from `Library.exportItems(for:)`,
which snapshots the recipes at that moment: an edit made while the sheet is
up or the queue runs does not change what is written for a photo already in
it; `protected` is every photo's own file plus the files resolved for the
export, so a Photos original's cached copy is in it too); the sheet calls
`keep(target:options:)` and then `ExportQueue.start(_:to:options:)`
(`keep(folder:options:)` and `start(_:into:options:)` are the folder
forms, kept as wrappers). `start` runs the items in
order in one task: each item is handed to the `Worker` on a detached task
off the main thread, one at a time, and `Task.isCancelled` is checked before
each item, so `cancel()` stops after the file in flight and what is written
stays. Progress is `total`, `done` (files written), `skipped` (left alone
under the Skip policy), `failures` (one `Failure` per item that threw, with
its source and message), `current` (the photo in flight) and `state`
(`running`, then `finished` or `cancelled`; `dismiss()` returns it to
`idle`). The default `Worker` is `Exporter.export`, handed each item's
source, recipe and `protected` set; it is injected so a test can count or
slow jobs without rendering.

A Photos target runs the same `Worker` (so format, quality, resize and
metadata take the one path) into a per-run directory under
`stagingDirectory` (`$TMPDIR/PhotoLab-export/` by default), with the
collision policy forced to `.number`; each written file is handed to the
queue's `PhotosWriter` and removed whether or not the import worked, and
the run's directory is removed when the run ends. A new asset's
`localIdentifier` is appended to `imported` and counted in `done`; a
writer error is a `Failure` and the run goes on. `target` is the run's,
which the export bar names (Show in Finder for a folder, Open Photos for
Photos).

### `PhotosWriter`

`PhotosWriter` (`Photos.swift`) is everything an export to Photos asks of
PhotoKit: `authorizationStatus()`, `requestAuthorization()` (the export
sheet's Allow Access… button, the only prompt) and
`importImage(at:intoAlbum:)`, which returns the new asset's identifier.
`PhotoKitLive` implements it with one `performChanges`:
`PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL:)`, and the
placeholder added through `PHAssetCollectionChangeRequest` to the first
regular album with that title (`regularAlbum(titled:)`) or to one created
with `creationRequestForAssetCollection(withTitle:)`. It throws
`PhotosError.notAuthorized` before touching the library when reading is not
allowed. Every export is a NEW asset: a Photos-sourced photo comes back
beside its original, which is never changed.

### `Exporter.export`

`Exporter.export(_:recipe:into:options:protected:renderer:)` (`Batch.swift`) writes
one photo:

1. `Exporter.destination(for:in:options:)` names the file:
   `<stem><suffix>.<ext>` from `ExportOptions.fileName(for:)`. Under
   `.number` (the default) it is the next free name when that one is taken,
   `<stem> 2.jpg`, `<stem> 3.jpg`, …, so nothing is ever replaced, not even
   the original when exporting into its own folder. Under `.skip` and
   `.overwrite` it is the plain name whether or not it exists.
2. If the file exists: `.skip` returns the `.skipped` outcome
   (`Exporter.Outcome`) without rendering; `.overwrite` first resolves both paths and throws
   `Exporter.Failure.isTheOriginal` when the destination is the photo's own
   file, then throws `Exporter.Failure.isALibraryOriginal` when it is any
   file of `protected` (`Exporter.isSameFile`: the same resolved path or the
   same `fileResourceIdentifier`, so a case variant or a hard link counts).
   Those are the writes the app refuses; nothing is rendered or written.
3. `Renderer.fullResolution` decodes the original, and `Renderer.render`
   applies the recipe with `resize` from the options, the resize as the
   chain's last step (section 1).
4. The output properties: when `keepMetadata` is on,
   `ExportMetadata.properties(of:outputWidth:outputHeight:)`, every property
   ImageIO reads from the source (TIFF make and model, the EXIF block, GPS,
   IPTC) with what described the source container corrected or dropped:
   orientation 1 at the top level and in the TIFF block (the render is
   already upright), the EXIF pixel dimensions set to the output's, the
   source format's own dictionaries and its compression and photometric tags
   removed. Then the lossy quality for JPEG and HEIC, and LZW compression for
   TIFF.
5. A `CGImageDestination` of the format's `utType` writes to a hidden
   `.partial` file beside the final name (`.<name>.<uuid>.partial`); only
   when it finalizes is the file moved into place (replacing the existing
   file under `.overwrite`). The partial is removed on every exit, so a
   failed or cancelled export leaves no half file. The outcome is
   `.written` with the URL.

Steps 3 to 5 are `Exporter.write(_:recipe:to:options:renderer:)`, which a
Save to Photos also calls for the JPEG PhotoKit asks for (section 2,
Adjustment data).

## 5. The picture

```
   original file (never written; PhotoSource.originalFile(for:),
        |          a folder photo's own file, or a Photos asset's copy
        |          in <Caches>/PhotoLab/originals/ via OriginalsCache)
        |  ImageIO downsample                       CIImage(contentsOf:)
        |  Renderer.previewMaster                   Renderer.fullResolution
        v                                                  v
   +------------------------------------------------------------------+
   |  Renderer.apply(recipe)   AdjustmentKind.allCases order,          |
   |                           grouped stages via ColorCubes/CubeCache |
   |  Renderer.render          fit maxPixelSize, then OutputSize last  |
   +------------------------------------------------------------------+
        |                        |                         |
        v                        v                         v
   PreviewModel            PresetThumbnails           Exporter.export
   -> PreviewCanvas        -> PresetStrip             -> CGImageDestination
   (loupe, latest wins)    (strip, same chain)        -> .partial -> file
                                                      (ExportQueue, one at a time)

                 ^ recipe
                 |
        Library.setRecipe(_:for:)   <- the only writer: undo step, then sidecar
                 ^        ^        ^
                 |        |        |
            slider /   Preset   SyncMask + Recipe.syncing
            checkbox   .apply   (Library.sync / Library.apply(_:mask:to:),
            (beginEdit (to:)     one batch tag, undo takes the batch back)
             ..endEdit)
                 |
                 v
        SidecarStore  <folder>/.photolab/<file>.json   (atomic; recipe + marks;
                      or <App Support>/PhotoLab/photos-sidecars/<safe-id>.json
                                                        default and unmarked = deleted)
        PresetStore   <presets dir>/<name>.json        (reads feed Preset.apply)
```

Sidecars, presets and batches reach a photo's recipe only through
`Library.setRecipe`; the renderer reads recipes and never writes one; the
original file is read by both inputs and written by nothing.
