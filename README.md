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

**Open Recent:** File › Open Recent (and a list on the Welcome screen) holds
the last 10 folders and Photos albums, most recent first, with Clear Menu.
Each source reopens at the photo, grid or loupe, and filter you left it in.

**Photos library:** File › Open Photos Library… (`⇧⌘O`, or the Welcome
button) lists Recents and your albums; the first time, click **Allow** in
the system dialog. It works only from the bundled app
(`scripts/bundle.sh --open`, then `build/PhotoLab.app`): macOS grants Photos
access to an app bundle, never to a bare `swift run`, whose Welcome screen
says so. The bundle is ad-hoc signed by default, and the grant is tied to
the signature, so Photos asks again after every rebuild; to keep it, make a
self-signed code-signing certificate once (Keychain Access › Certificate
Assistant › Create a Certificate, type Code Signing, e.g. "PhotoLab Dev")
and build with `PHOTOLAB_SIGN_IDENTITY="PhotoLab Dev" scripts/bundle.sh
--open`. PhotoLab reads the originals (the RAW of a RAW+JPEG pair) and
shows them unadjusted: an edit made in Photos is not shown. An iCloud-only
original is downloaded the first time its photo opens in the loupe.

**Save to Photos** (File menu, or the loupe's toolbar button, for an edited
photo of a Photos album) writes the edit into Photos itself: Photos shows
the edited photo, **Revert to Original** there takes it back, and the
recipe travels with the photo as PhotoLab's adjustment data (Photos may ask
you to allow the change). Saving again replaces the edit. PhotoLab's own
record stays the sidecar: reverting in Photos does not change what PhotoLab
shows. When a photo has no sidecar (another Mac, or the sidecar deleted)
and Photos holds PhotoLab's edit for it, opening it in the loupe brings the
recipe back and writes the sidecar; another app's edit is ignored.

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
| `⇧⌘O` | Open Photos Library… (the album sheet) |
| `G` | Grid |
| `E` or `Return` | Loupe (the selected photo, or the first) |
| `Esc` | Back to the grid; in the grid, collapse the selection to the anchor |
| `←` `→` | Previous / next photo |
| `\` | Toggle before / after (or hold the **Before** button) |
| `Y` | Before and After side by side (or the toolbar's **Before / After** toggle); from the grid it opens the loupe |
| `J` | Toggle the clipping warning (blown pixels red, crushed pixels blue; or click a histogram triangle) |
| `F` | Show or hide the filmstrip under the loupe (a View menu item; the choice is remembered) |
| `P` / `X` / `U` | Flag the selection as a pick / a reject / unflagged |
| `0` … `5` | Rate the selection that many stars (`0` clears) |
| `⌘A` | Select All Photos (grid only) |
| `⌘Z` / `⇧⌘Z` | Undo / Redo |
| `⇧⌘R` | Reset Photo (back to the original) |
| `⇧⌘P` | Save Preset… (in the loupe) |
| `⇧⌘C` / `⇧⌘V` | Copy Settings / Paste Settings… |
| `⇧⌘E` | Export… (the grid's selection, or the loupe's photo) |

Every key above except `Return` and `Esc` is also a menu item: File (open,
Export…, Save to Photos), Edit (Undo / Redo, the settings items, Select All
Photos), **View** (Grid, Loupe, Before and After, Show Original, Clipping
Warning, Filmstrip, Previous and Next Photo) and **Photo** (Pick, Reject, Unflag, the
ratings, Reset Photo). A single-letter key is written after its menu item's
name, as in "Pick (P)", rather than bound to the menu, so typing that letter
into a text field (a preset's name, the export suffix) types the letter.

The same actions are clickable: Pick, Reject, Unflag and five stars in the
loupe panel footer (the one photo) and in the batch bar (the selected
photos), and a right-click menu on a grid photo (Pick, Reject, Unflag,
Rating, Apply Preset, Copy and Paste Settings, Export, Reset Photo, and Show
in Finder for a folder photo). A right-click on a photo outside the selection
acts on that photo alone, inside it on the whole selection. Open Photos
Library sits in the toolbar beside Open Folder (disabled outside the app
bundle).

`Return` and `Esc` also confirm and cancel the welcome screen's Open Folder…,
the Sync sheet and the Export sheet. Sync Settings… and the preset names in
the Presets menu have no key.

With the mouse, in the grid: click selects one photo, `⇧`-click selects
every photo between the anchor and it (the anchor kept), `⌘`-click adds or
removes one (the anchor moves to a photo added), double-click opens it in
the loupe. In the loupe: a filmstrip of the visible photos runs under the photo (click a cell to move there, `⇧`-click to extend the selection, `⌘`-click to toggle); double-click the photo to go back to the grid,
double-click an adjustment's name to reset it, hold **Before** to see the
original, press `Y` to see the original and the edit side by side.

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
  folder, and neither is any other photo of the open library: an Overwrite
  that would land on one fails for that photo and the bar says why), whether the camera info travels (EXIF, GPS and IPTC are copied
  from the original with the orientation reset, since the render is
  already upright), and where it goes: a **Folder**, or the **Photos
  library**. For Photos each photo is rendered with the same options and
  added as a new photo, into an album (default **PhotoLab**, created the
  first time; clear the field for the library only); there is no collision
  choice, since every export is a new photo, and a photo opened from Photos
  comes back as a new photo beside its original, which is not changed.
  Photos needs the app bundle (`scripts/bundle.sh`) and your permission:
  the sheet's **Allow Access…** is the only place it is asked. A bar at the
  bottom of the window shows the count done, the file in flight and Cancel,
  which stops after that file; what is written stays, a skipped file is
  counted.

Copy Settings (`⇧⌘C`) remembers one photo's settings; Paste Settings…
(`⇧⌘V`) opens the same sheet onto whatever is selected, so a look can be
carried between folders. Every batch write goes through the same path as a
slider move: one sidecar per photo, written at once, and the whole batch is
**one undo step**: `⌘Z` on any photo of the batch takes them all back
(a photo you edited again since keeps its later edit; undo that first).

## On disk

Everything the app writes, and nothing else:

- **Sidecars** — `<folder>/.photolab/<file>.json`, one per edited, flagged
  or rated photo, next to the photos. Removed when the photo is reset to the
  original and carries no flag or rating. A sidecar this version cannot
  read is kept beside the new one as `<file>.json.unreadable-<stamp>`,
  never deleted.
- **Presets** — `~/Library/Application Support/PhotoLab/presets/<name>.json`,
  one per preset; the six starter looks are written there when that folder
  does not exist yet.
- **Photos sidecars** — `~/Library/Application Support/PhotoLab/photos-sidecars/<asset-id>.json`,
  one per edited, flagged or rated photo of a Photos album (the asset's
  identifier with its slashes as underscores), with the same rules as a
  folder's sidecars. The Photos library is written to only by an export
  you send there (new photos) and by Save to Photos (the edit of that one
  photo: a rendered JPEG plus PhotoLab's adjustment data, which Photos keeps
  beside the untouched original).
- **Originals cache** — `~/Library/Caches/PhotoLab/originals/<asset-id>.<ext>`,
  a copy of each Photos original the loupe or an export has opened (an
  iCloud-only original is downloaded into it once). A cache: delete the
  folder to reclaim the space; the next open downloads again, and no edit
  is lost.
- **Preferences** — in the app's UserDefaults: the last opened source (a
  folder's path, or a Photos album's identifier), the
  last export folder, target (Folder or Photos) and Photos album, and the
  last export options (format, quality, size, suffix, collision policy,
  metadata), so the next export sheet opens with them.
- **Exports** — the files you ask for, in the folder you choose, written
  through a hidden partial file and moved into place when complete. An
  export to Photos renders each file into `$TMPDIR/PhotoLab-export/<run>/`,
  hands it to Photos and removes it; the run's folder goes when it ends.
- **The release bundle** — `build/PhotoLab.app`, made by `scripts/bundle.sh`
  (signed with `PHOTOLAB_SIGN_IDENTITY`, default ad hoc; `swift build` puts
  debug builds under `.build/`).

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
