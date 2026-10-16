# PhotoLab — notes for agents

The rules, with a pointer to where each mechanism is documented once:
`README.md` (what the app does, keys, on disk),
`Documentation/Architecture.md` (the render path, data model, edit path and
export pipeline), `Documentation/Features.md` (each screen to its types and
what it writes) and `Documentation/Testing.md` (what the suite proves, how
to run it, the timing tests, adding an adjustment).

## Build

- SwiftPM package, no Xcode project. `swift build`, `swift run PhotoLab
  [folder]`, `swift test`, `scripts/bundle.sh` for the release bundle. Swift 5
  language mode (tools 5.9); macOS 14 minimum. Build with Xcode selected
  (xcode-select -p must print a path inside Xcode.app): the Command Line Tools toolchain
  lacks the SwiftUIMacros plugin on macOS 27 and fails on `@State`. (README,
  Run.)

## Rules

- **Never write to a photo's original file.** Edits live in sidecar JSON
  (`SidecarStore`, `<folder>/.photolab/<file>.json`, atomic; the file goes
  only when the recipe is the default and the photo has no flag or rating,
  a disabled-only edit keeps it); exports go to a separate output folder,
  and an export that would land on the original throws
  (`Exporter.Failure.isTheOriginal`). A sidecar or preset file this build
  cannot decode (damaged, or a `version` too new) is never overwritten: the
  store moves it to `<file>.unreadable-<stamp>` first (`UnreadableBackup`)
  and never deletes a backup. (Architecture 2 and 4.)
- **Marks are not edits.** A flag or rating (`Marks`) rides in the sidecar
  beside the recipe through `Library.setFlag(_:for:)` /
  `Library.setRating(_:for:)`: never an undo step, never inside a recipe, a
  preset, copied settings or a sync mask. Every selection path walks
  `Library.visiblePhotos`; a photo the filter hides is never in
  `batchTargets`. (Architecture 2, Marks; Features, Flags and ratings.)
- **`Library.setRecipe` is the only path that changes an edit.** It records
  the undo step and writes the sidecar; a slider drag wraps its changes in
  `beginEdit` / `endEdit` so the drag is one step and one write. Presets
  apply through `Library.apply(_:to:)` -> `setRecipe`, never by writing a
  sidecar. `open` and `restore` are the LOAD path: they install a recipe
  read from a sidecar or from a Photos asset's adjustment data
  (`Library.recoverRecipe`) and record no step; there is no other path that
  writes a recipe or a sidecar. (Architecture 3.)
- **One render path.** `Renderer.apply(_:to:)` is the Core Image chain for
  the loupe, the preset strip and the export alike; do not add a second
  renderer. A new adjustment is a new `AdjustmentKind` case in chain
  position with a `section`, one `stage` branch, and one direction test in
  `Tests/PhotoLabTests/ToneSetTests.swift`, shown to bite with a local
  mutant. (Architecture 1; Testing, Adding an adjustment.)
- **No second batch path.** `SyncMask` + `Recipe.syncing(_:from:)` through
  `Library.sync(_:mask:to:)` is the one batch primitive (one shared batch
  tag, so undo takes the batch back); applying a preset to many photos is
  the same call, and so is Auto on many photos (`Library.sync(_:mask:)`, a
  source per photo under the one tag). (Architecture 3, Batch.)
- **Injected directories.** `PresetStore(directory:)`,
  `SidecarStore(folder:)`, `CollectionStore(directory:)` (through
  `Library(collections:)`), `Library(rememberFolder:)`, `ExportQueue`'s
  `Worker`, `remember:`, `photos:` (the `PhotosWriter`) and
  `stagingDirectory:`, `Thumbnails`' decoder and renderer, `PhotosAccess` (the
  `PhotoKitClient`, the sidecar and originals directories). Every test
  points them at a temporary directory and never at a user folder or
  UserDefaults; the app alone passes the real ones. (Testing, Injected
  directories.)
- **PhotoKit only through `PhotoKitClient` and `PhotosWriter`**
  (`Photos.swift`). No `PHAsset` outside `PhotoKitLive`; nothing fetches
  before `PhotosAuthorization.canRead`; `requestAuthorization` is called
  from a sheet's Allow button alone (the album sheet's, the export sheet's),
  never at launch and never from a test (the real tests `XCTSkip` unless
  already authorized; the ones that import or edit also need
  `PHOTOLAB_PHOTOS_WRITE=1`). Originals are copied once into the Caches
  directory and read from there; the library is written only by an export
  to Photos (new assets) and by Save to Photos (`PhotoKitClient.saveEdit`:
  the asset's edit, PhotoLab's adjustment data plus a JPEG rendered from
  the cached original through `Exporter.write`, never from the input's own
  image). (Architecture 2, PhotosSource and adjustment data; 4,
  PhotosWriter.)
- **A collection member's edit lives in its own folder.** `Library.persist`
  writes through `PhotoSource.sidecars(for:)` and `open` reads through
  `loadSidecars(for:)`; `CollectionSource` routes each member to
  `SidecarStore(folder: member.root)`. Never write a photo's sidecar
  through `source.sidecars` directly. (Features, Collections.)
- **Photo ids are the URLs `Library.scan` returns** (symlinks resolved:
  `/var/...` comes back as `/private/var/...`). Key recipes by those ids,
  never by a URL you built yourself. (Features, Grid.)
- **Keep ImageIO for thumbnails** (fast, orientation-aware, reads RAW and
  HEIC). The embedded-preview size rule and the cancellation forwarding are
  in `ImageLoading.swift`. An edited photo's cell is that same cached 480 px
  decode run through `Renderer.render` (`Thumbnails.thumbnail(for:recipe:)`,
  one cache keyed by photo and recipe; a recipe that is `Recipe.isNeutral`
  never renders): never a fresh decode through the renderer, never a second
  chain. (Features, Grid.)
- **Clipping is counted on the frame's own bytes.** `Histogram`
  (`Histogram.swift`) is computed from the rendered 8-bit preview frame,
  never a second render: a pixel is blown when any channel is at or above
  `Histogram.highlightLevel` (254) and crushed when any channel is at or
  below `Histogram.shadowLevel` (1), and `ClippingOverlay.compose(over:context:)`
  paints exactly those pixels (red, blue) over the finished frame, so the
  two triangles and the J overlay count the same pixels. Change the rule in
  both or neither. Auto (`AutoTone`) is the one other `Histogram` reader and
  renders its own frame on purpose: the recipe with the six Basic kinds at
  neutral, so a second Auto reads the same input. (Architecture 1, The
  histogram and the clipping overlay.)
- **Cube builds allocate nothing.** The tone and HSL lookups are built in
  `ColorCubes.swift` on a reusable workspace; a debug build pays for every
  fresh array in that hot path. (Architecture 1, The chain.)
- **Starter presets are data in Swift** (`Preset.starters`), not a resource
  bundle: `scripts/bundle.sh` copies only the binary. (Architecture 2,
  Preset.)
- **Core Image gotchas met here:** a layer with alpha 0 is dropped by the
  compositing filters (use alpha 1 and multiply, or the stock unsharp mask);
  `CIFilter.mix()`'s `amount` is clamped to 0…1 (no extrapolation); `CIFilter.randomGenerator()`'s
  RGB is premultiplied by its random alpha (skewed dark) but the alpha is
  uniform; the stock unsharp mask and the tone/HSL cubes are applied in sRGB
  gamma space on purpose (wrap with `linearToSRGBToneCurve` /
  `sRGBToneCurveToLinear`, or `colorCubeWithColorSpace`). Spatial radii are
  fractions of the long side so preview and export match.
- **Timing tests are load-sensitive.** Read `uptime` before trusting a red
  one; `PHOTOLAB_BENCH_IMAGE` times a real photo. (Testing, The timed
  renders.)
- **Every key is one `AppCommand` entry** (`AppCommand.all`,
  `Commands.swift`); the menus and `HiddenShortcuts` are built from it, and
  no `.keyboardShortcut` with a key is typed anywhere else (`CommandsTests`
  checks). A bare key (no modifiers) is bound on `HiddenShortcuts` only and
  named in its menu item's title, never a menu key equivalent, so it cannot
  take a letter from a sheet's text field. (Features, Menus and shortcuts.)
- No AI attribution lines in commit messages.
