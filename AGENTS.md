# PhotoLab — notes for agents

- SwiftPM package, no Xcode project. Build with `swift build`, run with
  `swift run PhotoLab [folder]`, release bundle with `scripts/bundle.sh`.
  Swift 5 language mode (tools 5.9); macOS 14 minimum. Build with Xcode
  selected (`xcode-select -p` must show Xcode.app): the Command Line Tools
  toolchain lacks the SwiftUIMacros plugin on macOS 27 and fails on `@State`.
- Never write to a photo's original file. Edits live in sidecar JSON
  (`SidecarStore` in `Sidecar.swift`: `<folder>/.photolab/<file>.json`,
  atomic write, a neutral recipe deletes the file); exports go to a separate
  output folder. `Library.setRecipe` is the only path that changes an edit:
  it records the undo step and writes the sidecar. A slider drag wraps its
  changes in `beginEdit` / `endEdit` so the drag is one step and one write.
- Presets (`Presets.swift`): `Preset` is a named recipe with the geometry
  kinds (`AdjustmentKind.geometryKinds`) neutral; `Preset.apply(to:)` keeps
  the target photo's own rotate and crop. `PresetStore(directory:)` is one
  JSON per preset under `PresetStore.defaultDirectory`
  (`~/Library/Application Support/PhotoLab/presets/`); the directory is
  injected, so every test points it at a temp directory and never at the
  user's folder. The starter set is `Preset.starters` (a data table in
  Swift, not a resource bundle: `scripts/bundle.sh` copies only the binary),
  seeded only when the directory does not exist. Applying goes through
  `Library.apply(_:to:)` -> `setRecipe`, never by writing a sidecar.
  `PresetThumbnails.render` is the strip; `Tests/PhotoLabTests/PresetTests.swift`
  has the round-trip, apply-after-reopen and 50 ms thumbnail gate.
- Batch (`Batch.swift`, `Library` "Batch" and "Multi-selection" marks):
  `Library.selection` is the anchor and setting it collapses
  `selectedIDs` to that one photo; `click(_:extending:toggling:)` is the
  path that grows a selection, `batchTargets` the folder-ordered list a
  batch acts on. `SyncMask` (`.look` = all but geometry, `.grade` = look
  minus exposure) + `Recipe.syncing(_:from:)` is the one batch primitive;
  `Library.sync(_:mask:to:)` runs it through `setRecipe` per photo with a
  shared batch tag on the undo steps, and `undo` / `redo` act on every photo
  whose top step carries the selected photo's tag. Never write a second
  batch path that bypasses `setRecipe`. Export: `Exporter.export` is the
  one path: `Renderer.fullResolution` -> `Renderer.render(resize:)` (the
  export resize is the chain's last step, `OutputSize` = exact long side
  or percent, never up) -> `CGImageDestination` in the format
  `ExportOptions` names (JPEG / HEIC with `quality`, TIFF LZW), with the
  source's properties from `ExportMetadata.properties` (orientation 1,
  output pixel dimensions, the source container's own tags dropped) when
  `keepMetadata` is on, written to a `.partial` beside the final name and
  moved into place. `destination(for:in:options:)` is `<stem><suffix>.<ext>`
  and the collision policy: `.number` (the default, `<stem> 2.jpg`),
  `.skip` (returns `.skipped`), `.overwrite` (throws `isTheOriginal`
  rather than replace the photo's own file). `ExportQueue` runs items one
  at a time off the main thread, checks cancellation between items, counts
  `done` / `skipped` / `failures`, and keeps the last folder and options
  (`keep(folder:options:)`, UserDefaults only when `remember:` is on; the
  app passes true, tests never do); `requestExport` puts up `ExportSheet`
  (`ExportSheet.swift`), which calls `start` with the resolved options. Its
  `Worker` is injected so a test can count or slow jobs.
  `Tests/PhotoLabTests/BatchTests.swift` has the 20-photo apply-and-undo
  proof, the mask, copy settings, the selection rules, and the queue's
  completion and cancel; `ExportTests.swift` has quality vs. file size,
  the exact resize (after the crop, never up), the EXIF carry-over with
  orientation reset in all three formats, HEIC / TIFF round trips, the
  collision policy and the untouched original. Every export in a test goes
  to a temp directory; never point one at a real folder.
- Photo ids are the URLs `Library.scan` returns, which resolve symlinks
  (`/var/...` comes back as `/private/var/...`); key recipes by those ids,
  never by a URL you built yourself. `Tests/PhotoLabTests/SidecarTests.swift`
  covers save/reload, reset, undo/redo and the untouched original.
- One render path: `Renderer.apply(_:to:)` in `Renderer.swift` is the Core
  Image chain for preview and export alike. Do not add a second renderer; a
  new adjustment is a new `AdjustmentKind` case (in chain position, with a
  `section` for the panel) plus one `stage` branch plus a direction test in
  `Tests/PhotoLabTests/ToneSetTests.swift`. Kinds apply in `allCases` order,
  not recipe order. Grouped kinds (`AdjustmentKind.Group`: crop, tone, HSL)
  render as one stage in `groupStage`; the tone and HSL lookups are built in
  `ColorCubes.swift` with Accelerate on a reusable workspace (a debug build
  pays ~50 µs per fresh 128 KB array, so no allocations in a build) and
  cached by value in `CubeCache`.
- Core Image gotchas met here: a layer with alpha 0 is dropped by the
  compositing filters (use alpha 1 and multiply, or the stock unsharp mask);
  `CIMix.amount` is clamped to 0…1 (no extrapolation); `CIRandomGenerator`'s
  RGB is premultiplied by its random alpha (skewed dark) but the alpha is
  uniform; the stock unsharp mask and the tone/HSL cubes are applied in
  sRGB gamma space on purpose (wrap with `linearToSRGBToneCurve` /
  `sRGBToneCurveToLinear`, or `colorCubeWithColorSpace`). Spatial radii are
  fractions of the long side so preview and export match.
- `swift test` runs the recipe/chain tests and three timed renders (the basic
  sweep, every slider over an everything-on recipe, the preset strip); set
  `PHOTOLAB_BENCH_IMAGE=<file>` to time a real photo through the loupe path.
  The timing tests are load-sensitive: a box with a load average above ~8
  (Spotlight indexing, other test runs) doubles every number; read `uptime`
  before trusting a red one. A crop or rotate step changes the output size
  and Core Image charges 5–15 ms the first time it meets a size; the test
  gates those kinds on a second pass over the same sizes.
- Keep ImageIO for thumbnails (fast, orientation-aware, reads RAW and HEIC).
- Keyboard shortcuts are global hidden buttons in `ContentView.swift`
  (`HiddenShortcuts`); add new ones there.
- No AI attribution lines in commit messages.
