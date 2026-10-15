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
skips; three tests skip by design (the real-RAW timing, below, and the two
real-PhotoKit tests in `PhotosTests`, which run only in a process that is
already authorized for Photos), and a timed render gate that misses on a
swamped box skips rather than fails (Load sensitivity, below). The timed
tests print a `BENCH` line with their numbers beside the verdict; read it,
not only the pass.

## What each file proves

- `RendererTests.swift` — the recipe model (every kind once, in chain order;
  JSON round trip), the neutral recipe is the identity, a disabled entry
  changes nothing, the direction of exposure, temperature, tint and
  saturation, the preview fit (down, never up), and the timed slider step on
  a 24 MP photo.
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
  the end.
- `EditStateTests.swift` — `Recipe.isNeutral` versus `Recipe.isDefault`: a
  disabled-only edit renders as identity but is still an edit, in memory and
  on disk; `Library.endEdit` closes whatever edit is open and `beginEdit` on
  another photo closes the first; `Library.open` of a missing path (or a
  flag-like argument) opens nothing and keeps the current folder; and
  `Library.maxUndoDepth` (100) caps the undo stack, dropping the oldest
  steps and keeping the newest in order.
- `SourceTests.swift` — the `PhotoSource` seam: a fake source of three
  assets opens in its own order with its names and title, a recipe on an
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
  case-insensitive volume, an Overwrite onto another library original (by
  name, case variant or hard link) fails in the queue with the file named
  and both originals byte-identical, the queue counts skipped files and passes the
  options through, the file name, suffix, extension and options round
  trip, and the preview and the export agree on colour: `Renderer.previewMaster`
  rendered at loupe size and `Renderer.fullResolution` exported as a TIFF,
  on a Display P3 HEIC and an sRGB JPEG under one recipe that moves every
  channel, have the same mean colour to within 1/255 (the "one render path"
  claim, pinned).
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
- `HistogramTests.swift` — a frame with a 25 % white block reports a quarter
  of its pixels blown and none crushed, the warning lights above a tenth of
  a percent and not at it, the bins sum to the pixel count and match a
  plain-Swift count, one clipped channel counts the pixel, the timed
  preview-sized frame, and the overlay flags exactly the clipped pixels of a
  frame holding every 8-bit level and of a rendered frame, agreeing with
  that frame's histogram.
- `TestImages.swift` — no tests; the shared helpers. `syntheticImage(width:height:space:)`
  draws the photo every pixel test reads (a luminance ramp with coloured
  bands, so both neutral and saturated pixels are present; sRGB unless a
  colour space is passed), `meanRGB` and `maxDiff` measure a rendered frame,
  `bench24MPImageURL()` is the 24 MP source for the timed tests, and
  `loadAverage()` / `assertFrameBudget` are the load guard on the timed
  render gates.

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

The source for the render timings is `PHOTOLAB_BENCH_IMAGE` when set (a real
photo, through the loupe's own master decode), else a synthetic 6000×4000
JPEG written once to the temporary directory (`bench24MPImageURL()`).
`PHOTOLAB_BENCH_TARGET` overrides the loupe's long side in pixels.

**Load sensitivity.** These numbers double on a busy box (a sibling build,
Spotlight, another test run). Every timed test reads the 1-minute load
average and prints it beside its number. The thumbnail and histogram timings scale
their bound above a load of 8 (`loadFactor`). The three render gates (the two
slider steps and the strip) go through `assertFrameBudget`: the bound is as
written up to a load of 4 (a clean box idles at 2–4; on 2026-10-15 every red
of the 16 ms gate came at a load of 7.3 or more from sibling builds and every
pass at 5.3 or less, with the render path unchanged), scales with
`load / 4` above it (load 8 is 32 ms), and above a load of 12 a miss throws
`XCTSkip` with the numbers in its message, never a red, because the box
cannot measure a frame budget then. Each gate measures up to three times
and the best sweep counts (a sibling build's compile burst is seconds long
and rarely covers three sweeps; a slower chain misses all three; the `BENCH`
line says "best of n sweeps" when it retried). A pass at any load stands,
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
- `Library(rememberFolder: false)`: the opened source stays out of
  UserDefaults; `Library(rememberFolder:defaults:)` takes a
  `UserDefaults(suiteName:)` the test removes afterwards when remembering
  is what is tested.
- `PhotosAccess(client:sidecarDirectory:originalsDirectory:)`: the fake
  client and two temporary directories; `PhotosAccess.live` (the real
  client, `~/Library/Application Support/PhotoLab/photos-sidecars/` and
  `~/Library/Caches/PhotoLab/originals/`) is the app's alone. No test calls
  `requestAuthorization`: the permission dialog is the user's click, from
  the bundled app.
- `ExportQueue`: `init(remember:worker:)` leaves `remember:` off (the folder
  and options stay in memory) and takes a `ExportQueue.Worker`, so a test
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
