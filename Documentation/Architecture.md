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
kinds apply in the order the enum declares them (lens corrections, geometry,
then exposure and white balance, tone, color, per-band HSL, color grading, detail, effects)
whatever order the
recipe happens to list them in. An entry that is disabled or at its neutral
value (`Adjustment.isNoop`) is skipped, so the neutral recipe is the identity.

Some kinds render together as one stage. `AdjustmentKind.Group` names the
four: `crop` (the four edges are one `cropped(to:)`), `tone` (highlights,
shadows, whites, blacks and the five tone-curve points are one per-channel
lookup), `hsl` (the 24 hue / saturation / luminance sliders are one 3D
color cube) and `grade` (the ten color-grading sliders are another cube,
right after `hsl` and before clarity; `ColorGradingTests` pins the
position). `apply` reaches a group when it meets its first member and
renders it once through `groupStage`, provided any member is not a no-op;
the other members' own `stage` branch is a pass-through.

The cubes are built on the CPU in `ColorCubes` (`ColorCubes.swift`,
Accelerate): `ColorCubes.toneLUT` samples the tone curve and
`ColorCubes.toneCube` turns it into cube data; `ColorCubes.hslCube` builds
the HSL cube, weighted by each pixel's own saturation so grays never move.
`ColorCubes.gradeCube` builds the color-grading cube: each entry's Rec. 709
luma (`ColorCubes.lumaWeights`) weights it into shadows, midtones and
highlights (`ColorCubes.gradeWeights`, the quadratic Bernstein basis of the
luma bent by balance, so the three sum to 1), the weighted luminance sliders
add an offset to every channel (`gradeLuminanceAmount` at ±100), then the
weighted tints (`ColorCubes.tintDirection` of each range's hue, times its
saturation and `gradeTintChroma`) are added with no luma of their own,
scaled per entry only as far as keeps every channel in 0…1, so a gray takes
color and keeps its luma. `groupStage` skips the grade cube when every
saturation and luminance is 0 (a hue alone, or balance alone, tints
nothing), so such a grade is exactly the identity.
All three are `ColorCubes.dimension` samples per axis and are applied through
`colorCubeWithColorSpace` in sRGB gamma space on purpose, where tone and
lightness read the way the sliders suggest. `CubeCache` keys a built cube by
its parameter values: dragging an unrelated slider reuses the cube, a step of
one of the cube's own sliders builds a new one.

Every spatial parameter in `stage` (the clarity and blur radius, the
sharpening radius, the colour-noise blur, the grain cell, the vignette
radius) is a fraction of the image's own long side, so a preview and an
export of the same recipe look the same at their different sizes.

The two noise stages run after the crop and before exposure, so the tone
stages never lift noise first, on the fewest pixels (placed first in the
chain they measured ~1.5 ms slower at loupe size: more pixels, and the lens
warp reads a larger area of them). Both live in `NoiseReduction.swift` and
keep values outside 0…1 (a Display P3 red, a highlight above white), which
exposure may still bring back. `colorNoise` blurs a downsized copy at a
fixed `colorRadiusShare` (0.5%) of the long side, the copy scaled so the
blur is `smallRadius` (2.5) of its pixels (so the round trip's pitch is a
share of the frame and preview and export match), then mixes the blurred
colour over the original's luminance by the slider in one Metal kernel,
`chromaMix` (Rec. 709 weights, no clamp). `CIColorBlendMode` did this
first and was dropped: it clamps to 0…1, and with a slider-scaled radius
and a fixed quarter size the effect jumped at 1 and then barely moved.
`luminanceNoise` is `CINoiseReduction` on gamma-encoded values (in linear
values a shadow's noise is so small that any level smeared it before
exposure lifts it), level (a threshold: noise under it goes) 0.1 × the
slider, the edge-protecting sharpness rising with it (0 → 0.4; a fixed one
at a low level only sharpened the noise). It takes one input on purpose: a
dissolve from the original made Core Image compute the chain before it
twice, about 0.8 ms at loupe size.

Even so, the two stages cost about 0.75 ms a frame at loupe size, and the
everything-on gates (`ToneSetTests` slider steps with masks,
`BrushStrokeBudgetTests`) had no such room. So a drag's frames leave them
out: the loupe renders `Library.previewRecipe(for:)`, which mid-drag
(`beginEdit` … `endEdit`: a slider, a grade wheel, a mask handle, a brush
stroke) is `Recipe.draft(since:)` the value at `beginEdit` — noise reduction
reset once the drag has moved something else, unchanged on a press that
moved nothing, and kept while the drag moves noise reduction itself (its
own slider shows its effect live). The recipe, the sidecar, every export and
the frame at mouse-up are never drafted; the two gates time the draft, which
is what the screen shows mid-drag. One real limit: the preview is a
downsampled master, which already hides much of a RAW's noise, so judge
noise reduction at 1:1 (the zoomed loupe renders a full-resolution region).

The two lens corrections, `lensDistortion` and `lensVignette`, are the first
stages, before rotate, so they act on the whole frame the lens made
(`LensCorrection.swift`). Both are Core Image kernels compiled once at
runtime from the Metal source `LensCorrection.source` through
`CIKernel.kernels(withMetalString:)` (macOS 12 and later, so no availability
check against the macOS 14 floor, and no .metal build step in SwiftPM); they
need the Metal-backed context `Renderer` makes, and without the kernels
(`LensCorrection.isAvailable` false) each stage returns its input. Positions
are normalised about the frame centre by the half diagonal, so both scale
with the image. `LensCorrection.distort` is a `CIWarpKernel`: an output
point `p` reads the source at `q (1 + k |q|²)` with `q = s p`
(`LensMath.source(of:k:scale:)`), `k = LensMath.k(for:)` (−0.2 at +100:
positive corrects barrel, negative pincushion) and `s` the fill zoom
`LensMath.scale(k:width:height:)`, the largest that keeps every border
point reading at least a pixel inside the source (the corner binds for
k > 0, the nearer edge's midpoint for k < 0). The zoom is applied before
the warp, so the corrected picture is only scaled about the centre and a
straightened line stays straight. Its ROI callback bounds a destination
rect by the rect scaled at the factors of its nearest and farthest radius,
so a 1:1 region reads only its own neighbourhood. The output is cropped to
the input's extent, so `CropMath.uncropped` and the crop overlay work on
it unchanged. `LensCorrection.vignette` is a `CIColorKernel` gain of
`2^(value/100 · r²)` (`LensMath.vignetteGain`) over the pre-crop frame,
apart from the Effects `vignette`, which stays post-crop. Masks are drawn
over the source extent and go through rotate and crop only
(`geometryKinds` is still rotate plus the crop edges), so a mask stays
where it was placed on screen but does not follow the image when the
distortion slider later moves.

The recipe's masks (`Recipe.masks`, local adjustments) are one more stage,
run just before `Renderer.maskStageBefore` (clarity, the head of Detail):
after the HSL group and the color grade, so clarity, sharpening, grain and
the vignette sit on top of local edits. `apply` makes one call, `MaskRender.compose`
(`MaskRender.swift`), with the extent of its own input (the scaled source,
the frame mask geometry is written in). For each mask that renders
(`MaskRender.renders`: enabled, some adjustment not a no-op, and not a brush
with no strokes nor an automatic mask whose bitmap is all zero with no paint
stroke, `MaskBitmap.isBlank`), in list order, it draws the shape's mask over
that extent (`MaskRender.image(for:over:)`: `CILinearGradient` from `start`
to `end`, or `CIRadialGradient` on a unit circle with its inner ring at
`1 - feather`, scaled to the radii in long-side pixels, turned clockwise on
screen by `angle` and moved to the centre, a brush's CPU raster, below,
or an automatic mask's bitmap, placed as the brush raster is: its pixel
edges onto the extent's, clamped at the edges; `CIImage(bitmapData:)` reads
row 0 as the top, so the top-down rows need no flip; with strokes, it
goes through `BrushRasterCache` like a brush (`image(for:base:width:height:)`):
the strokes are rastered at the brush's raster size for the extent
(`BrushRaster.rasterSize(for:)`) over the bitmap resampled to that size
(`MaskBitmap.resampled(width:height:)`, the seed of a `LiveRaster`), so a
dab is round and the size `MaskMath` says whatever the bitmap's size),
runs it through the recipe's
own geometry kinds (`AdjustmentKind.geometryKinds`, by `apply` itself, so
rotate and crop are not written twice), applies the mask's adjustments to
the picture so far through `apply(mask.recipe, to:)` (the same chain, so a
mask's highlights and shadows come through the tone cube and `CubeCache`),
and composes the two with `CIBlendWithMask`; an inverted mask swaps the two
images, weight 1 - w. `MaskMath.weight(of:at:in:)` (`Masks.swift`) states
the same weights without Core Image: a straight ramp along the gradient,
constant along its perpendicular in pixels, and a straight ramp in
normalised ellipse radius between the inner and outer rings, and an
automatic mask's bitmap sampled bilinearly between pixel centres
(`MaskBitmap.weight(at:)`) with its strokes applied over it by the brush's
rule (`BrushRaster.weight(of:at:in:over:)`). Because the
mask is built over the whole source and placed by the same stages as the
pixels, a 1:1 region needs nothing of its own: it reads a window of the
same chain.

A brush mask is rastered on the CPU (`BrushRaster.swift`, its pixel loops
in the `BrushKernel` C target, `Sources/BrushKernel`, built with `-O3` in
every configuration: unoptimised Swift loops cost about 250 ns a pixel, so
a debug build could not paint live).
`BrushRaster.render(strokes:base:width:height:)` is pure: one byte per pixel,
rows top-down, each pixel the brush's weight at its centre, starting from
0 for a brush mask or from `base` (an automatic mask's bitmap resampled to
the raster size) for an automatic mask's refining strokes. A stroke is
round dabs every `BrushRaster.dabSpacing` (a quarter of the radius) of arc
length along its points, plus one on the last point (`BrushRaster.dabs`);
a dab weighs `flow` inside `radius x (1 - feather)` and eases to 0 at
`radius` by a smoothstep (`BrushRaster.dabWeight`). The dabs of one stroke
merge by their maximum, so one pass lays down at most its `flow`; strokes
apply in order, a paint stroke adding its coverage clipped at 1 and an
erase stroke multiplying the weight so far by 1 - its coverage.
`BrushRaster.weight(of:at:in:)` is the same rule at one point, and is what
`MaskMath` reports for a brush. The raster is the size of the extent it is
drawn over (the scaled source), its long side capped at
`BrushRaster.maxLongSide` (4096, `BrushRaster.rasterSize(for:)`); beyond
the cap `MaskRender.image(for:over:)` scales it up with Core Image. It is
held as a one-channel, unmanaged `CIImage` (`.L8`, no colour space, so the
bytes are the weights) in `BrushRasterCache.shared`, keyed by the strokes,
the raster size and, for an automatic mask, its bitmap's
`MaskBitmap.digest` (`BrushRasterCache.Key.base`: two detections with the
same strokes never share a raster) (the `CubeCache` pattern, a handful of entries): a
render whose strokes have not changed (a mask or global slider, a rotate or
crop, which act on the mask after it is drawn) never rasters again, and
`BrushRasterCache.rasters` counts the misses for the tests. A stroke being
painted changes the strokes on every point, so every frame misses; a miss
therefore rasters through a `LiveRaster` kept per raster size and base
digest (at most three, the loupe, the 1:1 view and the preset strip, the
most recent kept; one for an automatic mask is seeded with its resampled
bitmap, `LiveRaster.init(width:height:base:)`, and every rebuild starts
from that seed). It holds the weight of every stroke but the last (`acc`), the last
stroke's walked dabs max-merged (`cover`) and the bytes. When the last
stroke only grew (`LiveRaster.grows`: its points a prefix, the same radius,
feather, flow and erase) only its new walked dabs (`BrushRaster.walk`, the
dabs before the moving last-point dab) are stamped, and only the pixels
they and the old and new last-point dabs touch are re-quantised; a new
stroke after it composes it into `acc` over its own bounds first; anything
else (an undo, an edited stroke) rebuilds. Max-merging is exact and every
path runs the same C loops, so the bytes are a fresh raster's
(`LiveRasterTests`), and `BrushRaster.render` itself is a rebuild of a
fresh `LiveRaster`.

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
- `Renderer.firstFrame(_:minPixelSize:masterPixelSize:)` is the loupe's
  stand-in while that master decodes: `ImageLoading.firstFrame` returns the
  container's embedded preview as stored, never a decode (both `FromImage`
  options passed as false; left unset, ImageIO decodes a file with no
  preview), and only when its long side is at least
  `PreviewModel.firstFrameMinPixelSize` and below `masterPixelSize` (at or
  above it the master is that same preview). A Sony ARW's 1616×1080
  preview passes; a JPEG's 160 px EXIF thumbnail does not.
- `Renderer.fullResolution(_:decodeNow:)` is the export's input:
  `CIImage(contentsOf:)` with the orientation property applied, the whole
  file, decoded lazily by Core Image at render time. The loupe's 1:1 master
  is the same call with `decodeNow` (`.cacheImmediately`): the same decoder
  and the same pixels, decoded once into memory off the main thread.

### Output

`Renderer.render(_:recipe:maxPixelSize:resize:region:watermark:)` is the one place a chain is
run to pixels. It scales the source down to `maxPixelSize` first (never up;
nil renders at source size), applies the recipe, then, if `resize` is given,
sizes the output: `OutputSize` is an exact long side (`longSide`) or a
percentage (`percent`) of the rendered, cropped size, and
`OutputSize.size(fitting:)` returns nil for any target at or above the
rendered size, so an export is never upscaled. Instead of `resize`, a
`Renderer.Region` cuts the output to a window of the rendered frame, the
loupe's 1:1 view: a centre normalised in the rendered frame (after crop and
rotate, 0…1, origin top-left) and a size in pixels; `Region.rect(in:)`
slides the window inside the frame at the edges. The chain is built over
the whole source exactly as for the whole frame and only the pixels read
back differ, so every spatial radius stays a fraction of the whole image;
never render a cropped input instead. `Result.frameSize` is the whole
rendered frame's size and `Result.region` the window it holds. That resize is a Lanczos
scale, the last step of the chain, done once. For a whole frame only, an
export's `sharpening` (`ExportOptions.Sharpening`: `CISharpenLuminance` at a
1 px radius in the output) runs right after it, so a downsized file gets
back the edge the resize softened. The result is an 8-bit `CGImage` in the
source's color space, or in an export's `colorSpace`
(`ExportOptions.ColorSpace`: sRGB or Display P3; Core Image converts, never
retags), returned as `Renderer.Result` with the
wall time of the whole step in `milliseconds` (the loupe's footer and the
tests read it). `render` is synchronous; every caller runs it off the main
thread.

After the resize, and only for a whole frame (never with a `region`),
`watermark` (an export's `ExportOptions.watermark`) is the very last stage:
`Watermark.composite(over:in:)` typesets the trimmed one-line text
(`cleanText`) with Core Text in the system font, its height (ascent plus
descent) `clampedSize` of the OUTPUT rect's short side (shrunk to fit
between the margins when the line is too long), draws it white with a
soft dark shadow at `clampedOpacity` into its own bitmap, and composites
it source-over at `Watermark.origin(for:textSize:in:margin:)`: a corner,
`Watermark.marginFraction` (2%) of the short side in from both edges, or
the centre. Because it follows the resize, the mark is the same share of
every exported size. Nil or blank text changes nothing, pixel for pixel.
Only `Exporter.write` passes one, so the loupe, the preset strip,
thumbnails and Save to Photos (`PhotosSource.saveOptions`) never draw it.

### The loupe

`PreviewModel` (`Preview.swift`) holds one photo's master and renders the
current recipe at the view's pixel size (scaled by Settings › Preview
quality: `PreviewCanvas` asks for `PreviewQuality.pixelSize(_:)` of it and
draws the frame scaled to fit; the 1:1 window is never scaled). `PreviewModel.load(_:)` decodes the
master off the main thread; `PreviewModel.request(url:recipe:maxPixelSize:)`
records a request; `pump` runs at most one render at a time and the newest
request replaces any waiting one (latest wins), so a fast slider never queues
stale frames. `PreviewCanvas` (`ContentView.swift`) is the view: it calls
`load` when the photo changes and `request` when the recipe or its own pixel
size changes, and substitutes `Recipe.neutral` while `Library.showBefore` is
on, which is all the Before button does.

The first frame. `load` starts two decodes off the main thread
(`PreviewModel.Decoders`, injectable; `.live` is `Renderer.firstFrame` and
`Renderer.previewMaster`). An embedded preview that lands first stands in
as the master: `pump` renders the waiting request over it through the same
chain, so the recipe is applied to the frame that shows, and
`imageIsFirstFrame` is set on that frame. When the master lands it cancels
the preview's task, takes the preview's place, and
`renderAgainOverMaster` asks for the newest request again (and compare's
Before, dropping one still rendering over the preview); `image` is never
cleared in between, so the swap is one frame replacing another. A master
that lands first leaves the preview unused; a master that fails takes the
preview's frame down so the canvas labels the photo. `masterSize` is the
master's alone and zero until it lands. 1:1 is untouched: its window comes
from the full-resolution master, decoded on its own. A new photo cancels
both decodes; `offMain` forwards the cancellation into the detached work,
so a decode that has not started is skipped and one already in ImageIO
runs out and is dropped.

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
the clipping overlay or the mask tint; the histogram stays the After frame's. Leaving compare
mode drops `beforeImage` and clears the in-flight request, so a Before
still rendering then finds itself unwanted and is discarded.

Crop mode (`Library.cropMode`, `R`) is the same model with a different
recipe: the canvas requests `CropMath.uncropped(_:)`, the recipe with its
four crop edges at neutral. Rotate is the first stage of the chain and the
crop the second, so that frame is the rotated frame whole, and the crop the
renderer will cut is an axis-aligned rectangle in it: `CropOverlay` draws
it there and its handles move square to the frame as shown, with no
rotation arithmetic. A crop drag changes only the crop edges, so the
requested recipe, and the frame, stay the same through it; only the
overlay moves. `PreviewModel.imageRecipe` is the recipe the shown frame
came from, and the overlay is drawn only over a frame
`CropMath.isCropFrame` accepts (uncropped, at the current rotation), never
over the cropped frame still up from before. The mapping from view points
to the crop is `CropMath` (`CropMath.swift`): pure functions over the fit
rect `ZoomMath.fitRect` gives, in points, so the display scale never
enters. The aspect lock works in the same units: a pixel ratio becomes a
ratio of frame fractions through the frame's own aspect
(`CropMath.Aspect.normalized(frame:)`), which rotate never changes, so a
locked crop keeps its shape at any rotation. The straighten line is read
over the same frame: it is already turned by the current rotate and laid
out at a uniform scale, so the angle seen on screen is the angle in the
frame, and `StraightenMath` (also `CropMath.swift`) takes it off the
current value.

The mask handles (`MaskOverlay`, over the After frame outside crop mode)
need the opposite direction: a mask lives in the SOURCE frame, before
rotate and crop, and the frame shown is after both.
`MaskMath.viewToSource` / `sourceToView` (`Masks.swift`) map between them
in three steps, the forward one mirroring the chain: a view point to a
fraction of the frame shown (`MaskMath.Viewport`: `.fit` over the rect
`ZoomMath.fitRect` gives, or `.window` over the 1:1 region drawn unscaled
and centred, as `ZoomMath.point(forClick:…)` reads a click, without its
snap to a pixel centre); the crop undone (`CropMath.Crop.rect`); then the
rotate stage undone, its inscribed rectangle
(`MaskMath.Geometry.inscribedScale`, the formula of `Renderer`'s
`.rotate` stage) and its clockwise turn about the centre. The renderer
also takes a pixel off each side of the inscribed rectangle, which the
mapping leaves out (under a pixel of the frame). `MaskMath.Geometry` is
read from the current recipe and `PreviewModel.masterSize` (only its
aspect is used), and the overlay is drawn only once
`PreviewModel.imageRecipe` has the current rotate and crop
(`MaskRender.geometryKinds`), so the mapping is the shown frame's. A
handle drag maps its start and current pointer to the source and the
shape moves there (`MaskHandles`), so a mask drag never re-requests a
different geometry: only the overlay and the masked render move.

### The loupe at 1:1

`PreviewModel.zoom` is `PreviewZoom.fit` (the whole frame in the view) or
`.actual(center:)`, one image pixel per view pixel around a centre
normalised in the rendered frame (after crop and rotate, origin top-left).
`setZoom(_:)` changes it; `request(url:recipe:maxPixelSize:viewPixelSize:)`
carries the view's pixel size, which is the window's. While 1:1 each request
also records a window request, rendered by `pump` through
`Renderer.render(_:recipe:region:)` over the photo's full-resolution master
into `zoomImage` / `zoomURL`, with `zoomRegion` (where the window landed in
the full-resolution rendered frame, slid inside it at the edges) and
`zoomFrameSize` (that frame's size) for the view to pan and map clicks.
`image` and the histogram stay the fit frame's: a waiting window and a
waiting fit frame take turns, so a drag updates both. The window carries
the clipping overlay and the mask tint like the fit frame; `setClipping` re-renders it.

The full-resolution master (`Renderer.fullResolution(_:decodeNow:)`) is
decoded off the main thread on the first 1:1 of a photo and held for that
photo only: about 4 bytes a pixel for an 8-bit source, 96 MB for a 24 MP
photo, more for a 16-bit or RAW one. Back to fit drops the window but keeps
the master, so zooming in again decodes nothing; `load` of another photo
drops the master and the window, as compare mode's Before frame goes with
its photo, and a window still rendering then is discarded. A region step
over a 24 MP master renders in about 12 ms on this machine, since Core Image
evaluates only the pixels the window needs.

Because the window is the export's own chain over the export's own pixels,
it matches the same crop of an export render to within 1 level. Core
Image's result depends on the area it is asked for at about that level
(two windows disagree on their overlap by as much, measured), and strong
sharpening across a hard edge can lift it to 2 to 4 on a few edge pixels;
`ZoomTests` gates within 1 at the documented settings.

The interaction lives in the view and `Library`; the arithmetic is pure, in
`ZoomMath` (`Zoom.swift`), so it is tested without a window.
`Library.loupeZoom` holds the zoom (fit whenever `selection` changes, an
arrow is pressed or the loupe closes); `PreviewCanvas` hands it to
`setZoom` and passes its pane in pixels (`ZoomMath.window`) as
`viewPixelSize`. A click maps through the fit frame's rect in the padded
pane (`ZoomMath.fitRect`, `center(forClick:frame:pane:)`), which is laid out
in points, so the display scale does not enter; the clicked pixel is the
window's centre at any scale. A drag moves the centre by the translation
times the display scale over the frame size, from a start centre clamped
first, and `ZoomMath.clamp` holds it at least half a window from each edge
(the middle on an axis the window covers whole), the same place
`Region.rect(in:)` slides the window to, so a pan back from an edge moves
the picture at once. A window whose frame fits inside the view whole
(`ZoomMath.fits`) is never shown: `renderZoom` sets `zoom` back to `.fit`,
and the canvas puts `Library.loupeZoom` back too.

The white-balance eyedropper reads a click as a point of the rendered
frame the same two ways: at fit through `center(forClick:frame:pane:)`,
at 1:1 through `ZoomMath.point(forClick:region:frame:pane:displayScale:)`,
which undoes the canvas's layout of the window (`PreviewModel.zoomRegion`
drawn unscaled, centred in the pane) and returns the clicked pixel's
centre over `zoomFrameSize`. A normalised point is the same spot of the
picture at any frame size, so the 5×5 patch `Renderer.Region` cuts from
the decoded master is the same from either view (`WhiteBalanceTests`).

In compare mode the window request carries `before`, and `renderZoom` cuts
the neutral render at the same `Renderer.Region` in the same hop into
`zoomBeforeImage` / `zoomBeforeRegion`, so the halves cannot show different
regions or land apart. With a crop or rotation on, Before is the uncropped
photo (as at fit), so the same region is the same normalised window of its
own frame. Turning compare on or off at 1:1 asks for the window again;
off drops the Before window.

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

The O overlay (Show Mask Overlay) is a third stage of the same kind:
`PreviewModel.maskOverlay` is the id of the mask to tint (the canvas sets
it through `setMaskOverlay(_:)` to `Library.selectedMask` while
`Library.showMaskOverlay` is on, nil otherwise), and `pump` and
`renderZoom` look that id up in the request's own recipe and, after the
clipping overlay, call `MaskTint.compose(over:mask:recipe:sourceExtent:window:renderer:)`
(`MasksPanel.swift`). It draws the mask with `MaskRender.placedImage`
over the extent `Renderer.render` scaled the source to
(`MaskTint.sourceExtent(of:maxPixelSize:)`, the same never-upscale rule;
the full-resolution master's extent for a 1:1 window, cut to the window's
region), inverts it for an inverted mask, and blends `MaskTint.color` (red)
at `MaskTint.opacity` (0.5) times that weight over the 8-bit frame, untagged
in and out like the clipping overlay. The tint therefore lands on the
pixels the mask's adjustments change at any rotate, crop, preview size or
window. It needs the mask's placement, which only a render has, so
`setMaskOverlay` and a `setClipping` while a mask is tinted render the
newest request again (`renderAgain`) rather than re-compose the kept
frame. Compare's Before, thumbnails, the preset strip and `Exporter` never
pass through it.

Auto (`AutoTone.swift`) is the one other reader of a `Histogram`, and it
measures its own frame, not the panel's: the photo's recipe with the six
Basic kinds at neutral (`AutoTone.base`), rendered through
`Renderer.render` at `AutoTone.analysisPixelSize` over the photo's decoded
master and counted by `Histogram.compute`. `AutoTone.values(from:)` is a
pure function of that histogram. It solves for targets in the 8-bit frame
through a model of the chain (`AutoTone.Model`: exposure a gain on linear
values, contrast a scale of linear values about 0.5, the tone stage
`ColorCubes.toneLUT` itself), not through rules of thumb: exposure moves the
luma median toward `AutoTone.midTarget` (half way when darkening, never
pushing the brightest channel's 99.5th percentile past
`AutoTone.whiteCeiling` nor darkening a top already there), contrast
(within `AutoTone.contrastRange`) takes the interquartile spread toward
`AutoTone.spreadTarget`, whites and blacks put the end points into
`AutoTone.whiteWindow` and `AutoTone.blackWindow`, and highlights and
shadows answer the mass above `AutoTone.upperZone` and below
`AutoTone.lowerZone`. The measured frame never carries the six, so Auto
read twice reads the same histogram and sets the same values. White balance
comes first: `AutoTone.values(for:recipe:)` asks `WhiteBalance.auto`
(a grey-world mean over `WhiteBalance.greyWorldMean`'s near-neutral pixels
of the frame with `WhiteBalance.base` and `AutoTone.base` applied, solved
by `WhiteBalance.neutralising`) and measures the histogram on the recipe
with that temperature and tint; `AutoTone.base` zeroes only the six, so the
second run reads the same frame and sets the same eight values.

`ImageStats` (`ImageStats.swift`) is the measurement a look is compared by:
the shared core of learning from edits (a solver that minimises
`ImageStats.distance(to:weights:)` between a photo and a reference) and of
Auto in my style. `ImageStats.measure(_:)` reads one 8-bit frame through
`RGBA8Pixels`, the bytes `Histogram` counts, and returns, on a 0…1 scale of
the sRGB-encoded frame: Rec. 709 luma (`ImageStats.lumaWeights`, as
`Histogram.luminance`) at each of `ImageStats.percentileLevels` (0.5, 5,
25, 50, 75, 95 and 99.5 %, read by `AutoTone.percentile` from 256 bins);
the mean colour (`ImageStats.RGB`); the mean colour of each
`AdjustmentKind.GradeRange` (`ImageStats.rangeMeans`: luma below
`ImageStats.shadowCeiling`, a third, is shadow, above
`ImageStats.highlightFloor`, two thirds, highlight, the rest midtone; nil
for a range no pixel falls in); mean HSV saturation and mean chroma. It is
vectorised (vDSP over Double planes and one vImage histogram), well under
a frame at 512 px (`ImageStatsTests`). `ImageStats.Weights` names the three terms of
the distance (`tone`: the mean absolute difference of the percentiles;
`colour`: the mean RGB distance of the overall and per-range means, a
range only one frame has counting `ImageStats.missingRange`; `saturation`:
the saturation and chroma differences), zero to itself and symmetric.
`ImageStats.of(master:recipe:)` renders the recipe as it stands through
`Renderer.shared` at `AutoTone.analysisPixelSize`, as
`AutoTone.histogram(of:recipe:)` does without its neutral base, and
measures that frame. Learn Style reads it (see `Library.runAutoJob`) for a
photo's brightness bucket, on the frame with the Basic and white-balance
kinds at neutral.

`LookMatch` (`LookMatch.swift`) is the first reader: the solver that finds
the global values making a photo measure like a target `ImageStats`. Its
twelve `LookMatch.kinds` are exposure, contrast, whites, blacks,
temperature, tint, saturation, vibrance and the shadow and highlight grade
hue and saturation (`LookMatch.mask`, a `SyncMask`, for applying them).
`LookMatch.values(target:master:recipe:)` starts from `LookMatch.base`
(the recipe with the twelve at neutral, as `AutoTone.base`, so a second
run solves the same thing) and costs each candidate by rendering it
through `ImageStats.of(master:recipe:)` at `AutoTone.analysisPixelSize` and
taking `ImageStats.distance(to:weights:)` to the target: no slider's sign
or strength is modelled, the chain is the truth, as in
`WhiteBalance.neutralising`. The search is coarse, then compass: the tone
kinds (`LookMatch.toneKinds`) swept one at a time over
`LookMatch.coarseOffsets` on the tone term alone (`LookMatch.toneWeights`);
temperature and saturation swept together (a warm cast raises every
grey's saturation, so either alone reads a warm, desaturated look as a
wrong turn), then tint and vibrance; each grade range's hue and saturation
over `LookMatch.coarseHues` × `LookMatch.coarseGradeSats`; then a compass
search on the full cost (`LookMatch.weights`, `ImageStats.Weights.standard`)
from `LookMatch.compassStart` slider steps halving to one, a move only on a
strictly lower cost and a hue under no saturation left alone. Every point
is on the slider grid (`LookMatch.step(of:)`: 0.05 EV for exposure, else
whole numbers) inside the kind's `range`, and a point is rendered once
(the search memoises its stats). `LookMatch.applying(_:to:)` sets the
values on a recipe. A whole solve takes about two seconds at 512 px
(`LookMatchTests`); it is pure and synchronous, with no UI yet.

`Library.autoTone` reads its photos in a task group of at most
`Library.autoConcurrency`, each through `Library.autoMeasure` (off the main
thread; a test replaces it), results keyed by `Photo.ID` and applied by one
`sync` after the last; `Library.cancelAuto()` drops them all. That job is
`Library.runAutoJob`, generic over what each read returns, and Auto in My
Style (`Library.autoMyStyle`, reads through `Library.autoStyleMeasure` =
`AutoStyle.values(for:recipe:profile:)`: Auto plus the bucket's correction,
clamped and rounded) shares `Library.autoTone`'s apply step
(`applyAutoJob`, one `sync`). Learn Style
(`Library.learnStyle(from:replace:)`, `AutoStyle.swift`) is its second
user: each read through `Library.styleMeasure` gives a `StyleSample`'s
`StyleBucket` and the values Auto gives the photo, the photo's own
values are taken from its recipe as the job started, and
`StyleProfile.learn(from:)` (pure) turns the samples into per-bucket
medians of own − Auto with an all-photo fallback, saved by `StyleStore`.

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

All of it is in `Adjustments.swift`, `Masks.swift`, `Sidecar.swift`, `Presets.swift`,
`Export.swift`, `Watermark.swift`, `ExportPresets.swift`, `PhotoSource.swift` and `Photos.swift`.

### `PhotoID`, `Photo` and `PhotoSource`

A photo's identity is a `PhotoID` (`PhotoSource.swift`): `PhotoID.file`,
the file URL of a photo in a folder, or `PhotoID.asset`, a library asset's
identifier (`UUID/L0/001`). Every `Library` map (`recipes`, `marks`, `keywords`, the
undo history, the selection) is keyed by it, and a `Photo` is the id, the
display `name` the source gave it, `Photo.fileURL`, the file when the
id is one (nil for an asset until its source produces a file), and
`Photo.captureDate` when the listing carries one (a Photos asset's
`creationDate`; nil for a file, whose date `CaptureDates` reads when the
capture-date sort first needs it, or takes from the Info section's header
read, `PhotoInfoStore`, which applies the same rule), and `Photo.location`,
a `GeoPoint`, when the listing carries one (a Photos asset's
`PHAsset.location`; nil for a file, whose position the map takes from the
same header read, `PhotoLocations`, Features: Map). What a photo's header
says (camera, lens, exposure, dimensions, GPS) is a `PhotoInfo`
(`Info.swift`), read once per photo off the main thread and kept by
`Library.photoInfo` (Features: Adjustments panel, Info). The three
places the library shows a photo's name (Copy Settings, the Sync sheet,
the sidecar error) read `Library.name(for:)`, never the id.

A virtual copy is a third case, `PhotoID.copy`: its master's id plus a copy
number from `PhotoID.firstCopyNumber` (2), made by
`PhotoID.copy(of:number:)`, which takes the master's master so a copy of a
copy is a copy of the same photo. `PhotoID.master` is the id whose file or
asset it reads, `PhotoID.copyNumber` its number. `fileURL` and
`defaultName` answer with the master's (one file), so the renderer, the
thumbnails, Info, the capture date and `ImageLoading` read the master's
pixels, and `cacheKey` adds `#copy<n>`, so a copy's thumbnail is cached as
its own. `Photo.virtualCopy(number:)` is a listed photo's copy: the same
name, capture date and position. A source maps a copy to its master before
reading (`PhotosSource.originalFile(for:)`, `thumbnail(for:maxPixelSize:)`
and `name(for:)` switch on `id.master`; a folder's and a collection's
already read `fileURL`). The copy's sidecar and its discovery are the
store's (below); `Library.createVirtualCopy(of:)` and
`Library.removeVirtualCopy(_:)` are the model's two operations (Features:
Virtual copies). Where a copy shows as one: `Photo.caption` and
`Photo.copyLabel`, `VirtualCopyBadge`, the Info row
(`InfoSection.virtualCopy(_:)`), the export name (`ExportOptions.copySuffix`,
section 4) and `Library.canSaveToPhotos`, false on a copy.

Where photos come from is a `PhotoSource`: `title` (the window title),
`photos()` (in any order: `Library` sorts them by `Library.sort`, a
`PhotoSort`, Features: Grid, Sort), `sidecars` (the `SidecarStore` its edits
persist to), `sidecars(for:)` (the store ONE photo's edit persists to,
which `Library.persist` writes through; `sidecars` unless the source
overrides it) and `loadSidecars(for:)` (every listed photo's sidecar, read
by `Library.open`; `sidecars.loadAll` unless overridden), `thumbnail(for:maxPixelSize:)` (a downsample of the
unadjusted original, synchronous, run off the main thread by `Thumbnails`)
and `originalFile(for:)` (the one file the loupe master and the export
decode; async, since a source may have to fetch it). `FolderSource` is the
folder: `Library.scan` lists it, `SidecarStore(folder:)` keeps the edits
under `.photolab/`, `ImageLoading.downsampled` makes the thumbnails, and a
photo's original is its own file. `Library.open(_:)` takes a source, or a
URL that it wraps in a `FolderSource` (a folder, or a file whose folder
opens with that photo in the loupe), and `Library.open(album:access:)` an
album wrapped in a `PhotosSource`, and `Library.open(collection:)` a saved
collection wrapped in a `CollectionSource` (`Collections.swift`): its
members across folders, each routed by `sidecars(for:)` to
`SidecarStore(folder: member.root)` and read per root by `loadSidecars(for:)`,
so an edit made in a collection is the sidecar its folder reads (Features:
Collections). `Library.source` is the open one and `Library.folder` its
folder when it is a `FolderSource`. A source whose
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
(images only, oldest capture first: `PhotoKitLive.assetFetchOptions()`;
one pass over the fetch result for each asset's identifier,
`creationDate` and `location`, no `PHAssetResource` read), `originalFilename(of:)` (the
original resource's file name, `PhotoKitLive.originalResource(of:)`, one
asset at a time), `thumbnail(for:maxPixelSize:)`, `writeOriginal(of:to:)`, and the three
calls of the adjustment data (below): `hasAdjustments(_:)`,
`adjustment(of:)` and `saveEdit(_:to:render:)`. The live
client needs an app bundle: the system keys Photos access to a bundle
identifier and a usage string, both written by `scripts/bundle.sh`; under a
bare `swift run` it never fetches, and `PhotosAccess.hasBundle` is what the
Welcome view checks before offering the album sheet.

`PhotosSource.photos()` throws `PhotosError.notAuthorized` until the status
reads (`PhotosAuthorization.canRead`: authorized or limited), so `Library`
refuses the open and nothing is fetched; it lists the album through the
client, dating each photo by the asset's capture time
(`PhotosAsset.creationDate` -> `Photo.captureDate`), placing it by the
asset's position (`PhotosAsset.location` -> `Photo.location`) and leaving it unnamed
(`PhotosAsset.originalFilename` nil -> `Photo.isNamed` false) unless the
client's listing carried the name. A name is read per asset when asked,
`PhotosSource.name(for:)` (the `PhotoSource` requirement, defaulting to nil
for a source whose listing names everything) through
`OriginalsCache.name(of:client:)`, which keeps it (the cached copy's
extension comes from it; an asset with no original resource is named by
its identifier, and a read cut short by cancellation keeps nothing).
`Library.resolveName(_:)` is the one caller on screen: each visible grid and
filmstrip cell, off the main thread, a cancelled cell writing nothing
(Features, Opening a source); an export (`Library.exportItems(for:)`) and a
Save to Photos await it for their photo, so an output is never named by an
asset identifier. So a Recents of thousands opens with no name read and
`SidecarStore.loadAll` lists the flat sidecar directory once instead of
checking a file per photo. Thumbnails come from Photos' own cache:
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
`local.photolab.recipe`, format version `Sidecar.version(for:)` of the
recipe (1, 2 when it has masks, 3 when one is automatic, the rule a
sidecar file follows), and as
data the recipe-only sidecar JSON (`SidecarStore.encode`, no flag or
rating). `Library.saveToPhotos()` (enabled by `canSaveToPhotos`: the
anchor is an edited photo of a Photos album and no save is running; the
state is `photosSave`) closes an open drag and calls
`PhotosSource.saveEdit(_:for:name:)`, which takes the cached original
(`originalFile(for:)`) and hands `PhotoKitClient.saveEdit` the data and a
render closure: `Exporter.write` with `PhotosSource.saveOptions` (JPEG,
full size, metadata kept, no watermark), the same render and write path as an export.
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
section: `basic`, `color`, `curve`, `hsl`, `grading`, `detail`, `effects`,
`lens`, `geometry`)
and a `neutral` value, the value at which it does nothing (zero for every
kind). `AdjustmentKind.geometryKinds` is rotate plus the four crop edges: the
kinds a preset never carries and a `.look` sync never copies. `group` is the
render grouping above; `hsl` and `curveX` give the HSL kinds their channel
and band and the curve kinds their x position; `grade` gives a color-grading
kind its channel (`HSLChannel`) and range (`GradeRange`: shadow, midtone,
highlight), nil for `gradeBalance`, and `AdjustmentKind.grade(_:_:)` looks
one up.

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

`masks` is the recipe's local adjustments, a list of `LocalMask`
(`Masks.swift`), in the order they apply; `Recipe.neutral` has none. A
`LocalMask` is an `id`, a `MaskShape`, its own `adjustments` (only the kinds
in `LocalMask.kinds`: exposure, temperature, tint, contrast, highlights,
shadows, saturation; `init`, the subscript and decoding all drop any
other), `enabled` and `inverted`. `MaskShape` is `.linear(start:end:)`
(full effect at `start` fading to none at `end`),
`.radial(center:radii:angle:feather:)`, `.brush(_:)`, a list of
`BrushStroke` (`points`, `radius`, `feather`, `flow`, `erase`), or
`.auto(_:)`, an `AutoMask`: a `kind` (`AutoMaskKind`: subject, person,
sky), a `MaskBitmap` and `strokes` (default none) that refine it. A
`MaskBitmap` is an 8-bit grey raster over the whole source frame, rows
top-down, stretched onto the source whatever its own size; `init(gray:width:height:)`
box-filters anything above `MaskBitmap.maxLongSide` (2048) down to it. It
carries its pixels, the PNG it is stored as (`png`, written by
`MaskBitmap.encodePNG`: per-row adaptive filters, deflate by the Compression
framework) and `digest`, the SHA-256 (CryptoKit) of its size and pixels;
equality and hashing are the digest, so the same pixels in a differently
encoded PNG are the same bitmap, and a recipe compare never walks pixels. All
geometry is in the SOURCE frame, before the recipe's rotate and crop:
a `MaskPoint` is a fraction of the source's width and height with the
origin top-left, and every radius (`MaskRadii`, `BrushStroke.radius`) a
fraction of the source's long side, so a mask stays on the same pixels
under any crop or rotate. In the JSON a shape is one object with a `type`
(`linear`, `radial`, `brush`, `auto`) and that type's fields; an `auto`
shape's are `kind`, `bitmap` (`width`, `height`, `png` as base64; the
digest is recomputed from the decoded pixels, never read) and `strokes`
(read as none when absent). A bitmap whose PNG is not 8-bit grey of its
stated size, or is over the cap, does not decode. Masks are part of
the edit: equality and `normalized` (each mask in `LocalMask.normalized`
form, list order kept) include them; any mask makes a recipe not
`isDefault`; `isNeutral` also needs every mask to be a no-op
(`LocalMask.isNoop`: disabled, or every adjustment a no-op), so a
disabled or all-neutral mask renders as identity but is still an edit.
`Recipe`'s `Codable` reads a missing `masks` key as none and writes the
key only when there is a mask, so an unmasked recipe encodes exactly as it
did before masks existed. Every shape renders (§1, The chain): linear and
radial masks as Core Image gradients, brush masks as a cached CPU raster
(`BrushRaster`), automatic masks as their bitmap. `MaskKind` names the
automatic kinds Subject, Person and Sky (`MaskKind.init(_:)` from the
shape's `AutoMaskKind`); their `defaultShape` is a placeholder
(`MaskBitmap.blank`, selecting nothing), since an automatic mask is made by
a detection, not placed, and the overlay draws no handles for one
(`MaskHandles.positions(of:size:)` is empty, as for a brush).

The panel edits masks through `extension Library` in `MasksPanel.swift`:
`addMask(_:for:)` (a `MaskKind.defaultShape` appended), `updateMask(_:for:_:)`,
`duplicateMask(_:for:)` and `deleteMask(_:for:)`, each one
`Library.setRecipe`, so the one writer, undo and the sidecar carry them;
a mask slider is `MaskSliderEdit`, a `beginEdit` / `endEdit` pair around
its `updateMask` calls. Which mask the panel shows (`Library.selectedMask`)
and whether the brush is armed (`Library.maskBrushArmed`) are tool state
on `Library`, never in a recipe; `Library.apply` clears `selectedMask`
whenever the selected photo's new recipe no longer holds it, which covers
undo, redo, delete, reset and sync with one rule. Painting (`BrushTool.swift`) is one more
`updateMask` caller: `Library.paintBrush(from:to:erase:size:for:)` opens a
`beginEdit` on a stroke's first point and grows the brush's last
`BrushStroke` in place, and `Library.endBrushStroke` closes it, so a stroke
is one step; the brush it paints with (`Library.brush`, a `BrushSettings`)
is tool state like `selectedMask`.

### `Sidecar` and `SidecarStore`

A `Sidecar` is the on-disk form of one photo's edit: `version`,
`original` (the photo's file name, for a human
reading the directory), `updated` and `recipe`, plus three optional keys,
`flag` and `rating`, the culling marks (`Marks`, below), and `keywords`
(below Marks), each absent when unset
so a file written before they existed decodes unchanged. Keywords do not
enter the version: `Sidecar.version(for:)` reads the recipe alone, so a
file with keywords and no masks is still format 1. The `version` is
the format: 1 is a recipe of sliders, 2 adds `Recipe.masks`, 3 adds
automatic masks (`MaskShape.auto`);
`Sidecar.currentVersion` (3) is the newest this build reads, and every
writer stamps `Sidecar.version(for:)`, the LOWEST version that holds the
recipe (1 without masks, 2 with, 3 when any mask is automatic), so format 1
and 2 files are written byte for byte as before. An unmasked file therefore stays
byte-identical to what a build before masks wrote and readable there, and
a masked one is refused there as unreadable (and backed up) instead of
being read without its masks and written back without them. A later
format takes the next number under the same rule. `SidecarStore` reads and
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

A virtual copy's sidecar sits beside its master's under the same naming
plus `SidecarStore.copySuffix` and the number: `.photolab/IMG_0001.JPG@copy2.json`,
`UUID_L0_001@copy2.json`. No real photo's sidecar name ends that way: a
file's ends in its own image extension (`jpg@copy2` is no image type, so
`Library.scan` never lists such a file) and a Photos identifier has no `@`
(`VirtualCopyTests.testNoRealPhotoSidecarNameParsesAsACopy`).
`SidecarStore.parseCopy(_:)` reads a file name back as a master's relative
name and a number (n ≥ 2, no leading zeros), and
`SidecarStore.copies(of:)` lists each directory a master's sidecar would
be in once and returns the copies found for the masters given, by master
then number; a copy file whose master is not given is never returned or
touched. `PhotoSource.virtualCopies(of:)` runs it per store
(`sidecars(for:)`, so a collection reads each member's root), and
`Library.open(_:)` lists the copies after the listing, before
`loadSidecars` reads every id's file. `SidecarStore.save` always writes a
copy's file, even at the default recipe with no marks or keywords: the
file is how the copy exists.

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
  non-empty marks and the list of unreadable photos; under the flat naming
  it lists the directory once and reads only the ids with a file there. `Library` shows those
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
A reject is also what `Library.rejectedPhotos` collects for Move Rejected
Photos to Trash…: the one path that changes an original, through the
injected `FileTrasher` (`Trash.swift`; `Library(trasher:)`, the app's
`LiveFileTrasher`), leaving the sidecar where it is (Features: Move rejects
to the Trash). The other, Photo › Rename…, moves a file to a new name in
its directory and its sidecar and copy sidecars with it (`RenameMove`,
`Rename.swift`), after which `Library.rekey` moves every map keyed by the
old `PhotoID` (marks included) to the new one (Features: Rename in place).

### Keywords

A photo's keywords (`Keywords.swift`) follow the marks' rules exactly: a
list beside the recipe in the sidecar (`Sidecar.keywords`, written only when
not empty), never an undo step, never in a `Recipe`, `Preset` or
`SyncMask`. Every list is `Keywords.normalized` (trimmed, empty dropped,
de-duplicated ignoring case with the first spelling kept, sorted ignoring
case), so one set of keywords is one array and one JSON.
`Library.keywords` holds the non-empty lists for the open source, filled by
`SidecarStore.loadAll(for:)` on open; `Library.addKeywords(_:to:)` and
`Library.removeKeyword(_:from:)` change them for a list of photos and write
each changed photo's sidecar at once through `persist`, which passes the
recipe, the marks and the keywords to
`SidecarStore.save(_:marks:keywords:for:name:now:)`. Its nothing-to-keep
rule is the default recipe AND no marks AND no keywords, so a keyword on an
unedited photo keeps its file and a reset keeps the keywords; the
recipe-only `SidecarStore.save(_:for:name:now:)` carries over the marks and
keywords the file held. `Library.requestKeywords(for:)` sets
`Library.keywordsRequest`, the `KeywordsSheet` the window presents.

### Visibility: the filter and the search

What the grid shows is one predicate in `Library` (`Library.swift`), and
every selection path walks its result: `Library.visiblePhotos` is the
photos (in sort order) whose marks `PhotoFilter.admits(_:)` AND that
`Library.search` matches, and `Library.isVisible(_:)` is the same test for
one id. `Library.search` is `Library.searchText` as a `PhotoSearch`
(`Search.swift`): its terms, split at whitespace, ANDed, each found as a
substring ignoring case and diacritics in the photo's name (only once the
source has named it, `Photo.isNamed`) or in one of its keywords. The
search is view state, not data: nothing writes it to a sidecar or to the
recents' `SourceViewState`, and `open` empties it. A change to the filter,
the search, a mark or a keyword runs `Library.reconcileSelection()`, which
drops hidden photos from the selection and moves a hidden anchor on.

### `Preset` and `PresetStore`

A `Preset` is a named recipe: `version` (`Preset.currentVersion`), `name`,
`updated`, `recipe`. Its initialiser `Preset(name:from:updated:)` normalises
the recipe, sets every geometry kind to neutral and drops `Recipe.masks`,
so a look travels and a crop, a rotation or a local adjustment does not.
`Preset.apply(to:)` is the inverse at apply time: the preset's look over
the photo's own geometry and masks, taken from the current recipe. `Preset.matches(_:)` tells the strip which preset the photo already
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

### `XMPPreset`: Lightroom `.xmp` presets

`XMPPreset.parse(_:fileName:)` (`XMPPreset.swift`) reads the bytes of a
Lightroom Classic / Camera Raw `.xmp` preset into an `XMPImport` and never
writes the file. `XMPPreset.settings(in:)` runs Foundation's `XMLParser`
with namespaces on and collects every top-level setting of the Camera Raw
namespace (`XMPPreset.namespace`, whatever prefix the file binds it to),
in both forms Adobe writes: attributes of an `rdf:Description` and
elements, as `XMPPreset.Raw` text, a list (an `rdf:Seq` / `Bag` / `Alt`) or a
nested structure; the `crs:` keys inside a mask's correction or a Look's
parameters are never read as global settings. Malformed XML throws
`XMPImportError.notXML`, no Camera Raw setting `.noCameraRawSettings`.

`XMPPreset.interpret` applies D-471 (a). `XMPPreset.mapping` is the one
table of direct settings (the file's key, the `AdjustmentKind` it sets, a
scale): the 2012 basic tone, the incremental temperature and tint,
vibrance, saturation, clarity, Sharpness (0…150 onto 0…100), grain,
`LuminanceSmoothing` and `ColorNoiseReduction` (Lightroom's RAW default 25
read as 0, so a preset carrying it changes nothing), the
post-crop vignette, the 24 HSL sliders, Color Grading and the older Split
Toning, an earlier row winning when two set one kind. A value outside the
kind's `range` is clamped and named in `XMPImport.clamped`. The point curve
(`XMPPreset.pointCurveKey`) and the parametric curve
(`XMPPreset.parametricKeys`) are approximated onto the five curve points
(`XMPPreset.approximateCurve`: the point curve read linearly at 0, ¼, ½, ¾,
1, each parametric region lifting the inner points either side of it by
half `XMPPreset.parametricLift` per +100) and named in
`XMPImport.approximated`. A non-neutral setting with no slider is named
with a plain label by `XMPPreset.unsupportedRules` (profile, Look, Dehaze,
Texture, calibration, Kelvin white balance, per-channel curves, the global
grading wheel and blending, black & white, noise reduction, lens
corrections, transform, crop, masks, brushes, gradients, spot removal,
process 2010 tone); any other key away from its default
(`XMPPreset.secondaryDefaults`, else 0), a non-identity curve or a nested
structure is listed under `XMPPreset.plainLabel` of its key, so nothing that
may change a photo goes unlisted; `XMPPreset.metadataKeys` describe the file
and are skipped. Neutral settings are not listed. The recipe starts from `Recipe.neutral`, so it
carries no geometry, lens kind or mask, and `Preset(name:from:)` takes it as
any other (`XMPPresetTests`). `XMPImportModel` (`XMPImportSheet.swift`) reads it for
the Import Lightroom Preset sheet: it parses on init, shows a parse error instead of
throwing, and writes only through `PresetLibrary.save(_:as:)`; the moved sliders come
from `RecipeDiff.moved(from:to:)` (`Presets.swift`), a pure diff against a recipe that the
look-match sheet reuses (`XMPImportTests`).

### `EditSummary` and `MyEditsRow`: My Edits

`MyEdits.swift`. Both are pure values over recipes. `MyEditsRow.rows(photos:recipes:)`
filters `Library.photos` to those whose recipe has an enabled non-neutral entry or a
non-noop mask and groups the entries by `AdjustmentKind.section`;
`EditSummary(recipes:)` counts, per `AdjustmentKind`, the photos using it
(`Adjustment.isNoop` false) and their median. `Library.myEdits` joins them over
`Library.recipes`, `Library.myEditsSheet` shows `MyEditsSheet` from `ContentView`'s
`.sheet(isPresented:)`, and `Library.openFromMyEdits(_:)` sets `selection` and `loupe`.
No write path: it reads the already-loaded recipes (`MyEditsTests`).

### `MatchLookModel`: Match Look

`Library.matchLook(reference:to:)` (`Library.swift`) measures one reference image
(`Renderer.previewMaster` at `PreviewModel.masterPixelSize`, then
`ImageStats.of(master:recipe:)` under `.neutral`), solves each target with
`LookMatch.values(target:master:recipe:)` (detached tasks, at most
`Library.autoConcurrency`) and applies the results through `Library.sync(_:mask:)`
with `LookMatch.mask` after `closeOpenEdit()`: one batch tag, one undo step. It
reuses Auto's `autoToning`, `autoProgress` and `cancelAuto()`; it throws
`MatchLookError` (`unreadable`, `busy`, `cancelled`) with nothing applied and never
writes, copies or imports the reference file. `MatchLookOutcome` carries the
counts and `MatchLookOutcome.rows` (per slider, `RecipeDiff.moved` over each
photo's before and after). `MatchLookModel` (`MatchLook.swift`) is the sheet's
state (`setReference`, `match()`, `close()`), held in `Library.matchLookRequest`
and shown by `MatchLookSheet` (`ContentView`'s `.sheet(item:)`);
`Library.requestMatchLook(for:reference:)` opens it from the Photo menu or from
the loupe panel's `dropDestination` (`MatchLookTests`).

### `ExportOptions`

One value per export run, carried unchanged through the queue to every item:

- `format`, an `ExportOptions.Format`: `jpeg`, `heic` or `tiff`, each with
  its `fileExtension`, `utType` and `isLossy` (TIFF is lossless LZW, so
  `quality` means nothing to it).
- `quality`, clamped to `ExportOptions.qualityRange` by `clampedQuality`.
- `resize`, an optional `OutputSize`; nil writes the rendered size.
- `suffix`, appended to the original's stem (`fileName(for:)` gives
  `<stem><suffix>.<ext>`, and `<stem><suffix>-copy<n>.<ext>` for a virtual
  copy, its `copy:` number through `ExportOptions.copySuffix`, also after a
  template's stem in `fileName(stem:copy:number:)`), cleaned of anything a file name cannot hold
  (`RenameTemplate.clean`: `/`, `:`, `\`, NUL, line breaks).
- `nameTemplate`, an optional `RenameTemplate` (`Rename.swift`: `pattern`,
  `start`) that replaces `<stem><suffix>`: `{name}` the original's stem,
  `{date}` the capture date (`yyyy-MM-dd` in the local calendar, `undated`
  when none), `{seq}` the 1-based place in the batch from `start`, padded to
  the digits of `start + count - 1`; cleaned by the same rule, and an empty
  result is the original's stem. `ExportQueue.start` resolves it once per
  run (`templatedStems(for:)`) and hands each item's stem to the worker,
  which passes it to `Exporter.destination` in place of
  `fileName(for:)`'s. nil = `<stem><suffix>`; options stored by a build
  without the field decode with nil, and a stored template missing a field
  takes its default (`RenameTemplate.init(from:)`). The template is a stem
  only, so a later rename-in-place can reuse it.
- `collision`, an `ExportOptions.Collision`: `number`, `skip` or
  `overwrite` (section 4).
- `keepMetadata`, whether the source's camera metadata travels.
- `watermark`, an optional `Watermark` (`Watermark.swift`: `text`,
  `position`, `size`, `opacity`), drawn by the render's last stage
  (section 1, Output); nil = none. Options stored by a build without the
  field decode with nil, and a stored `Watermark` missing a field takes
  that field's default (`Watermark.init(from:)`).

`ExportQueue` keeps the last run's folder, target kind, Photos album and
options between runs, and in UserDefaults across launches through its
`AppSettings` when that is `persistent` (the app passes its own; a test's
`ExportQueue(remember: false)` gets one that keeps nothing).

### `ExportPreset` and `ExportPresetStore`

An `ExportPreset` (`ExportPresets.swift`) is a named `ExportOptions`:
`version` (`ExportPreset.currentVersion`), `name`, `options` — every
field above, the watermark included. The destination (`ExportTarget`) is
not in it. `ExportPresetStore` is one JSON file per preset,
`<directory>/<name>.json`, injected (`ExportPresetStore(directory:)`,
default `ExportPresetStore.defaultDirectory`, the `export-presets` folder
beside `PresetStore.defaultDirectory`'s `presets`, never inside it). It
follows `PresetStore`'s rules without changing that file: names through
`PresetStore.validated`, `/` and `:` as `-` in `url(for:)`, an atomic
`save(_:now:)` that replaces the same name and refuses a different name on
the same file (`ExportPresetError.fileNameCollision`), `decode` refusing a
`version` above `ExportPreset.currentVersion`
(`ExportPresetError.unsupportedVersion`), `save` over an undecodable file
moving it aside with `UnreadableBackup.moveAside` first, and `loadAll()`
returning the readable presets sorted by name plus the `.json` files it
could not decode, left alone. `remove(_:)` deletes the one file. Nothing is
seeded: the built-in presets (`ExportPreset.builtIn`, today `.web`) live in
code, never in the store. `ExportPresetLibrary` is the store read into
memory for the export sheet, re-read after every change, with the last
error; `builtIns` lists the built-ins no saved preset of the same name
replaces, `preset(named:)` finds a saved preset first and then a built-in,
and `isSaved(_:)` gates Delete Preset.

`ExportForm` is the export sheet's fields as one value: `options`, the
Size controls (`sizeMode`, `longSide`, `percent`), the Watermark section
(`watermarkOn`, `watermark`) and `picked`, the preset last picked or
saved. `resolved` folds them into the `ExportOptions` a run uses;
`pick(_:)` rebuilds every field from the preset's options (so the
previous watermark never survives a pick); `isEdited` compares `resolved`
with the picked preset's own resolved options, and `presetLabel` is the
menu's title ("None", the name, or "<name> (edited)").

### `AppSettings`

`AppSettings` (`Settings.swift`) is every value kept between launches, over
one injected `UserDefaults`: the Settings window's `gridThumbnailSize`,
`previewQuality` and `reopenLastSource`, the per-kind sort (`sort(for:)`,
`setSort(_:for:)`), `showFilmstrip`, `showInfo` and `showHistory`, `lastSource`
(a folder, an album or a collection, `LastSource`), `recents`, the export sheet's `exportFolder`, `exportOptions`,
`exportAlbum`, `exportTarget` and `exportPreset` (the last picked export
preset's name), and the import sheet's `importRoot`. The keys (`AppSettings.Key`) are the
strings earlier builds wrote, so nothing saved is lost. It is
`@Observable`: the grid, the loupe canvas and the Settings window read it
and redraw when it changes. With `persistent: false` it reads nothing and
writes nothing. The app makes one (`PhotoLabApp`) and passes it to
`Library(settings:)`, `ExportQueue(settings:)` and `Importer(settings:)`.

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
A crop handle drag in the loupe is the same: the first
`Library.dragCrop(_:by:fit:for:)` of a drag calls `beginEdit` and records
the crop it starts from, every move writes the handle's edges through
`setRecipe` (measured from that start, so the edges follow the pointer
without drift), and `Library.endCropDrag(_:)` calls `endEdit`. Picking a
crop aspect (`Library.setCropAspect(_:frame:for:)`) and the straighten
line (`Library.straighten(from:to:for:)`) are single `setRecipe` calls,
one step each, like a menu command; so is the white-balance eyedropper
(`Library.applyWhiteBalance(_:for:)`), which sets temperature and tint
together, so one undo takes both back. A color-grading wheel drag
(`GradeWheelDrag`, `GradeWheel.swift`) is a slider drag with two values:
its first move calls `beginEdit`, every move sets the range's hue and
saturation through `setRecipe` (from `GradeWheelMath.puck(at:side:hueAtCentre:)`,
pure, clamped at the rim), and mouse-up calls `endEdit`; the wheel's
double-click (`GradeWheelDrag.reset`) is one `setRecipe`. Its solve
(`WhiteBalance.neutralising`, `WhiteBalance.swift`) adds no adjustment
kind and no renderer: it renders the sampled colour as a 1×1
`CIImage(color:)` through `Renderer.apply` at candidate slider values
(a 5×5 grid over both ranges, then a compass search halving its step to
1/32 of a unit, clamped to the ranges), so the filter itself fixes the
sign and scale of each slider. The colour is the patch of
`WhiteBalance.base` (every kind from temperature on at neutral: the
white-balance stage's input), so the sliders' values before the pick do
not enter it.

### Undo and redo

`EditHistory` is per photo, kept for the open folder: an `undo` and a `redo`
stack of whole recipes (a recipe is a few hundred bytes, so snapshots beat
deltas), capped at `Library.maxUndoDepth`. Masks live in the recipe, so a
mask edit is an ordinary step with no undo path of its own
(`MaskModelTests`). Each `Step` carries the recipe to
go back to and an optional batch tag. `Library.undo()` and `Library.redo()`
act on the selected photo; when its top step carries a batch tag, every photo
whose top step carries the same tag goes with it, and a photo edited again
since keeps its later edit until that is undone first.

The panel's History section reads the stacks through
`Library.historyEntries(for:)`, a read-only list of `HistoryEntry` rows (the
oldest undo recipe as the Original, then the state after each undo step,
the current recipe, and the redo stack in redo order); `EditHistory` itself
stays private. Each row's label is computed from the two recipes on either
side of it (`HistoryLabel.describe(from:to:batch:)`; a change to
`Recipe.masks` is the one name "Mask"), so a new
`AdjustmentKind` labels itself and nothing about a step is stored beyond
what undo already keeps. `Library.jumpToHistory(_:for:)` is undo or redo
in a loop (the private `undo(anchor:)` / `redo(anchor:)` that `undo()` and
`redo()` call with the selection), never a separate write: the batch rule,
the sidecar writes and the redo-clearing push are the ones above. Nothing
here is persisted; `open` resets it.

### Batch

`SyncMask` (`Batch.swift`) is a set of kinds and a `masks` flag (whether
`Recipe.masks` travels, the whole list): `.look` is every kind but
geometry (what applying a preset does), `.grade` is the look without
exposure (each photo keeps its own brightness), `.everything` and `.nothing`
are the sheet's All and None; only `.everything` has `masks` on, so Look,
Grade and Auto (`AutoTone.mask`) keep each target's masks and All copies
the source's (the sheet's Masks checkbox sets `masks` by hand). `Recipe.syncing(_:from:)` is the one batch
primitive: the receiver with every kind in the mask taken from the source,
value and enabled flag alike, and the source's masks in place of its own
when `masks` is on, the rest kept, in normalized form.

`Library.sync(_:mask:to:)` runs that primitive over the target photos,
each through `setRecipe` with one shared batch tag (a `UUID` made for the
call), skipping a photo the sync would not change and returning how many
changed; because the tag is shared, `undo` from any photo of the batch takes
the whole batch back. `Library.apply(_:mask:to:)` applies a preset to many
photos as the same operation: `sync` with the preset's recipe and the mask
minus the geometry kinds, `masks` off (a preset holds none). Sync Settings (`requestSync`, the anchor's recipe
onto the other selected photos) and Paste Settings (`requestPaste`, the
recipe `copySettings(from:)` remembered) both put up a `SyncRequest`, which
the `SyncSheet` turns into one `sync` call with the mask the user ticked;
`batchTargets` is the list a batch acts on, in sort order.

`Library.sync(_:mask:)` is the same call with a source per photo, and
`sync(_:mask:to:)` is it with one source for all. Auto
(`Library.autoTone(_:)`) is its one other caller: each photo's six values
(`AutoTone`, see 1, The histogram) and its white balance become that photo's
source, applied with `AutoTone.mask` (or `AutoTone.whiteBalanceMask` for
Photo › Auto White Balance, `Library.autoTone(_:mask:)`) under one batch tag, so Auto on the grid's selection is one
undo step and one sidecar write per photo changed, and a photo Auto would
not change is skipped.

`Library.syncRedetecting(_:mask:from:to:)` is `sync` for a source that holds
`.auto` masks while `SyncMask.masks` is on (the sheet's Sync button always
calls it; without such a mask it is `sync`). It asks
`Library.detectAutoMasks(_:for:)` for each target's bitmap per `AutoMaskKind`
(each photo decoded once at `VisionDetector.inputPixelSize`, at most
`autoConcurrency` at a time off the main actor, `autoProgress` and
`cancelAuto()` shared with Auto; `.sky` is a guess (`SkyGuess`), not re-detected: it is left out and a sky mask is copied as it is;
nothing is written to a recipe, so a later detect-on-import flow can call it
too), then builds one source recipe per target: each `.auto` mask becomes
`AutoMask(kind:bitmap:)` with the target's bitmap (strokes dropped, the
`LocalMask`'s adjustments, `enabled` and `inverted` kept), or is left out
and counted in `autoNote` when the kind found nothing; a target whose
`Photo.ID.master` is the anchor's keeps the source's masks as they are.
The per-target sources go through `sync(_:mask:)` once detection ends: one
batch tag, one undo step.

### Detecting an automatic mask

`Library.selectAuto(_:for:)` (Select Subject, Select Person, Select Sky (guess)) is the one path
that makes an `.auto` mask from pixels; `Library.selectFaces(for:)` (Select
Faces) shares its run (`runAutoDetection`) and makes radial masks instead. It reads the photo's oriented decode,
`ImageLoading.downsampledCGImage` at `VisionDetector.inputPixelSize`
(`MaskBitmap.maxLongSide`, 2048): the thumbnail options apply the EXIF
orientation (`kCGImageSourceCreateThumbnailWithTransform`), so row 0 of the
decode is the top of the photo as displayed, which is the source frame a
`MaskBitmap` is defined over. A detached task hands it to
`Library.autoMaskDetector`, an `AutoMaskDetector` (AutoMasks.swift,
`Sendable`, `subject(in:)` and `person(in:) async throws -> MaskBitmap?`,
`faces(in:) async throws -> [VNFaceObservation]`, `horizon(in:) async throws
-> SkyGuess.Horizon?`, nil by default in a protocol extension); the app's is
`VisionDetector`: `VNGenerateForegroundInstanceMaskRequest` for a subject and
`VNGeneratePersonInstanceMaskRequest` for a person (both macOS 14, on
device) with `allInstances` merged by
`generateScaledMaskForImage(forInstances:from:)` into a buffer the size of
the input, `VNDetectFaceRectanglesRequest` for faces and
`VNDetectHorizonRequest` for the horizon (its `angle` only: Vision reports
no height, so the line passes through the centre column at
`SkyGuess.defaultHorizonY`). Sky has no model: in the detached task
`SkyGuess.mask(in:horizon:)` (SkyGuess.swift, pure) redraws the decode at
most `SkyGuess.analysisLongSide` px into an sRGB RGBA8 buffer, scores each
pixel (`score`), multiplies by the position prior (`prior`, via
`Horizon.y(atColumn:width:height:)`), doubles and caps at 1, keeps the
4-connected region reached from the top row above `connectThreshold`
(`connectedToTop`, an explicit stack), returns nil under `minCoverage`, and
box-blurs rows then columns (`boxBlur`, radius `blurFraction` of the long
side) into a `MaskBitmap` at the analysis size. A face's
observation never leaves the detached task: there
`FaceMasks.radial(for:roll:imageSize:)` turns its `boundingBox` (normalised,
origin bottom-left) into a `.radial` in the source frame, the centre's y
flipped (`1 - midY`), the radii the box's half width and height in pixels
over the decode's long side times `FaceMasks.margin`, the angle `-roll` in
degrees (Vision's roll is counter-clockwise, a radial's angle clockwise on
screen), feather `FaceMasks.feather`. `MaskBitmap(pixelBuffer:)` converts a one-component buffer
(`OneComponent8` as is, `OneComponent32Float` clamped and rounded to 8 bits;
row padding skipped, any other format nil) keeping row 0 at the top. Back on
the main actor the result is dropped unless `autoMaskGeneration` (bumped by
a photo change and by opening a source) and the selection are what they were
at the start; a nil or blank bitmap (no faces, for Select Faces) sets
`autoMaskMessage`; otherwise any open edit is closed and one `setRecipe`
appends the mask (every face's mask, the first selected), one undo step and
one sidecar write. `autoMaskDetecting` holds a second run off.

## 4. Export pipeline

### `ExportQueue`

`ExportQueue` (`Batch.swift`) is one per app. `requestExport(_:)` puts up the
options sheet for a list of `ExportQueue.Item` (a source URL, its recipe,
`protected`, the open library's originals, and the photo's `keywords`, from `Library.exportItems(for:)`,
which snapshots the recipes and keywords at that moment: an edit made while the sheet is
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
source, recipe, `protected` set, name, keywords, templated stem and
`copyNumber` (a virtual copy's, `PhotoID.copyNumber`); it is injected so a test can count or
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
sheet's Allow Access to Photos… button, the only prompt) and
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

`Exporter.export(_:name:stem:copy:recipe:into:options:protected:keywords:renderer:)` (`Batch.swift`) writes
one photo:

1. `Exporter.destination(for:name:stem:copy:in:options:)` names the file:
   `<stem><suffix>.<ext>` from `ExportOptions.fileName(for:)` (a virtual
   copy's with `-copy<n>` before the extension, so it never takes its
   master's name). Under
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
   applies the recipe with `resize` and `watermark` from the options, the
   resize and then the watermark as the chain's last steps (section 1).
4. The output properties: when `keepMetadata` is on,
   `ExportMetadata.properties(of:outputWidth:outputHeight:)`, every property
   ImageIO reads from the source (TIFF make and model, the EXIF block, GPS,
   IPTC) with what described the source container corrected or dropped:
   orientation 1 at the top level and in the TIFF block (the render is
   already upright), the EXIF pixel dimensions set to the output's, the
   source format's own dictionaries and its compression and photometric tags
   removed; then, when the item has keywords,
   `ExportMetadata.setting(keywords:in:)` sets the IPTC Keywords to them
   (replacing the source's, keeping the rest of its IPTC block). With
   `keepMetadata` off nothing is carried, keywords included. Then the lossy quality for JPEG and HEIC, and LZW compression for
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

### Import

The one path that writes photo files the user did not export, and it
writes only under the import root. `ImportPlan.make(source:root:captureDate:)`
(`Import.swift`) walks the source (hidden entries and package contents
skipped), takes every regular file whose type conforms to `public.image`
(so a RAW+JPEG pair is two items) and counts the rest in `otherFiles`; each
goes to `<root>/YYYY/YYYY-MM-DD/<name>` by `CaptureDates.read` (the sort's
rule, read only, unchanged), or `<root>/Undated/` when no date can be read.
Where it would land, a file of the same name AND byte size
(`ImportPlan.sizeOnDisk`) makes it `already`; another size moves it on to
`ImportPlan.numbered` (`<stem> 2.<ext>`, `<stem> 3.<ext>` …), each checked
the same way, as is a name another file of the same run took. `Importer`
copies `copies` in order like `ExportQueue` (a main-actor task, each file
on a detached task, Cancel after the file in flight, one `Failure` per file
that throws) through `Importer.copy(_:to:)`: `copyItem` to a hidden
`.<name>.partial` beside the destination, then `moveItem`, which fails
rather than replace a file; the partial is removed on every failure. The
source is only read. The capture-date reader, the `VolumeLister`, the
ejector and the copier are injected; every test passes temporary folders.
`Importer` never writes a sidecar: `Importer.open(in:presets:)` opens the
common folder, then, for `Importer.develop` (`ImportDevelop`, kept as
`AppSettings.importDevelop`) other than `.none`, hands the `Photo.ID`s whose
`fileURL` is a destination in `Importer.copied` to `Library.autoTone(_:)`
(a task, `Importer.waitDevelop()` in tests) or `Library.apply(_:to:)`, so
`Library.setRecipe` stays the only edit path and the batch is one undo step.

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

        ExportPresetStore  <export-presets dir>/<name>.json  (ExportOptions only;
                           a pick fills ExportForm, never a recipe)
```

Sidecars, presets and batches reach a photo's recipe only through
`Library.setRecipe`; the renderer reads recipes and never writes one; the
original file is read by both inputs and written by nothing.
