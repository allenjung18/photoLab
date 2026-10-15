# PhotoLab

A Lightroom-style photo editor for the Mac: non-destructive adjustments you
can toggle one by one, named presets, and batch apply to many photos at once.
Native Swift, SwiftUI and Core Image. Originals are never written to.

## Run

    swift run PhotoLab            # debug build, last folder (or ⌘O)
    swift run PhotoLab ~/Pictures # open a folder directly
    scripts/bundle.sh --open      # release build as build/PhotoLab.app

Needs macOS 14+ and Xcode (free). On macOS 27 the bare Command Line Tools
cannot build SwiftUI (the SDK needs a macro plugin only Xcode ships), so
select Xcode once: `sudo xcodebuild -license accept` then
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. Opening
`Package.swift` in Xcode works too. No developer account is needed to build
or run locally.

## Keys

`⌘O` open folder · `G` grid · `E` or `Return` loupe · `Esc` back ·
`←` `→` previous / next photo · double-click a thumbnail to open it.

## Design

- **Edits are data.** Each photo gets a sidecar JSON: an ordered list of
  adjustments, each with parameters and an enabled flag. Toggles, undo,
  presets and batch apply are all edits to that list. (Chunk 3.)
- **One render path.** A Core Image filter chain renders the recipe for both
  the preview and the export, so they cannot drift in color. (Chunk 2.)
- **A preset is a named recipe.** Applying it to a selection writes into the
  sidecars, with per-adjustment checkboxes. (Chunks 5 and 6.)
