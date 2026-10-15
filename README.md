# PhotoLab

A Lightroom-style photo editor for the Mac: non-destructive adjustments you
can toggle one by one, named presets, and batch apply to many photos at once.
Native Swift, SwiftUI and Core Image. Originals are never written to.

## Run

    swift run PhotoLab            # debug build, last folder (or ⌘O)
    swift run PhotoLab ~/Pictures # open a folder directly
    swift run PhotoLab ~/Pictures/DSC01.ARW   # open one photo in the loupe
    swift test                    # recipe, chain and render-time tests
    scripts/bundle.sh --open      # release build as build/PhotoLab.app

Needs macOS 14+ and Xcode (free). On macOS 27 the bare Command Line Tools
cannot build SwiftUI (the SDK needs a macro plugin only Xcode ships), so
select Xcode once: `sudo xcodebuild -license accept` then
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. Opening
`Package.swift` in Xcode works too. No developer account is needed to build
or run locally.

## Keys

`⌘O` open folder · `G` grid · `E` or `Return` loupe · `Esc` back (in the
grid: back to one selected photo) · `←` `→` previous / next photo ·
double-click a thumbnail to open it · click, `⇧`-click and `⌘`-click to
select several, `⌘A` all · `\` before / after (or hold the Before button) ·
`⇧⌘P` save preset · `⇧⌘C` / `⇧⌘V` copy / paste settings · `⇧⌘E` export.

## Adjustments

The loupe's panel is in sections, each slider with a checkbox that switches
it off without losing its value; double-click a name to reset it, Reset for
the lot. `⌘Z` / `⇧⌘Z` undo and redo (a slider drag is one step), Reset or
`⇧⌘R` puts the photo back to the original. The footer prints the time of
the last frame.

- **Basic** — exposure (EV), contrast, highlights, shadows, whites, blacks.
- **Color** — temperature, tint, vibrance, saturation.
- **Tone Curve** — five points (blacks, shadows, midtones, highlights,
  whites), each moved up or down.
- **HSL** — hue, saturation and luminance for eight bands (red, orange,
  yellow, green, aqua, blue, purple, magenta); pick the channel, then the
  band sliders. Grays are never touched.
- **Detail** — clarity (local contrast), sharpening, grain.
- **Effects** — vignette (negative darkens the corners).
- **Crop & Rotate** — rotate (degrees, positive is clockwise; the frame is
  cropped to the largest same-shape rectangle, so no empty corners) and a
  crop from each edge in percent of the frame.

Every slider is one entry in the photo's recipe, so the sidecar, undo and
the presets to come treat them all alike. Spatial effects (clarity,
sharpening, grain, vignette) are sized relative to the image, so the preview
and an export look the same.

## Sidecars

Every edit is saved the moment it changes, as JSON in a hidden `.photolab/`
directory inside the photo's folder: `Pictures/IMG_0001.JPG` has its edit in
`Pictures/.photolab/IMG_0001.JPG.json` (the extension is kept, so a `.JPG`
and a `.HEIC` of the same name never share one). Opening the folder again,
in this app or after a quit, shows the same edit; the grid marks edited
photos with a sliders badge. A photo reset to the original has no sidecar.
To wipe every edit in a folder, delete its `.photolab/` directory. The
original is never written to, so a folder that is read-only still opens;
the panel then says the edit could not be saved.

## Presets

A preset is a named look: every slider except rotate and crop. The loupe's
panel opens with a **Presets** strip, each preset drawn live on the current
photo through the same renderer as the main view (about 1 ms each). Click
one to apply it (one undo step, the sidecar is written; the photo keeps its
own rotation and crop), right-click for Apply, Update with Current Settings,
Rename and Delete. **Save…** (or `⇧⌘P`, or Presets › Save Preset…) saves
the current look under a name; a preset of the same name is replaced. The
Presets menu lists them all for the selected photo.

Presets are files you can copy between Macs:
`~/Library/Application Support/PhotoLab/presets/<name>.json`. A fresh
install starts with six looks (Neutral, Warm Film, Cool Matte, High-Contrast
B&W, Faded, Punchy); delete or change them freely, and the strip's `…` menu
has Restore Starter Presets and Show Presets Folder in Finder.

## Batch

Select several photos in the grid (`⇧`-click a range, `⌘`-click to add or
remove, `⌘A` for all; the heavier frame is the anchor, the photo the loupe
shows). A bar appears under the grid:

- **Sync Settings…** copies the anchor's settings onto the other selected
  photos. The sheet has a checkbox per adjustment (sections fold open; HSL
  is three checkboxes, one per channel) and four shortcuts: **All**,
  **None**, **Look** (everything but rotate and crop, the default) and
  **Grade** (the look without exposure, so each photo keeps its own
  brightness and framing). An unchecked adjustment keeps each photo's own
  value; a checked one takes the anchor's, zero included.
- **Apply Preset** applies a preset to every selected photo (its look over
  each photo's own crop and rotation). The Presets menu does the same for
  the selection.
- **Export…** renders every selected photo to a full-size JPEG in a folder
  you choose (`⇧⌘E` from anywhere exports the selection, or the loupe's
  photo). A bar at the bottom of the window shows the count done, the file
  in flight and Cancel, which stops after that file; what is written stays.
  Names are `<photo>.jpg`, never overwriting: a second export of the same
  photo into the same folder is `<photo> 2.jpg`. Quality, resize and
  metadata come in chunk 7 (default quality, no resize for now).

Copy Settings (`⇧⌘C`) remembers one photo's settings; Paste Settings…
(`⇧⌘V`) opens the same sheet onto whatever is selected, so a look can be
carried between folders. Every batch write goes through the same path as a
slider move: one sidecar per photo, written at once, and the whole batch is
**one undo step**: `⌘Z` on any photo of the batch takes them all back
(a photo you edited again since keeps its later edit; undo that first).

## Design

- **Edits are data.** Each photo gets a sidecar JSON: an ordered list of
  adjustments, each with parameters and an enabled flag. Toggles, undo,
  presets and batch apply are all edits to that list. Undo is a stack of
  whole recipes per photo, kept for the open folder. (Chunk 3.)
- **One render path.** `Renderer.apply` is the Core Image filter chain for a
  recipe; the loupe feeds it a 3200 px ImageIO master, the export will feed
  it the full-resolution decode, so the two cannot drift in color. A slider
  step re-renders at the view's pixel size (about 4 ms for a 24 MP JPEG,
  9 ms for a RAW, on an M4, with the six basic sliders; about 12 ms with
  every section switched on). (Chunk 2, chunk 4.)
- **Grouped stages.** The tone sliders and the curve are one per-channel
  lookup, the 24 HSL sliders one 3D color cube, both built on the CPU with
  Accelerate and cached by their values; the four crop edges are one crop.
  Kinds apply in a fixed order (geometry, exposure and white balance, tone,
  color, HSL, detail, effects) whatever order the sidecar lists them in.
  (Chunk 4.)
- **A preset is a named recipe.** One JSON file per preset in a user-level
  folder, carrying every kind but geometry; applying one writes the photo's
  sidecar through the same `setRecipe` path as a slider, so it undoes like
  one. The strip's thumbnails are the same chain at 160 px. (Chunk 5.)
- **A batch is a sync mask over a selection.** Sync, Paste and Apply Preset
  are one operation: for each selected photo, the kinds in the mask are
  taken from the source recipe and the rest kept, written through
  `setRecipe` per photo. The undo steps of one batch share a tag, so undo
  from any photo of the batch takes back every photo whose latest step is
  that batch. The export queue feeds the full-resolution decode into the
  same `Renderer.apply` as the loupe, one photo at a time, cancellable
  between files. (Chunk 6.)
