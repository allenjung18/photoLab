# PhotoLab

A Lightroom-style photo editor for the Mac: non-destructive adjustments you
can toggle one by one, named presets, and batch apply to many photos at once.
Native Swift, SwiftUI and Core Image. Originals' pixels are never written
to; the two commands that change a file are Move Rejected Photos to
Trash…, which moves a folder's rejects to the macOS Trash after a confirm,
and Rename…, which renames the selected files where they are after a
preview, both undoably.

## Run

    swift build                   # debug build
    swift run PhotoLab            # opens the last folder (or ⌘O; Settings can turn this off)
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
original is downloaded the first time its photo opens in the loupe. A large
album (a Recents of thousands) opens at once: every cell is there from the
start, and each photo's name and thumbnail load as its cell scrolls into
view, so a caption stays blank until then.

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
| `⌥⌘M` | Map: the shown photos that carry a GPS position, as pins on a map in the grid's place (again, or `G`, goes back to the grid) |
| `Z` | In the loupe, 1:1 (one photo pixel per screen pixel) at the middle of the photo, or back to fit |
| `R` | In the loupe, crop mode: drag the crop's edges and corners on the photo (or **Crop on Photo** in Crop & Rotate); `R` or `Esc` again to finish |
| `W` | In the loupe, the white-balance eyedropper (or **White Balance** in Color): click something that should be neutral grey or white, at fit or 1:1, and temperature and tint are set so it renders grey, one undo step; a clipped or near-black spot is refused with a note and changes nothing; `W` or `Esc` puts it down |
| `M` / `⇧M` | In the loupe, arm a new linear / radial gradient mask: drag on the photo to place it (start to end; centre to edge), or click for the default shape there; again or `Esc` disarms (see Masks) |
| `K` | In the loupe, paint: arms the selected brush or automatic mask, or adds a new brush mask; drag on the photo to paint, hold `⌥` at the start of a drag to erase; `K` again or `Esc` puts the brush down |
| `[` / `]` | While the brush is armed, a smaller / larger brush (a quarter each step, Photo › Smaller Brush / Larger Brush) |
| `O` | Show the selected mask as a red tint over the loupe photo (View › Show Mask Overlay); never in Before or an export |
| `Esc` | Stop a running Auto batch (nothing is applied); else put the white-balance eyedropper down; else the brush; else a new mask's placement; else the straighten tool; else leave crop mode; else deselect the mask (its handles go); else back to the grid; in the grid, collapse the selection to the anchor |
| `←` `→` | Previous / next photo |
| `\` | Toggle before / after (or hold the **Before** button) |
| `Y` | Before and After side by side (or the toolbar's **Before / After** toggle); from the grid it opens the loupe |
| `J` | Toggle the clipping warning (blown pixels red, crushed pixels blue; or click a histogram triangle) |
| `F` | Show or hide the filmstrip under the loupe (a View menu item; the choice is remembered) |
| `⌘I` | Show or hide the Info section of the loupe panel (from the grid it opens the loupe with it shown; the choice is remembered) |
| `P` / `X` / `U` | Flag the selection as a pick / a reject / unflagged |
| `0` … `5` | Rate the selection that many stars (`0` clears) |
| — | RAW+JPEG pairs: in a folder, a RAW and the JPEG (or HEIC) of the same name show as one photo with a **RAW+JPG** badge; you edit and export the RAW, and Trash and Rename move both files. A JPEG you already edited, flagged, rated or keyworded keeps its own cell. Info shows the companion under **Paired With** |
| `⌘⌫` | Move Rejected Photos to Trash…: every rejected photo of the open folder or collection, shown by the filter or not, to the macOS Trash after a confirm that names the count and the first names. Each edit and its marks stay in `.photolab/`, so the Finder's **Put Back** restores the photo with them; the banner's **Undo** or **Edit › Undo Move to Trash** brings them back until you open another folder, album or collection. A file that cannot move stays and is named in the banner. Photos album photos are never offered |
| — | Rename… (Photo menu, no key) on the selection of a folder or collection: a template of text and `{name}`, `{date}`, `{seq}` (from a start number, zero-padded for the batch), every old → new name previewed; each file keeps its extension and is renamed where it is, its edit, marks, keywords and virtual copies with it. A name taken by another file, two photos given one name, a name starting with a dot, an edit already saved under a new name, or no name changing refuses the whole batch. A selected virtual copy renames its master. The banner's **Undo** or **Edit › Undo Rename** gives the old names back until you open another source |
| `⌘K` | Keywords… on the selection: a sheet with a field that adds comma-separated keywords to every selected photo and each keyword already on any of them, with "all" or "n of N" and a remove button; not an undo step, and Reset leaves keywords |
| `⌘F` | Search Photos: the search field at the left of the bar above the grid (from the loupe it goes back to the grid); every word typed must match a photo's name or one of its keywords, ignoring case and accents, on top of the filter; `Esc` clears it, `Return` leaves it; not remembered when you open another folder or album. While it has the focus every single-key shortcut (`P`, `X`, `0`–`5`, the arrows, `Esc`, `Return`…) types into it instead |
| `⌘A` | Select All Photos (grid only) |
| `⌘Z` / `⇧⌘Z` | Undo / Redo |
| `⌘U` | Auto Tone: temperature and tint from the photo's average colour, then exposure, contrast, highlights, shadows, whites and blacks from its histogram (or **Auto** in Basic); on the grid's selection, each photo its own values, one undo step for the lot; a large selection shows "Auto n of N" with Cancel, and `Esc` or Cancel stops it with nothing applied |
| `⇧⌘U` | Auto White Balance: temperature and tint only (or **Auto** beside White Balance in Color) |
| `⌥⌘U` | Auto in My Style (also in the menu on Basic's **Auto** button): Auto's values plus the learned correction for the photo's brightness bucket (dark, mid, bright), each kept inside its slider's range; on one photo, the grid's selection (one undo step, "Auto in my style n of N" with Cancel) or, with the Import sheet's **After import** set to Auto in my style, the photos just imported. Disabled until a style is learned ("Learn a style first (Photo > Learn Style from Selected Photos...)"); a second run sets the same values |
| — | My Edits… (View menu, no key): a read-only sheet over the open folder or album — your habits first (per slider, how many photos use it and the median value, most used first), then every edited photo (each virtual copy its own row) with its thumbnail and its enabled, non-neutral sliders by panel section and "n masks"; click a row to open that photo in the loupe. A switched-off slider is not shown or counted; nothing is written |
| — | Match Look… (Photo menu, no key; or drop an image file on the loupe's panel): pick one reference photo and the batch targets get its tone and colour (exposure, contrast, whites, blacks, temperature, tint, saturation, vibrance and the shadow and highlight grade) as ordinary slider values, each photo solved for its own, one undo step for the lot; the sheet shows the reference's thumbnail and lists the sliders moved. The reference is only read: never copied, imported or changed. An unreadable file changes nothing |
| — | Learn Style from Selected Photos… (Photo menu, no key): compares each selected photo's Basic and white-balance values with what Auto gives it, and keeps the median difference per brightness (dark, mid, bright) in `~/Library/Application Support/PhotoLab/style.json`, on this Mac only. **Replace** the learned style or **Add to Current Samples**; photos left at Auto or never edited there are skipped, and the bar says "Learned from n photos (m skipped)". Settings shows how many photos it holds and **Forget Style** |
| `⇧⌘R` | Reset Photo (back to the original) |
| `⌘'` | Create Virtual Copy: a second edit of the selected photo (grid or loupe), starting from its current one, listed right after it with a small number badge and captioned "<name> Copy 2"; **Photo › Remove Virtual Copy…** (also in a cell's right-click menu) deletes a copy's edit after a confirm and is not undoable. A copy is flagged, rated, synced, batch-edited and exported like any photo; its export is named `<name>-copy2.jpg` so it never lands on its master's; Save to Photos is off on a copy (Photos keeps one edit per photo) |
| `⇧⌘P` | Save Preset… (in the loupe) |
| `⇧⌘C` / `⇧⌘V` | Copy Settings / Paste Settings… |
| `⇧⌘I` | Import from Card… (a card's photos, or any folder's, copied into `~/Pictures/PhotoLab` by capture date) |
| `⇧⌘E` | Export… (the grid's selection, or the loupe's photo) |
| `⌘,` | Settings… (thumbnail size, preview quality, reopen at launch, sort, the learned style) |

Every key above except `Return` and `Esc` is also a menu item (`⌘,` is
PhotoLab › Settings…): File (open, Open Collection, Open Recent, Delete
Collection…, Import from Card…, Export…, Save to Photos), Edit (Undo / Redo, Undo Move to Trash, Undo Rename, the settings items, Select All
Photos, Search Photos), **View** (Grid, Loupe, Map, Zoom to 1:1, Before and After, Show Original, Clipping
Warning, Show Mask Overlay, Filmstrip, Info, My Edits…, Previous and Next Photo, below the toolbar items of the one View
menu macOS supplies) and **Photo** (Pick, Reject, Unflag, the
ratings, Crop, White Balance Picker, Auto Tone, Auto White Balance, Auto in My Style, Match Look…, Learn Style from Selected Photos…, Reset Photo, Create Virtual Copy, Remove Virtual Copy…, Keywords…, Rename…, Add
to Collection, Remove from Collection, New Linear Gradient, New Radial Gradient, Brush, Select Subject, Select Person, Select Faces, Select Sky (guess), Move Rejected Photos to Trash…). Select Subject, Select Person, Select Faces, Select Sky (guess), Match Look… and My Edits… have no key. A single-letter key (alone or with `⇧`) is written after its menu item's
name, as in "Pick (P)" or "New Radial Gradient (⇧M)", rather than bound to the menu, so typing that letter
into a text field (a preset's name, the export suffix or name template) types the letter.

**View › Show** also picks the grid's filter (All, Picks, Unflagged, Rejected, 1 to 5
stars), the same choice as the bar above the grid, and the empty-filter message has a
**Show All** button (it clears the search as well). The **Keywords** menu beside the
**Sort** menu lists the open folder's or album's keywords, each with how many photos
hold it; picking one searches for it. Under a filter or a search the window's subtitle
reads "n of N shown". **View › Sort By** (or the **Sort** menu at the right of the bar
above the grid) orders the grid by Capture Date, Name, Rating or Edited, Ascending or
Descending; the filmstrip and `←` `→` follow it, ties go by name, a photo with no
capture date goes last, and the choice is remembered once for folders and once for
Photos albums (a folder opens by name, an album oldest capture first until you pick
another). Sorting a Photos album by Name first reads every photo's name in the
background; the album keeps its order until the names are in, then sorts once. A file's capture date is its EXIF DateTimeOriginal, else the file's date. After an export, **Details…** lists every photo that failed or was
skipped. Render timings stay out of the panel and the tooltips unless you run
`defaults write <bundle id> showTimings -bool YES`.

**Settings** (`⌘,`, PhotoLab › Settings…) has four choices, each applied
at once and remembered: **Thumbnail size** (the grid cells' width, 120 to
300 points, 180 to start; the same slider sits at the right of the strip
under the grid, beside the photo count), **Preview quality** (Full renders
the fitted photo at every screen pixel; Balanced and Fast at ¾ and ½ of
them, drawn scaled up, so a slider responds sooner; 1:1 and exports are
always full resolution), **Reopen the last folder or album** at launch (on
to start; off, PhotoLab opens on the Welcome screen and Open Recent still
lists it), and the **Sort** a folder and a Photos album open in (the same
choice as View › Sort By, so changing either changes both; for the kind of
source that is open, the grid re-sorts at once). Thumbnails are decoded at
480 pixels, so the largest sizes upscale a little on a Retina screen.

The same actions are clickable: Pick, Reject, Unflag and five stars in the
loupe panel footer (the one photo) and in the batch bar (the selected
photos, which also has **Keywords…**), and a right-click menu on a grid photo (Pick, Reject, Unflag,
Rating, Keywords…, Apply Preset, Copy and Paste Settings, Export, Reset Photo, Create
and Remove Virtual Copy, and Show in Finder for a folder photo). A right-click on a photo outside the selection
acts on that photo alone, inside it on the whole selection. Open Photos
Library sits in the toolbar beside Open Folder (disabled outside the app
bundle).

`Return` and `Esc` also confirm and cancel the welcome screen's Open Folder… (with no
photo to open, `Return` is never the loupe key),
the Sync sheet and the Export sheet. Sync Settings… and the preset names in
the Presets menu have no key.

With the mouse, in the grid: click selects one photo, `⇧`-click selects
every photo between the anchor and it (the anchor kept), `⌘`-click adds or
removes one (the anchor moves to a photo added), double-click opens it in
the loupe. In the loupe: a filmstrip of the visible photos runs under the photo (click a cell to move there, `⇧`-click to extend the selection, `⌘`-click to toggle); click the photo to see it at 1:1 at that point, drag to pan, click again
for fit (`G` or `Esc` go back to the grid); double-click an adjustment's name to reset it, hold **Before** to see the
original, press `Y` to see the original and the edit side by side. A
camera RAW opens on the preview the camera embedded in it, with the edit
applied, and sharpens in place once the full decode lands.

**Info** (`⌘I`, View › Info, or the **Info** heading in the loupe panel)
lists what the photo says about itself: camera, lens, focal length,
aperture, shutter, ISO, pixel dimensions (as displayed), file name, size and
folder, capture date (the one the sort uses), GPS position as coordinates,
the photo's keywords, and whether it is edited. A field the photo does not have has no line. A
Photos album photo shows its name and date from Photos at once and the rest
once its original has been fetched, and has no folder line.

**Map** (`⌥⌘M`, View › Map, or the third segment of the toolbar's view
picker) shows the photos the grid shows (its filter applies) that carry a
GPS position, as pins on an Apple map: nearby photos share a pin showing
the first one's thumbnail and how many it holds, and zooming in splits
them. Click a pin to select its photos, double-click to open the first in
the loupe. A folder photo's position is read from its file the first time
the map opens ("Reading locations n of N" at the bottom, stopped by
leaving the map); a Photos album photo's comes with the album at once. The
footer says how many of the shown photos have a location. The map tiles
come from Apple over the network (no account or key); offline the pins
draw on a blank grid. The map is not remembered: a folder or album always
opens on the grid or the loupe.

**Collections** are saved sets of photos from any number of folders.
**Photo › Add to Collection** puts the selected photos of the open folder
into a collection you pick, or into a new one (**New Collection…** asks for
its name); **File › Open Collection**, the Welcome screen's **Collections**
list and Open Recent open one like a folder, and reopen at launch like the
last folder. An edit, flag, rating or keyword made in a collection is
written to the photo's own folder, so opening that folder shows it, and the
other way round. A photo whose file has moved or gone is left out of the
grid and counted in the window's subtitle ("2 missing"), never dropped from
the collection. **Photo › Remove from Collection** (while one is open) takes
the selected photos out of it, and **File › Delete Collection…** (after a
confirm; or right-click it on the Welcome screen) deletes the collection;
neither touches a photo or its edit. Photos album photos cannot be added
yet. Collections have no keys.

## Adjustments

The loupe's panel is in sections, each slider with a checkbox that switches
it off without losing its value; double-click a name to reset it, Reset for
the lot. `⌘Z` / `⇧⌘Z` undo and redo (a slider drag is one step), Reset or
`⇧⌘R` puts the photo back to the original. The footer prints the time of
the last frame.

**History**, under Info, lists the photo's steps newest on top with the
Original at the bottom, each named for what it changed ("Exposure +0.50",
"Crop", "Mask", "Exposure, Contrast +2 more", "Reset", and "Sync: …" for a step
taken on many photos at once). Click a row to go back (or forward) to it:
the same as pressing `⌘Z` / `⇧⌘Z` that many times, so a sync step takes
every photo of the sync with it. Undone steps stay greyed above the current
row until the next edit drops them. The history is kept while the folder or
album is open (the last 100 steps per photo) and is not saved.

**Masks**, under the Presets strip, are local adjustments: **Linear** (or
`M`) and **Radial** (`⇧M`) arm a new gradient, then a drag on the photo
places it: a linear from where the effect is full to where it ends, a
radial circle from its centre out to its edge (a click instead places a
gradient 40% of the photo tall, or a 0.2 × 0.15 ellipse, centred there).
**Brush** (`K`) adds an empty brush mask, armed: drag on the photo to
paint into it (a circle shows the brush's size and, dashed, where its soft
edge starts), hold `⌥` as a drag starts to erase instead, and set the next
strokes' **Size**, **Feather** and **Flow** in its rows (`[` and `]` for
the size). Picking a brush mask in the list arms it again. With an
automatic mask selected, `K` arms the brush on it instead: paint adds to
what was detected, `⌥` erases from it. Each stroke is
one undo step. **Subject** (Photo › Select Subject) finds the photo's
subject with Apple Vision, on this Mac with no network, and adds it as a
new automatic mask ("Subject 1"), selected, in one undo step; a photo with
nothing to find says "No subject found" and changes nothing. **Person**
(Photo › Select Person) does the same for every person in the photo, as
one mask ("Person 1"), or says "No person found". **Faces** (Photo › Select
Faces) adds one radial mask per face it finds, a feathered ellipse a little
larger than the face and turned with it, all in one undo step with the
first selected, or says "No faces found"; each is an ordinary radial with
handles. **Sky** (Photo › Select Sky (guess)) is a guess, not a model: it
masks the blue or overcast-white area above the horizon that reaches the
top edge, fading toward the horizon (Vision's horizon tilt when it finds
one, else level 70% down), as one mask ("Sky 1"), or says "No sky found";
refine it with the brush. They are off while a detection runs, and switching photos
meanwhile drops the result. The selected linear or radial has handles on the
photo, at fit and at 1:1: a linear's centre pin moves it and the handles
on its start and end lines turn it and set the fade's length about the
pin; a radial's centre pin moves it, its four edge handles set its width
and height, the knob above it turns it and the small diamond on the inner
(dashed) ellipse sets the feather. Each drag is one undo step. The
handles are hidden in compare, in crop mode and while Before shows. Each is listed by kind and order ("Linear 1",
"Radial 1", "Linear 2"); click one to show its own exposure, temperature,
tint, contrast, highlights, shadows and saturation sliders, a checkbox to
switch it off, **Invert** (apply where the mask is not), **Duplicate**
and **Delete**. Every add, delete, switch and slider drag is one undo step.
**Show Overlay** (or `O`) tints the selected mask red on the photo.

- **Basic** — exposure (EV), contrast, highlights, shadows, whites, blacks.
  **Auto** (or `⌘U`, Photo › Auto Tone) sets temperature and tint from the
  photo's near-neutral average colour, then all six from the histogram
  measured with those six at zero, so pressing it again changes
  nothing (an unreadable frame, all black or all clipped, keeps its white
  balance); it is one undo step and keeps every other edit. A dark photo is
  brightened, a blown sky pulled in by highlights and whites rather than by
  darkening the whole frame. A RAW is read from its decoded master, never
  from the camera preview the loupe shows first.
- **Color** — temperature, tint, vibrance, saturation. **White Balance**
  (or `W`) arms an eyedropper: the next click on the photo sets
  temperature and tint so the 5×5 pixels under it render grey, measured
  before any of the colour and tone sliders, so the sliders' old values
  do not matter. One undo step; a clipped or near-black spot is refused.
- **Tone Curve** — five points (blacks, shadows, midtones, highlights,
  whites), each moved up or down.
- **HSL** — hue, saturation and luminance for eight bands (red, orange,
  yellow, green, aqua, blue, purple, magenta); pick the channel, then the
  band sliders. Grays are never touched.
- **Color Grading** — split toning by brightness: a hue (0–360°), a
  saturation (0–100) and a luminance (−100…+100) each for shadows, midtones
  and highlights, plus **Balance**, which moves the line between shadows and
  highlights (positive gives the highlights more of the picture). A tint
  colours a grey and keeps its brightness; a hue with saturation 0 does
  nothing. Applied after HSL and before local adjustments (masks). Three
  wheels, Shadows, Midtones and Highlights, set a range's hue and
  saturation together: drag the puck (or anywhere on the disc), and the
  angle is the hue (red at the right, running counter-clockwise through
  yellow, green and blue) and the distance from the centre the saturation;
  the drag is one undo step, and a double-click on a wheel resets that
  range's hue and saturation. The luminance and Balance sliders sit under
  the wheels; **Hue & Saturation** opens the six exact sliders.
- **Detail** — noise reduction (luminance) and color noise, clarity (local
  contrast), sharpening, grain. Judge noise reduction zoomed in at 1:1.
  While you drag another control the preview leaves noise reduction out
  (to stay smooth) and puts it back when you let go; exports always have it.
- **Effects** — vignette (negative darkens the corners).
- **Lens Corrections** — manual sliders, no lens-profile database.
  **Distortion** (−100…+100): positive straightens barrel distortion (lines
  bowed outward), negative straightens pincushion; the frame is zoomed just
  enough that no empty edge shows, and keeps its size. **Vignetting**
  (−100…+100): positive brightens the corners to undo a lens's falloff (one
  stop at +100), negative darkens them; the centre is untouched. Both act
  on the whole frame the lens made, before Crop & Rotate, so the crop
  overlay shows the corrected frame; the Effects vignette is separate and
  follows the crop.
- **Crop & Rotate** — rotate (degrees, positive is clockwise; the frame is
  cropped to the largest same-shape rectangle, so no empty corners) and a
  crop from each edge in percent of the frame (up to 40% each, so at least
  a fifth of the frame is kept). **Crop on Photo** (or `R`) shows the whole
  rotated frame with the crop drawn over it: drag any edge or corner, the
  four values follow live, and one drag is one undo step. The crop is cut
  from the rotated frame, so the handles move square to the photo as you
  see it. **Aspect** locks the corners to a ratio (Original, Free, 1:1,
  4:5, 3:2, 16:9; the swap button turns it between portrait and
  landscape): picking one refits the crop at once (the largest of that
  shape around the crop's centre, one undo step), a corner drag then
  keeps the shape, and the edge handles are hidden until Free.
  **Straighten** (crop mode) takes the next drag on the photo as a line:
  draw it along a horizon and rotate is set so the line is level, or
  along something within 45° of upright and it is made upright; one undo
  step, and `Esc` puts the tool down. The aspect is a tool setting, not
  part of the edit: it stays while you move between photos and is
  forgotten when the app quits.

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

A preset is a named look: every slider except rotate and crop (and never
local adjustments, which stay with their photo). The loupe's
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

**Importing from Lightroom.** Presets › Import Lightroom Preset… (also in the
strip's `…` menu; no key) opens a panel for `.xmp` files, several at once. Each
file gets a sheet: the name (the file's own preset name, editable; if it is
taken the sheet asks Replace or Keep Both, which saves as "name 2"), the
sliders it moves with their values, the settings carried approximately or
clamped, and a "No equivalent in PhotoLab" list of what does not carry over
(Dehaze, Texture, masks, profiles and so on). Save writes one preset to the
presets folder; Cancel writes nothing. PhotoLab only reads the file you pick.

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
  value; a checked one takes the anchor's, zero included. **Masks** (checked
  by All only) replaces each photo's masks with the anchor's. An automatic
  mask (Select Subject / Person) is found again on each photo, with its
  adjustments kept and its brush refinement dropped (it was painted on the
  anchor's pixels); a photo where nothing is found gets no such mask and the
  bar at the bottom counts the skips. The whole sync is one undo step once
  detection finishes (Esc or Cancel in the bar stops it, applying nothing);
  a virtual copy of the anchor keeps the anchor's bitmap.
- **Apply Preset** applies a preset to every selected photo (its look over
  each photo's own crop and rotation). The Presets menu does the same for
  the selection.
- **Export…** renders every selected photo into a folder (`⇧⌘E` from
  anywhere exports the selection, or the loupe's photo). A sheet asks, and
  remembers for next time: the format (**JPEG**, **HEIC**, or lossless
  LZW **TIFF**), the JPEG/HEIC quality, the size (as edited, an exact long
  side in pixels, or a percentage; never upscaled), the file name (the
  original's name plus a suffix, `DSC06727` + `-edit` → `DSC06727-edit.jpg`,
  a virtual copy's with `-copy2` after it, `DSC06727-edit-copy2.jpg`,
  or a **Template** of literal text and the tokens `{name}` (the original's
  name), `{date}` (its capture date, `2026-03-14`; `undated` without one)
  and `{seq}` (its place in the batch from a settable start number,
  zero-padded to the batch's widest number: `01`…`10` for ten photos), with
  `/`, `:` and `\` removed and the original's name used when nothing is
  left; the sheet previews the first two names), what to do when the file
  exists (**Add a number** `<photo> 2.jpg`, **Skip**, or **Overwrite**;
  the original is never overwritten, even when exporting into its own
  folder, and neither is any other photo of the open library: an Overwrite
  that would land on one fails for that photo and the bar says why), whether the camera info travels (EXIF, GPS and IPTC are copied
  from the original with the orientation reset, since the render is
  already upright), an optional text **Watermark** (white with a soft
  shadow, at a corner or the centre, its size the text height as a share
  of the exported photo's short side, so it reads the same at every export
  size, and its opacity; blank text adds none; never on the loupe or a
  Save to Photos), and where it goes: a **Folder**, or the **Photos
  library**. For Photos each photo is rendered with the same options and
  added as a new photo, into an album (default **PhotoLab**, created the
  first time; clear the field for the library only); there is no collision
  choice, since every export is a new photo, and a photo opened from Photos
  comes back as a new photo beside its original, which is not changed.
  Photos needs the app bundle (`scripts/bundle.sh`) and your permission:
  the sheet's **Allow Access to Photos…** is the only place it is asked. A bar at the
  bottom of the window shows the count done, the file in flight and Cancel,
  which stops after that file; what is written stays, a skipped file is
  counted. The sheet's **Preset** menu keeps named sets of those options:
  picking one fills every field, the watermark included (but never the
  destination, which stays the sheet's own choice); **Save Current as
  Preset…** names the current fields (an existing name asks before it is
  replaced); **Delete Preset** removes the picked one. The last pick is
  remembered, and once a field changes the menu reads "<name> (edited)".
  One preset is built in: **For Google Photos / web** (JPEG, 2048 px on the
  long side, quality 85, sRGB, Standard output sharpening, `-web` suffix,
  camera info and dates kept, location removed). **Color space** (Same as
  original, sRGB, Display P3) and **Output sharpening** (Off, Low, Standard,
  High; applied after the resize) sit under Format. **Remove location (GPS)**, under Keep camera info, drops where
  a photo was taken from any export.

Copy Settings (`⇧⌘C`) remembers one photo's settings; Paste Settings…
(`⇧⌘V`) opens the same sheet onto whatever is selected, so a look can be
carried between folders. Every batch write goes through the same path as a
slider move: one sidecar per photo, written at once, and the whole batch is
**one undo step**: `⌘Z` on any photo of the batch takes them all back
(a photo you edited again since keeps its later edit; undo that first).

## Import

**File › Import from Card…** (`⇧⌘I`) lists the mounted cards: every
removable or ejectable volume (an SD card in a reader, a camera that mounts
as a disk) with a `DCIM` folder, with Refresh to list them again; **Choose
Folder…** imports any other folder instead. Before anything is copied the
sheet says how many photos are new, how many are already imported and how
many other files (videos, sidecars) are skipped. Every photo goes to
`<root>/YYYY/YYYY-MM-DD/<name>` by its capture date (the EXIF date the
photo was taken, else the file's creation date, else its modification
date), the root `~/Pictures/PhotoLab` unless you change it in the sheet
(remembered). A RAW+JPEG pair copies both. A file of the same name and size
already there is already imported and skipped; same name, another size is
copied as `<name> 2.<ext>`. Nothing is ever overwritten, and the card is
only read: nothing on it is moved, renamed or deleted. Cancel stops after
the file being copied. When it ends, **Eject** ejects the card (never
automatically) and **Open** opens the imported photos' folder (their day,
else their year, else the root). The sheet's **After import** picker (None,
Auto, Auto in my style, or a preset; remembered) makes the button **Open and Auto**, **Open and Auto in My Style** or **Open
and Apply <preset>**: after opening, Auto, Auto in my style (nothing while no style is learned) or the preset is applied to the
photos this import copied (never to ones skipped as already imported) as one
undo step; **Done** applies nothing. A preset you have deleted counts as None.

The first time PhotoLab reads a card macOS asks once whether it may access
files on a removable volume (and may ask again after a rebuild of an ad-hoc
signed bundle). If that was refused, the sheet shows the card as unreadable
with **Open System Settings** (Privacy & Security › Files and Folders).

## On disk

Everything the app writes, and nothing else:

- **Sidecars** — `<folder>/.photolab/<file>.json`, one per edited, flagged,
  rated or keyworded photo, next to the photos. Removed when the photo is reset to the
  original and carries no flag, rating or keyword. A virtual copy's is
  `<file>@copy<n>.json` beside its master's, kept while the copy exists. A photo without keywords
  has no `keywords` key, so its file is exactly as before. A sidecar this version cannot
  read is kept beside the new one as `<file>.json.unreadable-<stamp>`,
  never deleted. An edit with local adjustments is saved as format 2,
  which an older PhotoLab (another Mac not yet updated) treats as
  unreadable rather than opening it without them; an edit without any is
  saved as format 1, exactly as before. An edit with an automatic mask
  (Subject, Person or Sky) is saved as format 3, its mask a small grey PNG
  inside the file; formats 1 and 2 are written exactly as before.
- **Collections** — `~/Library/Application Support/PhotoLab/Collections/<id>.json`,
  one per collection: its name, when it was made, and each member's file
  path and the folder whose `.photolab/` holds its edit. Nothing is written
  there until you make one; deleting a collection deletes only its file.
- **Presets** — `~/Library/Application Support/PhotoLab/presets/<name>.json`,
  one per preset; the six starter looks are written there when that folder
  does not exist yet.
- **Export presets** — `~/Library/Application Support/PhotoLab/export-presets/<name>.json`,
  one per export preset (every export option, the watermark included, never
  the destination); nothing is written there until you save one. A file
  this version cannot read is listed in the Preset menu as unreadable and
  kept as `<name>.json.unreadable-<stamp>` before a preset of that name is
  saved, never deleted.
- **Learned style** — `~/Library/Application Support/PhotoLab/style.json`,
  written by Learn Style from Selected Photos… (the photos it learned from,
  each one's Auto values and yours, and the corrections); nothing is written
  until you learn one, and Forget Style deletes it. A file this version
  cannot read is kept as `style.json.unreadable-<stamp>` before a new style
  is saved, never overwritten.
- **Photos sidecars** — `~/Library/Application Support/PhotoLab/photos-sidecars/<asset-id>.json`,
  one per edited, flagged, rated or keyworded photo of a Photos album (the asset's
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
- **Preferences** — in the app's UserDefaults: the Settings window's
  thumbnail size, preview quality and reopen-at-launch choice, the last
  opened source (a folder's path, a Photos album's identifier, or a
  collection's id) and Open Recent's list, the sort (once for folders and
  collections, once for Photos albums),
  whether the filmstrip and the Info and History sections are shown, the
  last export folder, target (Folder or Photos) and Photos album, and the
  last export options (format, quality, size, suffix or name template, collision policy,
  metadata, watermark) and the last picked export preset's name, so the
  next export sheet opens with them, and the import root once changed.
- **Imports** — the photos you import, under the import root
  (`~/Pictures/PhotoLab` unless changed) in `YYYY/YYYY-MM-DD/` folders,
  each copied through a hidden `.<name>.partial` file and moved into place
  when complete. The card is never written.
- **Exports** — the files you ask for, in the folder you choose, written
  through a hidden partial file and moved into place when complete. An
  export to Photos renders each file into `$TMPDIR/PhotoLab-export/<run>/`,
  hands it to Photos and removes it; the run's folder goes when it ends.
- **The release bundle** — `build/PhotoLab.app`, made by `scripts/bundle.sh`
  (signed with `PHOTOLAB_SIGN_IDENTITY`, default ad hoc; `swift build` puts
  debug builds under `.build/`).

The original photo is never written to, under any of these. Two commands
move one: **Photo › Move Rejected Photos to Trash…** (`⌘⌫`) moves the
rejected files themselves to the macOS Trash (`~/.Trash`), and leaves
their sidecars in `.photolab/`; **Photo › Rename…** renames the files in
their folder and moves each sidecar (and each virtual copy's
`<name>@copy<n>.json`) to the new name in the same `.photolab/`, its
`original` field rewritten. Neither writes a byte of the file.

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
