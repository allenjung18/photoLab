import AppKit
import CoreImage
import ImageIO

/// `PHOTOLAB_LIVE_TOUR=<dir>`: the real app drives itself through a scripted
/// hand test and quits (`scripts/live-tour.sh` stages the photos and reads
/// the report). Keys go in as `NSEvent`s through `NSApp.sendEvent`, so the
/// menus' key equivalents, the hidden bare-key shortcuts and the focused
/// text field see them as typed; menu items are chosen in the real menu bar;
/// sheet controls are the AppKit controls SwiftUI drew. Each step writes a
/// screenshot of the window (and of a sheet over it) and a verdict:
/// PASS / FAIL for what the tour can check itself, LOOK for a layout only an
/// eye can judge from the screenshot, SKIP for what needs the user (a
/// Photos grant, an SD card).
///
/// Nothing outside `<dir>` is touched: the stores' directories come from
/// `AppDirectories` (inside `<dir>/state`), the settings are a UserDefaults
/// suite of their own, cleared at start and end, and the Trash is
/// `<dir>/trash`. `<dir>/photos` is the folder the tour opens (the script
/// copies the photos there; never point it at real originals).
@MainActor
final class LiveTour {
    nonisolated static let directory: URL? = ProcessInfo.processInfo.environment["PHOTOLAB_LIVE_TOUR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    nonisolated static var stateDirectory: URL? { directory?.appendingPathComponent("state", isDirectory: true) }
    static var isActive: Bool { directory != nil }
    static let defaultsSuite = "local.photolab.livetour"

    /// The tour's settings: its own suite, emptied first, the export folder
    /// set to `<dir>/exports` so the sheet opens on it.
    static func makeSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        let settings = AppSettings(defaults: defaults, persistent: true)
        if let directory {
            let exports = directory.appendingPathComponent("exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            settings.exportFolder = exports.path
        }
        settings.showInfo = false
        return settings
    }

    /// Moves into `<dir>/trash/<uuid>/`, never the macOS Trash.
    struct Trasher: FileTrasher {
        let directory: URL
        func trash(_ url: URL) throws -> URL {
            let into = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
            let landed = into.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: landed)
            return landed
        }
    }

    static var trasher: Trasher? {
        directory.map { Trasher(directory: $0.appendingPathComponent("trash", isDirectory: true)) }
    }

    enum Verdict: String { case pass = "PASS", fail = "FAIL", look = "LOOK", skip = "SKIP" }

    struct Step {
        let id: String
        let title: String
        var verdict: Verdict
        var notes: [String]
        var shots: [String]
    }

    private static var running: LiveTour?

    /// Starts the tour once the window is up; the app quits when it ends.
    static func start(library: Library, presets: PresetLibrary, exports: ExportQueue) {
        guard let directory, running == nil else { return }
        let tour = LiveTour(directory: directory, library: library, presets: presets, exports: exports)
        running = tour
        Task { await tour.run() }
    }

    let dir: URL
    let photosDir: URL
    let shotsDir: URL
    let library: Library
    let presets: PresetLibrary
    let exports: ExportQueue
    private var steps: [Step] = []
    private var current: Step?
    private var window: NSWindow!

    private init(directory: URL, library: Library, presets: PresetLibrary, exports: ExportQueue) {
        dir = directory
        photosDir = directory.appendingPathComponent("photos", isDirectory: true)
        shotsDir = directory.appendingPathComponent("shots", isDirectory: true)
        self.library = library
        self.presets = presets
        self.exports = exports
    }

    // MARK: The tour

    private func run() async {
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        guard await waitFor(10, { NSApp.windows.contains { $0.isVisible && $0.contentView != nil } }) else {
            return finish("no window appeared")
        }
        window = NSApp.windows.first { $0.isVisible && $0.attachedSheet == nil && !$0.isSheet }
        window.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 920), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        library.open(photosDir)
        keyMap()
        let tour: [(String, () async -> Void)] = [
            ("01", launch), ("02", pairs), ("03", pairInfo), ("04", noiseReduction), ("05", noiseDraft),
            ("06", exportSheetLayout), ("07", exportColorAndSharpening), ("08", trashPair),
            ("09", renamePairWithBothBanners), ("10", collections), ("11", searchKeys),
        ]
        // PHOTOLAB_LIVE_TOUR_STEPS=03,08 runs those steps alone (01 always runs: it waits for the folder).
        let only = ProcessInfo.processInfo.environment["PHOTOLAB_LIVE_TOUR_STEPS"].map { Set($0.split(separator: ",").map(String.init)) }
        for (id, step) in tour where id == "01" || only?.contains(id) ?? true {
            await step()
            await closeStraySheet(after: id)
        }
        if only == nil { skipped() }
        finish(nil)
    }

    /// Every menu item with a key, as the menu bar holds it: what a typed
    /// key can reach.
    private func keyMap() {
        begin("00", "Key map: the menu bar's key equivalents")
        var lines: [String] = []
        func walk(_ menu: NSMenu, _ path: String) {
            menu.update()
            for item in menu.items {
                if let sub = item.submenu { walk(sub, path + item.title + " › ") }
                guard !item.keyEquivalent.isEmpty else { continue }
                let m = item.keyEquivalentModifierMask
                let mods = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "")
                    + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
                let key = item.keyEquivalent.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? String(format: "\\u{%X}", $0.value) : String($0) }.joined()
                lines.append("\(mods)\(key)  \(path)\(item.title)")
            }
        }
        if let main = NSApp.mainMenu { walk(main, "") }
        for l in lines.sorted() { note(l) }
        end(.pass, "\(lines.count) items with a key")
    }

    /// A sheet a step left open would take every later key: close it and say so.
    private func closeStraySheet(after id: String) async {
        guard let sheet = window.attachedSheet else { return }
        let title = textTitles(sheet).first ?? "untitled"
        print("LIVE-TOUR   (step \(id) left a sheet open: \(title); closing it)")
        if let i = steps.lastIndex(where: { $0.id == id }) { steps[i].notes.append("left a sheet open (\(title)); the tour closed it") }
        await press("\u{1B}", 53)
        if window.attachedSheet != nil { window.endSheet(sheet) }
        _ = await waitFor(2) { self.window.attachedSheet == nil }
    }

    private func textTitles(_ window: NSWindow) -> [String] {
        views(NSTextField.self, in: window.contentView).filter { !$0.isEditable }.map(\.stringValue).filter { !$0.isEmpty }
    }

    private func launch() async {
        begin("01", "Launch: the folder opens in the grid and the search field does not take the focus on its own")
        guard await waitFor(15, { self.library.photos.count >= 4 }) else { return end(.fail, "the folder did not open: \(library.openError ?? "no photos")") }
        await settle(1.5)
        let responder = window.firstResponder
        let typing = responder is NSTextView
        note("photos in the grid: \(library.photos.count); files in the folder: \(files(photosDir).count)")
        note("first responder: \(responder.map { String(describing: type(of: $0)) } ?? "nil"); textEntryActive \(library.textEntryActive)")
        shot("01-launch-grid")
        end(!typing && !library.textEntryActive ? .pass : .fail,
            typing ? "a text field has the focus at launch: bare keys are dead" : "no text field has the focus")
    }

    private func pairs() async {
        begin("02", "RAW+JPEG pairs: each pair is one grid cell with the pair badge")
        let paired = library.photos.filter { $0.companion != nil }
        let names = paired.map { "\($0.fileURL!.lastPathComponent) + \($0.companion!.lastPathComponent)" }
        note("paired: \(names.joined(separator: ", "))")
        let jpegCells = library.photos.filter { p in paired.contains { $0.companion == p.fileURL } }
        shot("02-pairs-grid")
        if paired.count >= 2, jpegCells.isEmpty {
            end(.look, "\(paired.count) pairs, no companion has a cell of its own; check the badge on them in the shot")
        } else {
            end(.fail, "expected 2 pairs with no companion cell; got \(paired.count) pairs, \(jpegCells.count) companion cells")
        }
    }

    private func pairInfo() async {
        begin("03", "Info panel on a pair (⌘I): Paired With names the JPEG")
        guard let pair = library.photos.first(where: { $0.companion != nil }) else { return end(.fail, "no pair") }
        library.click(pair.id)
        await press("i", 34, .command)
        await settle(1.5)
        shot("03-pair-info")
        end(library.loupe && library.showInfo ? .look : .fail,
            "loupe \(library.loupe), info \(library.showInfo); read Paired With in the shot (\(pair.companion!.lastPathComponent))")
        await press("i", 34, .command)
    }

    private var rawID: Photo.ID? { photo(named: "DSC06727.ARW")?.id }

    private func noiseReduction() async {
        begin("04", "Noise reduction on the ARW at 1:1 (Z), before and after, plus a noise measure on the one render path")
        guard let id = rawID, let url = photo(named: "DSC06727.ARW")?.fileURL else { return end(.fail, "DSC06727.ARW is not in the folder") }
        library.click(id)
        if !library.loupe { await press("e", 14) }
        await press("z", 6)
        guard case .actual = library.loupeZoom else { return end(.fail, "Z did not zoom to 1:1 (loupe \(library.loupe))") }
        await settle(3)
        shot("04a-nr-off-1to1")
        var recipe = library.recipe(for: id)
        recipe.set(.luminanceNoise, to: 60)
        recipe.set(.colorNoise, to: 50)
        library.setRecipe(recipe, for: id)
        await settle(3)
        shot("04b-nr-60-50-1to1")
        let iso = isoSpeed(url)
        let measured = await Task.detached { Self.noiseMeasure(url, luminance: 60, color: 50) }.value
        guard let m = measured else { return end(.fail, "the measure could not render \(url.lastPathComponent)") }
        note("ISO \(iso.map(String.init) ?? "?"); high-pass sigma of the centre 800 px at 1:1: off \(fmt(m.off)), on \(fmt(m.on)) (\(fmt(100 * (1 - m.on / m.off)))% less); colour sigma off \(fmt(m.chromaOff)), on \(fmt(m.chromaOn))")
        let less = m.on < m.off * 0.9 && m.chromaOn < m.chromaOff
        end(less ? .look : .fail, less
            ? "the noise measure drops; judge whether it is enough from 04a vs 04b (the theory is about ISO 6400, this file is ISO \(iso.map(String.init) ?? "?"))"
            : "the measure did not drop by 10%")
    }

    private func noiseDraft() async {
        begin("05", "A drag's preview leaves noise reduction out while another slider moves, and has it back at mouse-up")
        guard let id = rawID else { return end(.fail, "no ARW") }
        library.beginEdit(id)
        var r = library.recipe(for: id)
        r.set(.exposure, to: 0.4)
        library.setRecipe(r, for: id)
        let mid = library.previewRecipe(for: id)
        await settle(1)
        shot("05a-mid-drag-draft")
        library.endEdit(id)
        await settle(2)
        let after = library.previewRecipe(for: id)
        note("mid-drag preview NR \(fmt(mid.value(of: .luminanceNoise)))/\(fmt(mid.value(of: .colorNoise))); after \(fmt(after.value(of: .luminanceNoise)))/\(fmt(after.value(of: .colorNoise)))")
        let ok = mid.value(of: .luminanceNoise) == 0 && after.value(of: .luminanceNoise) == 60
        end(ok ? .pass : .fail, ok ? "drafted out mid-drag, back after" : "the draft did not swap noise reduction as written")
        library.undo()
        await press("z", 6)
        await press("g", 5)
    }

    private func exportSheetLayout() async {
        begin("06", "Export sheet (⇧⌘E): the File section with Name set to Template, at 520 pt")
        guard let id = rawID else { return end(.fail, "no ARW") }
        library.click(id)
        guard await openExportSheet(), let sheet = window.attachedSheet else { return end(.fail, "⇧⌘E opened no sheet") }
        controlsNote(sheet)
        guard let name = popUp(in: sheet, showing: "Original name + suffix") else { return end(.look, "found no Name pop-up to set; the shot is the sheet as it opened") }
        let before = name.titleOfSelectedItem ?? "Original name + suffix"
        note("Name pop-up lists: \(choose(name, "Template").joined(separator: " | "))")
        await settle(1)
        let templateField = textFields(in: sheet).contains { $0.placeholderString == "e.g. {date}-{seq}" }
        note("sheet \(Int(sheet.frame.width))×\(Int(sheet.frame.height)) pt; template field shown: \(templateField)")
        shot("06-export-sheet-template")
        if let n = popUp(in: sheet, showing: "Template") { choose(n, before) }
        await press("\u{1B}", 53)
        _ = await waitFor(3) { self.window.attachedSheet == nil }
        end(templateField ? .look : .fail, templateField
            ? "check in the shot that the File section's rows do not clip or overlap"
            : "choosing Template showed no template field")
    }

    private func exportColorAndSharpening() async {
        begin("07", "Export Color space and Output sharpening: three exports through the sheet, read back")
        guard let id = rawID else { return end(.fail, "no ARW") }
        library.click(id)
        var outputs: [(String, URL)] = []
        for (label, space, sharpen) in [("sRGB, none", "sRGB", "None"), ("sRGB, Standard", "sRGB", "Standard"), ("Display P3, none", "Display P3", "None"), ("Same as original, none", "Same as original", "None")] {
            guard await openExportSheet(), let sheet = window.attachedSheet else { return end(.fail, "⇧⌘E opened no sheet") }
            var picked: [String] = []
            let spaces = ["Same as original", "sRGB", "Display P3"], sharpenings = ["Off", "Low", "Standard", "High"]
            if let p = views(NSPopUpButton.self, in: sheet.contentView).first(where: { spaces.contains($0.title) }) {
                choose(p, space)
                picked.append(p.title)
            }
            if let p = views(NSPopUpButton.self, in: sheet.contentView).first(where: { sharpenings.contains($0.title) }) {
                choose(p, sharpen == "None" ? "Off" : sharpen)
                picked.append(p.title)
            }
            await settle(0.5)
            if outputs.isEmpty { shot("07-export-sheet-picked") }
            let previous = exports.exported
            await press("\r", 36)
            _ = await waitFor(5) { self.exports.state == .running || self.exports.exported != previous }
            guard await waitFor(60, { self.exports.state == .finished && self.window.attachedSheet == nil }),
                  let url = exports.exported.last else {
                return end(.fail, "the \(label) export did not finish: \(exports.detailLines.joined(separator: "; "))")
            }
            note("\(label): sheet showed \(picked.joined(separator: " / ")) -> \(url.lastPathComponent)")
            outputs.append((label, url))
        }
        var ok = true
        var sigmas: [Double] = []
        for (label, url) in outputs {
            let info = Self.colorInfo(url)
            note("\(label): profile \(info.profile ?? "none"), EXIF ColorSpace \(info.exifSpace.map(String.init) ?? "none")")
            // Same as original: whatever profile the source carries, the EXIF tag must agree with it.
            let wantP3 = label.hasPrefix("Same as original") ? info.profile?.contains("P3") == true : label.hasPrefix("Display P3")
            let profileOK = info.profile.map { wantP3 ? $0.contains("P3") : $0.contains("sRGB") } ?? false
            let exifOK = wantP3 ? info.exifSpace != 1 : info.exifSpace == 1
            if !profileOK || !exifOK { ok = false; note("  ✗ \(label): expected \(wantP3 ? "a P3 profile and EXIF ColorSpace 65535 (uncalibrated)" : "an sRGB profile and EXIF ColorSpace 1")") }
            sigmas.append(Self.highPassSigma(url) ?? 0)
        }
        note("high-pass sigma of the whole export: \(sigmas.map(fmt).joined(separator: " / "))")
        if sigmas.count >= 3, !(sigmas[1] > sigmas[0] * 1.03) { ok = false; note("  ✗ Standard sharpening did not raise the high-pass sigma by 3%") }
        await press("g", 5)
        end(ok ? .pass : .fail, ok ? "each file is written in the space picked, and sharpening shows" : "see the ✗ lines")
    }

    private func trashPair() async {
        begin("08", "Trash a pair: X rejects, ⌘⌫ from the grid reaches Move Rejected Photos to Trash…, both files go; the banner sits above the filter bar")
        guard let pair = library.photos.first(where: { $0.companion != nil }), let raw = pair.fileURL, let jpeg = pair.companion else {
            return end(.fail, "no pair")
        }
        if library.loupe { await press("g", 5) }
        library.click(pair.id)
        await press("x", 7)
        guard library.marks(for: pair.id).flag == .reject else { return end(.fail, "X did not reject the selected pair") }
        await press("\u{7F}", 51, .command)
        guard await waitFor(3, { self.window.attachedSheet != nil }), let alert = window.attachedSheet else {
            return end(.fail, "⌘⌫ showed no confirm (trashRequest \(library.trashRequest != nil))")
        }
        shot("08a-trash-confirm")
        guard let go = buttons(in: alert).first(where: { $0.title == "Move to Trash" }) else { return end(.fail, "the confirm has no Move to Trash button") }
        go.performClick(nil)
        guard await waitFor(5, { self.library.trashUndo != nil }) else { return end(.fail, "nothing moved: \(library.trashError ?? "")") }
        await settle(1)
        let gone = !exists(raw) && !exists(jpeg)
        let inTrash = files(dir.appendingPathComponent("trash")).map(\.lastPathComponent)
        note("in the tour's trash: \(inTrash.sorted().joined(separator: ", "))")
        shot("08b-trash-banner")
        let ok = gone && inTrash.contains(raw.lastPathComponent) && inTrash.contains(jpeg.lastPathComponent)
        // Edit › Undo Move to Trash (the banner's Undo is the same call) puts both back.
        guard chooseMenu(["Edit", "Undo Move to Trash"]) else { return end(.fail, "Edit › Undo Move to Trash is missing or disabled") }
        await settle(1.5)
        let back = exists(raw) && exists(jpeg)
        note("after the banner's Undo: \(raw.lastPathComponent) \(exists(raw) ? "back" : "MISSING"), \(jpeg.lastPathComponent) \(exists(jpeg) ? "back" : "MISSING")")
        library.setFlag(nil, for: [pair.id])
        end(ok && back ? .look : .fail, ok
            ? (back ? "both files went and came back; judge in 08b that the banner sits above the filter bar" : "Undo did not bring both back")
            : "the pair did not both go to the trash")
    }

    private func renamePairWithBothBanners() async {
        begin("09", "Rename a pair (Photo › Rename…) under a Trash banner: both files renamed, the two banners stack above the filter bar")
        // A Trash banner first: a plain JPEG rejected and trashed.
        if let plain = library.photos.first(where: { $0.companion == nil && $0.fileURL?.pathExtension.lowercased() == "jpg" }) {
            library.click(plain.id)
            await press("x", 7)
            await press("\u{7F}", 51, .command)
            if await waitFor(3, { self.window.attachedSheet != nil }), let alert = window.attachedSheet {
                buttons(in: alert).first { $0.title == "Move to Trash" }?.performClick(nil)
            }
            _ = await waitFor(5) { self.library.trashUndo != nil }
            note("trash banner from \(plain.fileURL!.lastPathComponent): \(library.trashBannerShown)")
        }
        guard let pair = library.photos.last(where: { $0.companion != nil }), let raw = pair.fileURL, let jpeg = pair.companion else {
            return end(.fail, "no pair")
        }
        library.click(pair.id)
        guard chooseMenu(["Photo", "Rename…"]) else { return end(.fail, "Photo › Rename… is missing or disabled") }
        guard await waitFor(3, { self.window.attachedSheet != nil }), let sheet = window.attachedSheet else { return end(.fail, "no Rename sheet") }
        await settle(1)
        note("rename sheet \(Int(sheet.frame.width))×\(Int(sheet.frame.height)) pt")
        shot("09a-rename-sheet")
        await press("\r", 36)
        guard await waitFor(5, { self.library.renameUndo != nil || self.library.renameError != nil }) else { return end(.fail, "Rename did nothing") }
        await settle(1)
        let stem = raw.deletingPathExtension().lastPathComponent
        let newRaw = files(photosDir).first { $0.pathExtension == raw.pathExtension && $0.lastPathComponent.hasPrefix(stem + "-") }
        let newJpeg = files(photosDir).first { $0.pathExtension == jpeg.pathExtension && $0.lastPathComponent.hasPrefix(stem + "-") }
        note("renamed: \(newRaw?.lastPathComponent ?? "no RAW") + \(newJpeg?.lastPathComponent ?? "no JPEG"); old names left: \(exists(raw) || exists(jpeg))")
        note("error: \(library.renameError ?? "none")")
        shot("09b-two-banners")
        let ok = newRaw != nil && newJpeg != nil && !exists(raw) && !exists(jpeg)
            && newRaw!.deletingPathExtension().lastPathComponent == newJpeg!.deletingPathExtension().lastPathComponent
        end(ok ? .look : .fail, ok
            ? "both files took one new name; judge in 09a the sheet's preview and in 09b the two banners over the filter bar"
            : "the pair was not renamed together")
    }

    private func collections() async {
        begin("10", "Collections: Photo › Add to Collection and File › Open Collection list a new collection at once, and drop it once deleted")
        guard let first = library.visiblePhotos.first else { return end(.fail, "no photo") }
        library.click(first.id)
        let name = "Tour Collection"
        guard chooseMenu(["Photo", "Add to Collection", "New Collection…"]) else { return end(.fail, "New Collection… is missing or disabled") }
        guard await waitFor(3, { self.window.attachedSheet != nil }), let sheet = window.attachedSheet else { return end(.fail, "no name sheet") }
        if let field = textFields(in: sheet).first(where: { $0.isEditable }) { sheet.makeFirstResponder(field) }
        await typeText(name, in: sheet)
        shot("10a-new-collection")
        await press("\r", 36)
        _ = await waitFor(3) { self.window.attachedSheet == nil }
        await settle(1)
        let addAt = menuTitles(["Photo", "Add to Collection"])
        let openAt = menuTitles(["File", "Open Collection"])
        note("Add to Collection: \(addAt.joined(separator: " | "))")
        note("Open Collection: \(openAt.joined(separator: " | "))")
        let listed = addAt.contains(name) && openAt.contains(name)
        // Open it, then File › Delete Collection….
        guard chooseMenu(["File", "Open Collection", name]) else { return end(.fail, "could not open \(name) from File › Open Collection") }
        _ = await waitFor(5) { self.library.openCollection != nil }
        await settle(1)
        guard chooseMenu(["File", "Delete Collection…"]), await waitFor(3, { self.window.attachedSheet != nil }),
              let alert = window.attachedSheet else { return end(.fail, "Delete Collection… showed no confirm") }
        buttons(in: alert).first { $0.title == "Delete" }?.performClick(nil)
        await settle(1.5)
        let addAfter = menuTitles(["Photo", "Add to Collection"])
        let openAfter = menuTitles(["File", "Open Collection"])
        note("after Delete — Add to Collection: \(addAfter.joined(separator: " | ")); Open Collection: \(openAfter.joined(separator: " | "))")
        let dropped = !addAfter.contains(name) && !openAfter.contains(name)
        library.open(photosDir)
        _ = await waitFor(5) { !self.library.photos.isEmpty }
        end(listed && dropped ? .pass : .fail, listed
            ? (dropped ? "listed at once, gone at once" : "still listed after the delete")
            : "not listed at once after New Collection (a menu that redraws only when reopened shows the same way here)")
    }

    private func searchKeys() async {
        begin("11", "⌘A selects every photo in the grid; search: ⌘F focuses the field, typed letters fire no bare key, ⌘A there is the field's own, ⌘Z undoes the photo's edit, Esc clears")
        if library.loupe { await press("g", 5) }
        guard let target = library.visiblePhotos.first(where: { $0.fileURL?.lastPathComponent.hasPrefix("DSC") == true }) else {
            return end(.fail, "no DSC photo")
        }
        library.click(target.id)
        let selectAll = menuItem(["Edit", "Select All Photos"])
        note("Edit › Select All Photos: key \"\(selectAll?.keyEquivalent ?? "-")\" mask \(selectAll?.keyEquivalentModifierMask.rawValue ?? 0), enabled \(selectAll?.isEnabled ?? false)")
        await press("a", 0, .command)
        await settle(0.5)
        let gridAll = library.selectedIDs.count == library.visiblePhotos.count
        note("⌘A in the grid (no field focused): \(library.selectedIDs.count) of \(library.visiblePhotos.count) selected")
        library.click(target.id)
        var r = library.recipe(for: target.id)
        r.set(.exposure, to: 0.7)
        library.setRecipe(r, for: target.id)
        let marksBefore = library.marks(for: target.id)
        await press("f", 3, .command)
        guard await waitFor(2, { self.library.textEntryActive }) else { return end(.fail, "⌘F did not focus the search field") }
        await typeText("dsc")
        await settle(1)
        let typed = library.searchText
        let marksSame = library.marks(for: target.id) == marksBefore
        note("search text \"\(typed)\", \(library.visiblePhotos.count) of \(library.photos.count) shown; marks unchanged by typing: \(marksSame)")
        shot("11a-search-typed")
        let selectedBefore = library.selectedIDs.count
        await press("a", 0, .command)
        await settle(0.5)
        let editor = window.firstResponder as? NSTextView
        let textSelected = editor.map { $0.selectedRange().length } ?? 0
        let photosKept = library.selectedIDs.count == selectedBefore
        note("⌘A: photos selected \(selectedBefore) -> \(library.selectedIDs.count) of \(library.visiblePhotos.count) shown; field text selected \(textSelected) characters")
        shot("11b-search-cmd-a")
        library.click(target.id)
        await settle(0.3)
        let exposureBefore = library.recipe(for: target.id).value(of: .exposure)
        await press("z", 6, .command)
        await settle(0.5)
        let exposureAfter = library.recipe(for: target.id).value(of: .exposure)
        note("⌘Z: exposure \(fmt(exposureBefore)) -> \(fmt(exposureAfter)); search text now \"\(library.searchText)\"; field focused \(library.textEntryActive)")
        let photoUndo = exposureAfter == 0 && library.searchText == typed
        await press("\u{1B}", 53)
        await settle(0.5)
        let cleared = library.searchText.isEmpty && !library.textEntryActive
        note("Esc: search text \"\(library.searchText)\", focused \(library.textEntryActive)")
        var bad: [String] = []
        if typed != "dsc" { bad.append("typing did not reach the field") }
        if !marksSame { bad.append("a typed letter fired a bare key") }
        if !gridAll { bad.append("⌘A in the grid did not select every photo") }
        if !photosKept { bad.append("⌘A in the search field changed the photo selection") }
        if !photoUndo { bad.append("⌘Z did not undo the photo's edit") }
        if !cleared { bad.append("Esc did not clear and unfocus") }
        end(bad.isEmpty ? .pass : .fail, bad.isEmpty ? "each key did what it should" : bad.joined(separator: "; "))
    }

    private func skipped() {
        begin("12", "Save to Photos live path (C-19 theory)")
        end(.skip, "needs Photos access granted by your click and a Photos album; not driven by the tour")
        begin("13", "Card import with Removable Volumes access refused (C-41 theory)")
        end(.skip, "needs a real SD card and a refused grant")
    }

    // MARK: Steps and report

    private func begin(_ id: String, _ title: String) {
        current = Step(id: id, title: title, verdict: .skip, notes: [], shots: [])
        print("LIVE-TOUR step \(id): \(title)")
    }

    private func note(_ line: String) { current?.notes.append(line) }

    private func end(_ verdict: Verdict, _ summary: String) {
        guard var step = current else { return }
        step.verdict = verdict
        step.notes.insert(summary, at: 0)
        steps.append(step)
        current = nil
        print("LIVE-TOUR   \(verdict.rawValue): \(summary)")
    }

    private func finish(_ abort: String?) {
        if let abort { begin("00", "Tour aborted"); end(.fail, abort) }
        var md = "# PhotoLab live tour\n\n"
        let count = { (v: Verdict) in self.steps.filter { $0.verdict == v }.count }
        md += "\(count(.pass)) PASS · \(count(.fail)) FAIL · \(count(.look)) LOOK · \(count(.skip)) SKIP — \(Date().formatted())\n\n"
        for s in steps {
            md += "## \(s.id) \(s.verdict.rawValue) — \(s.title)\n\n"
            for (i, n) in s.notes.enumerated() { md += i == 0 ? "**\(n)**\n\n" : "- \(n)\n" }
            if !s.shots.isEmpty { md += "\nShots: " + s.shots.map { "`shots/\($0)`" }.joined(separator: ", ") + "\n" }
            md += "\n"
        }
        try? md.write(to: dir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        UserDefaults(suiteName: Self.defaultsSuite)?.removePersistentDomain(forName: Self.defaultsSuite)
        print("LIVE-TOUR done: \(count(.pass)) pass, \(count(.fail)) fail, \(count(.look)) look, \(count(.skip)) skip")
        exit(count(.fail) == 0 ? 0 : 1)
    }

    // MARK: Driving the app

    /// One key, down and up, as the keyboard sends it: a CGEvent from the
    /// key code (the window server and the keyboard layout make its
    /// characters, as for a real key) posted to this process alone, so no
    /// other app ever receives it and no Accessibility grant is asked for.
    /// `chars` is only for the log; the key code is what is pressed.
    private func press(_ chars: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) async {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.postToPid(getpid())
        }
        await settle(0.35)
    }

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46, " ": 49,
    ]

    private func typeText(_ text: String, in target: NSWindow? = nil) async {
        if let target { target.makeKey() }
        for ch in text {
            let lower = Character(ch.lowercased())
            await press(String(ch), Self.keyCodes[lower] ?? 0, ch.isUppercase ? .shift : [])
        }
    }

    private func openExportSheet() async -> Bool {
        await press("E", 14, [.command, .shift])
        return await waitFor(3) { self.window.attachedSheet != nil }
    }

    /// What opening a menu does before it draws: SwiftUI fills a submenu
    /// or a pop-up's items only then.
    private func opening(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.delegate?.menuWillOpen?(menu)
        menu.update()
        menu.delegate?.menuDidClose?(menu)
    }

    private func menuItem(_ path: [String]) -> NSMenuItem? {
        var menu = NSApp.mainMenu
        var item: NSMenuItem?
        for title in path {
            guard let m = menu else { return nil }
            opening(m)
            item = m.items.first { $0.title == title }
            menu = item?.submenu
        }
        return item
    }

    /// The titles in a submenu as it shows when opened.
    private func menuTitles(_ path: [String]) -> [String] {
        guard let menu = menuItem(path)?.submenu else { return [] }
        opening(menu)
        return menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    private func chooseMenu(_ path: [String]) -> Bool {
        guard let item = menuItem(path), let menu = item.menu else { return false }
        menu.update()
        guard item.isEnabled else { return false }
        menu.performActionForItem(at: menu.index(of: item))
        return true
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        var found: [T] = []
        if let hit = root as? T { found.append(hit) }
        for sub in root.subviews { found += views(type, in: sub) }
        return found
    }

    private func buttons(in window: NSWindow) -> [NSButton] {
        views(NSButton.self, in: window.contentView?.superview ?? window.contentView)
    }

    private func textFields(in window: NSWindow) -> [NSTextField] {
        views(NSTextField.self, in: window.contentView)
    }

    /// The sheet's pop-up showing `shown` now (SwiftUI's pop-ups hold no
    /// items until their menu opens, so they are found by their title).
    private func popUp(in window: NSWindow, showing shown: String) -> NSPopUpButton? {
        views(NSPopUpButton.self, in: window.contentView).first { $0.titleOfSelectedItem == shown || $0.title == shown }
    }

    /// Opens the pop-up's menu as a click does and picks `title` from it
    /// while it is open; returns the titles the open menu listed.
    @discardableResult
    private func choose(_ popUp: NSPopUpButton, _ title: String) -> [String] {
        var listed: [String] = []
        RunLoop.main.perform(inModes: [.eventTracking]) {
            MainActor.assumeIsolated {
                guard let menu = popUp.menu else { return }
                listed = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                let index = menu.items.firstIndex { $0.title == title }
                menu.cancelTracking()
                if let index { menu.performActionForItem(at: index) }
            }
        }
        popUp.performClick(nil)
        return listed
    }

    /// Which AppKit controls SwiftUI drew in a sheet, for the report.
    private func controlsNote(_ sheet: NSWindow) {
        let pops = views(NSPopUpButton.self, in: sheet.contentView).map { "[\($0.titleOfSelectedItem ?? "")]" }
        let fields = textFields(in: sheet).filter(\.isEditable).map { "(\($0.placeholderString ?? $0.stringValue))" }
        note("sheet controls: pop-ups \(pops.joined(separator: " ")); fields \(fields.joined(separator: " "))")
    }

    private func shot(_ name: String) {
        if let file = capture(window, name) { current?.shots.append(file) }
        if let sheet = window.attachedSheet, let file = capture(sheet, name + "-sheet") { current?.shots.append(file) }
    }

    private func capture(_ window: NSWindow, _ name: String) -> String? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let file = name + ".png"
        try? data.write(to: shotsDir.appendingPathComponent(file))
        return file
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: Files and measures

    private func photo(named name: String) -> Photo? {
        library.photos.first { $0.fileURL?.lastPathComponent == name }
    }

    private func files(_ folder: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    private func isoSpeed(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first else { return nil }
        return iso
    }

    /// The centre 800 px of the full-resolution render, noise reduction off
    /// and on: the high-pass sigma of its luminance, and of its colour
    /// (each channel minus the luminance).
    nonisolated static func noiseMeasure(_ url: URL, luminance: Double, color: Double)
        -> (off: Double, on: Double, chromaOff: Double, chromaOn: Double)? {
        guard let source = Renderer.fullResolution(url, decodeNow: true) else { return nil }
        let region = Renderer.Region(center: CGPoint(x: 0.5, y: 0.5), size: CGSize(width: 800, height: 800))
        var on = Recipe.neutral
        on.set(.luminanceNoise, to: luminance)
        on.set(.colorNoise, to: color)
        guard let a = Renderer.shared.render(source, recipe: .neutral, region: region)?.image,
              let b = Renderer.shared.render(source, recipe: on, region: region)?.image,
              let sa = sigmas(a), let sb = sigmas(b) else { return nil }
        return (sa.luma, sb.luma, sa.chroma, sb.chroma)
    }

    nonisolated static func highPassSigma(_ url: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return sigmas(image)?.luma
    }

    /// Each pixel minus the mean of its four neighbours, over the image:
    /// the standard deviation for the luminance and for the colour.
    nonisolated static func sigmas(_ image: CGImage) -> (luma: Double, chroma: Double)? {
        let w = image.width, h = image.height
        guard w > 2, h > 2 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func luma(_ i: Int) -> Double { 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2]) }
        func chroma(_ i: Int) -> Double { Double(px[i]) - Double(px[i + 2]) }
        var sl = 0.0, sl2 = 0.0, sc = 0.0, sc2 = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = (y * w + x) * 4
                let l = luma(i) - (luma(i - 4) + luma(i + 4) + luma(i - w * 4) + luma(i + w * 4)) / 4
                let c = chroma(i) - (chroma(i - 4) + chroma(i + 4) + chroma(i - w * 4) + chroma(i + w * 4)) / 4
                sl += l; sl2 += l * l; sc += c; sc2 += c * c; n += 1
            }
        }
        return ((sl2 / n - (sl / n) * (sl / n)).squareRoot(), (sc2 / n - (sc / n) * (sc / n)).squareRoot())
    }

    /// The written file's ICC profile name and EXIF ColorSpace tag.
    nonisolated static func colorInfo(_ url: URL) -> (profile: String?, exifSpace: Int?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (nil, nil) }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        return (props[kCGImagePropertyProfileName] as? String, exif?[kCGImagePropertyExifColorSpace] as? Int)
    }
}
