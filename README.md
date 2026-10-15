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

`⌘O` open folder · `G` grid · `E` or `Return` loupe · `Esc` back ·
`←` `→` previous / next photo · double-click a thumbnail to open it ·
`\` before / after (or hold the Before button).

## Adjustments

The loupe has a panel of six sliders: exposure (EV), contrast, temperature,
tint, vibrance, saturation. Each has a checkbox that switches it off without
losing its value; double-click a name to reset it, Reset All for the lot.
The footer prints the Core Image time of the last frame. Edits are kept per
photo for the session (sidecars come in chunk 3).

## Design

- **Edits are data.** Each photo gets a sidecar JSON: an ordered list of
  adjustments, each with parameters and an enabled flag. Toggles, undo,
  presets and batch apply are all edits to that list. (Chunk 3.)
- **One render path.** `Renderer.apply` is the Core Image filter chain for a
  recipe; the loupe feeds it a 3200 px ImageIO master, the export will feed
  it the full-resolution decode, so the two cannot drift in color. A slider
  step re-renders at the view's pixel size (about 4 ms for a 24 MP JPEG,
  9 ms for a RAW, on an M4). (Chunk 2.)
- **A preset is a named recipe.** Applying it to a selection writes into the
  sidecars, with per-adjustment checkboxes. (Chunks 5 and 6.)
