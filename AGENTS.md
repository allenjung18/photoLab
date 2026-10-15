# PhotoLab — notes for agents

- SwiftPM package, no Xcode project. Build with `swift build`, run with
  `swift run PhotoLab [folder]`, release bundle with `scripts/bundle.sh`.
  Swift 5 language mode (tools 5.9); macOS 14 minimum.
- Never write to a photo's original file. Edits live in sidecar JSON;
  exports go to a separate output folder.
- One render path: Core Image for preview and export alike. Do not add a
  second renderer.
- Keep ImageIO for thumbnails (fast, orientation-aware, reads RAW and HEIC).
- Keyboard shortcuts are global hidden buttons in `ContentView.swift`
  (`HiddenShortcuts`); add new ones there.
- No AI attribution lines in commit messages.
