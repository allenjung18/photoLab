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
- `swift test` runs the recipe/chain tests and two timed renders (the basic
  sweep, and every slider over an everything-on recipe); set
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
