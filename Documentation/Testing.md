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
skips; one test skips by design (the real-RAW timing, below). The timed tests
print a `BENCH` line with their numbers beside the verdict; read it, not only
the pass.

## What each file proves

- `RendererTests.swift` — the recipe model (every kind once, in chain order;
  JSON round trip), the neutral recipe is the identity, a disabled entry
  changes nothing, the direction of exposure, temperature, tint and
  saturation, the preview fit (down, never up), and the timed slider step on
  a 24 MP photo.
- `ToneSetTests.swift` — the direction tests for the whole tone set (below),
  the sidecar shape holding one entry per kind, and the timed sweep of every
  slider over an everything-on recipe.
- `SidecarTests.swift` — a recipe saved for a photo comes back when the
  folder is opened again in a new `Library`, two originals that differ only
  by extension never share a sidecar, the original is untouched, the default
  recipe removes the file, an unreadable sidecar throws and is not
  overwritten, a sidecar from a newer build is refused and kept as the
  `.unreadable-<stamp>` backup of the next save, a junk sidecar survives an
  edit through the `Library` as that backup, undo and redo walk the history
  and persist each step, and a slider drag is one undo step written once at
  the end.
- `EditStateTests.swift` — `Recipe.isNeutral` versus `Recipe.isDefault`: a
  disabled-only edit renders as identity but is still an edit, in memory and
  on disk; `Library.endEdit` closes whatever edit is open and `beginEdit` on
  another photo closes the first; `Library.open` of a missing path (or a
  flag-like argument) opens nothing and keeps the current folder.
- `SourceTests.swift` — the `PhotoSource` seam: a fake source of three
  assets opens in its own order with its names and title, a recipe on an
  asset persists under the flat naming (`A/L0/001` as `A_L0_001.json` in
  the injected directory) and reloads through a fresh `Library`, export
  items and the loupe take their file from the source, a source whose
  listing fails is refused and the open folder stays, a folder opens
  through `FolderSource` with its sidecars at `.photolab/<relative
  path>.json`, the two namings map ids to files, and `PhotoID` round trips
  through JSON and keys one thumbnail cache.
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
  validated, rename keeps the recipe and refuses a taken name, an unreadable
  preset file is listed and left alone, an undecodable preset is not an
  empty slot and becomes the backup of a save (Restore Starters included),
  a preset from a newer build is refused, listed unreadable and kept on
  save, a fresh directory is seeded once,
  `PresetLibrary` reports errors and recovers, a saved preset applied to
  another photo after a reopen reproduces the edit, applying the preset a
  photo already shows is no step, and the timed strip.
- `BatchTests.swift` — `Recipe.syncing` takes only the masked kinds, a
  preset applied to a multi-selection writes one sidecar per photo and one
  undo takes them all back, a later single edit sits on top of a batch, the
  grade mask keeps each photo's own exposure and crop, the click / shift /
  command / select-all rules, and the export queue writing every photo
  through the renderer and stopping after the item in flight on cancel.
- `ExportTests.swift` — JPEG quality moves the file size monotonically,
  resize gives an exact long side, works in percent and never upscales, the
  camera EXIF travels with the orientation reset in every format, HEIC and
  TIFF round trip, the collision policy (number, skip, overwrite) and the
  original is never written, not even under a case-variant name on a
  case-insensitive volume, the queue counts skipped files and passes the
  options through, and the file name, suffix, extension and options round
  trip.
- `ThumbnailTests.swift` — the embedded-preview size rule (a small embedded
  thumbnail is refused and the image decoded; a request at or under its
  size is served from it), the timed folder of synthetic JPEGs, the
  real-RAW timing (skipped unless asked for), and the cancellation proof: a
  request cancelled before its decode decodes nothing, one cancelled in
  flight sees the cancellation inside the decode and caches nothing.
- `TestImages.swift` — no tests; the shared helpers. `syntheticImage(width:height:)`
  draws the photo every pixel test reads (a luminance ramp with coloured
  bands, so both neutral and saturated pixels are present), `meanRGB` and
  `maxDiff` measure a rendered frame, and `bench24MPImageURL()` is the 24 MP
  source for the timed tests.

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

Four tests time the render path and one the thumbnails; each prints a
`BENCH` line and fails above a bound.

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

The source for the render timings is `PHOTOLAB_BENCH_IMAGE` when set (a real
photo, through the loupe's own master decode), else a synthetic 6000×4000
JPEG written once to the temporary directory (`bench24MPImageURL()`).
`PHOTOLAB_BENCH_TARGET` overrides the loupe's long side in pixels.

**Load sensitivity.** These numbers double on a busy box (a sibling build,
Spotlight, another test run). The thumbnail timings read `getloadavg`,
print the load beside their number and scale their bound above a load of 8
(`loadFactor`); the render-step and strip gates are fixed. So before trusting
a red timing test, read `uptime`: a red at a high load average is re-run on
a quiet box before anything is changed, and a documentation or test-only
change cannot have caused one. A green at a high load is still green.

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
- `Library(rememberFolder: false)`: the opened folder stays out of
  UserDefaults.
- `ExportQueue`: `init(remember:worker:)` leaves `remember:` off (the folder
  and options stay in memory) and takes a `ExportQueue.Worker`, so a test
  can count, slow or fail jobs without rendering; exports that do render go
  into a temporary output directory.
- `Thumbnails`: `init(decode:)` takes the decoder, so a test can count calls,
  block a decode or report what it saw.

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
