# PhotoLab

A Lightroom-style photo editor for the Mac: non-destructive adjustments you
can toggle one by one, named presets, and batch apply to many photos at once.
Native Swift, SwiftUI and Core Image. Originals are never written to.

## Run

    swift build                   # debug build
    swift run PhotoLab            # opens the last folder (or ⌘O)
    swift run PhotoLab ~/Pictures # open a folder directly
    swift run PhotoLab ~/Pictures/DSC01.ARW   # open one photo in the loupe
    swift test                    # the test suite
    scripts/bundle.sh --open      # release build as build/PhotoLab.app

Needs macOS 14 or later (the `platforms` line in `Package.swift`) and Xcode
(free; no developer account is needed to build or run locally). On macOS 27
the bare Command Line Tools cannot build SwiftUI (the SDK needs a macro
plugin only Xcode ships), so select Xcode once: `sudo xcodebuild -license
accept`, then `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`;
`xcode-select -p` must print a path inside Xcode.app. Opening `Package.swift`
in Xcode works too.

## Keys

| Key | Does |
| --- | --- |
| `⌘O` | Open Folder… |
| `G` | Grid |
| `E` or `Return` | Loupe (the selected photo, or the first) |
| `Esc` | Back to the grid; in the grid, collapse the selection to the anchor |
| `←` `→` | Previous / next photo |
| `\` | Toggle before / after (or hold the **Before** button) |
| `⌘A` | Select All Photos (grid only) |
| `⌘Z` / `⇧⌘Z` | Undo / Redo |
| `⇧⌘R` | Reset Photo (back to the original) |
| `⇧⌘P` | Save Preset… (in the loupe) |
| `⇧⌘C` / `⇧⌘V` | Copy Settings / Paste Settings… |
| `⇧⌘E` | Export… (the grid's selection, or the loupe's photo) |

`Return` and `Esc` also confirm and cancel the welcome screen's Open Folder…,
the Sync sheet and the Export sheet. Sync Settings… and the preset names in
the Presets menu have no key.

With the mouse, in the grid: click selects one photo, `⇧`-click selects
every photo between the anchor and it (the anchor kept), `⌘`-click adds or
removes one (the anchor moves to a photo added), double-click opens it in
the loupe. In the loupe: double-click the photo to go back to the grid,
double-click an adjustment's name to reset it, hold **Before** to see the
original.

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

Every slider is one entry in the photo's recipe, so the sidecar, undo,
presets and batch apply treat them all alike. Spatial effects (clarity,
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
photo through the same renderer as the main view. Click one to apply it
(one undo step, the sidecar is written; the photo keeps its own rotation
and crop), right-click for Apply, Update with Current Settings, Rename and
Delete. **Save…** (or `⇧⌘P`, or Presets › Save Preset…) saves the current
look under a name; a preset of the same name is replaced. The Presets menu
lists them all for the selected photo.

Presets are files you can copy between Macs:
`~/Library/Application Support/PhotoLab/presets/<name>.json`. A fresh
install starts with six looks (Neutral, Warm Film, Cool Matte, High-Contrast
B&W, Faded, Punchy); delete or change them freely, and the strip's `…` menu
has Restore Starter Presets and Show Presets Folder in Finder.

## Batch

Select several photos in the grid (`⇧`-click a range, `⌘`-click to add or
remove, `⌘A` for all; the heavier frame is the anchor, the photo the loupe
shows). A bar appears under the grid, with **Deselect** to collapse the
selection back to the anchor:

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
- **Export…** renders every selected photo into a folder (`⇧⌘E` from
  anywhere exports the selection, or the loupe's photo). A sheet asks, and
  remembers for next time: the format (**JPEG**, **HEIC**, or lossless
  LZW **TIFF**), the JPEG/HEIC quality, the size (as edited, an exact long
  side in pixels, or a percentage; never upscaled), a name suffix
  (`DSC06727` + `-edit` → `DSC06727-edit.jpg`), what to do when the file
  exists (**Add a number** `<photo> 2.jpg`, **Skip**, or **Overwrite**;
  the original is never overwritten, even when exporting into its own
  folder), whether the camera info travels (EXIF, GPS and IPTC are copied
  from the original with the orientation reset, since the render is
  already upright), and the output folder. A bar at the bottom of the
  window shows the count done, the file in flight and Cancel, which stops
  after that file; what is written stays, a skipped file is counted.

Copy Settings (`⇧⌘C`) remembers one photo's settings; Paste Settings…
(`⇧⌘V`) opens the same sheet onto whatever is selected, so a look can be
carried between folders. Every batch write goes through the same path as a
slider move: one sidecar per photo, written at once, and the whole batch is
**one undo step**: `⌘Z` on any photo of the batch takes them all back
(a photo you edited again since keeps its later edit; undo that first).

## On disk

Everything the app writes, and nothing else:

- **Sidecars** — `<folder>/.photolab/<file>.json`, one per edited photo,
  next to the photos. Removed when the photo is reset to the original.
- **Presets** — `~/Library/Application Support/PhotoLab/presets/<name>.json`,
  one per preset; the six starter looks are written there when that folder
  does not exist yet.
- **Preferences** — in the app's UserDefaults: the last opened folder, the
  last export folder and the last export options (format, quality, size,
  suffix, collision policy, metadata), so the next export sheet opens with
  them.
- **Exports** — the files you ask for, in the folder you choose, written
  through a hidden partial file and moved into place when complete.
- **The release bundle** — `build/PhotoLab.app`, made by `scripts/bundle.sh`
  (ad-hoc signed; `swift build` puts debug builds under `.build/`).

The original photo is never written to, under any of these.

## Design

Edits are data: a photo's edit is a recipe, a list of adjustments each with
a value and an enabled flag, saved as a sidecar JSON and changed only through
one method in the library that records the undo step and writes the file.
One Core Image chain renders every recipe, for the loupe, the preset strip
and the export alike; only the input image and the output size differ. A
preset is a named recipe without the crop and rotation, and a batch is that
same write with a mask over a selection, so undo takes a whole batch back.
How each of these works, with the types that implement it, is in
[Documentation/Architecture.md](Documentation/Architecture.md).
