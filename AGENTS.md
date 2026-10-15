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
  new adjustment is a new `AdjustmentKind` case plus one `stage` branch plus
  a direction test in `Tests/PhotoLabTests/RendererTests.swift`.
- `swift test` runs the recipe/chain tests and a timed render; set
  `PHOTOLAB_BENCH_IMAGE=<file>` to time a real photo through the loupe path.
- Keep ImageIO for thumbnails (fast, orientation-aware, reads RAW and HEIC).
- Keyboard shortcuts are global hidden buttons in `ContentView.swift`
  (`HiddenShortcuts`); add new ones there.
- No AI attribution lines in commit messages.
