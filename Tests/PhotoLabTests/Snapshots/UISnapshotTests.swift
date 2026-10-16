import XCTest
import AppKit
import SwiftUI
@testable import PhotoLab

/// The main-window states of the app, written as PNGs (light and dark) by the
/// offscreen harness (`SnapshotHarness`). Every test skips unless
/// `PHOTOLAB_SNAPSHOTS=<output dir>` is set; see Documentation/Testing.md.
///
/// The gate when the variable is set: every state is written in both modes,
/// none is a single flat color, none times out, `index.txt` names them all.
@MainActor
final class UISnapshotTests: XCTestCase {
    private static let wide = CGSize(width: 1280, height: 800)
    private static let floor = CGSize(width: 900, height: 600)
    /// The export sheets read an empty, never-created folder, not the
    /// user's export presets: the Preset menu reads "None".
    private static let noExportPresets = ExportPresetStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("photolab-snapshots-no-export-presets-\(UUID().uuidString)", isDirectory: true))

    // MARK: Scenes

    /// A scene on a fresh fixture folder: the library open on it, then `setup`.
    private func scene(junk: Bool = false,
                       big: Bool = false,
                       unreadablePreset: Bool = false,
                       sidecarJunkFor: String? = nil,
                       setup: (Library, SnapshotFixture, ExportQueue) async throws -> Void = { _, _, _ in }) async throws
        -> SnapshotHarness.Scene {
        let fx = try SnapshotFixture(junk: junk, big: big)
        if let name = sidecarJunkFor {
            let store = SidecarStore(folder: fx.folder)
            let url = store.url(for: fx.folder.appendingPathComponent(name))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{ not json".utf8).write(to: url)
        }
        let presets = PresetLibrary(store: PresetStore(directory: fx.presetDirectory))
        var look = Recipe.neutral
        look.set(.exposure, to: 0.4); look.set(.contrast, to: 15); look.set(.vibrance, to: 25)
        _ = presets.save(look, as: "Warm morning")
        var mono = Recipe.neutral
        mono.set(.saturation, to: -100); mono.set(.contrast, to: 20)
        _ = presets.save(mono, as: "Mono")
        if unreadablePreset {
            try Data("{ not a preset".utf8).write(to: fx.presetDirectory.appendingPathComponent("Faded film.json"))
            presets.reload()
        }
        let exports = ExportQueue(remember: false, photos: FakePhotosWriter(), stagingDirectory: fx.stagingDirectory)
        var scene = SnapshotHarness.Scene(presets: presets, exports: exports)
        scene.cleanup = { fx.remove() }
        scene.library.open(fx.folder)
        try await setup(scene.library, fx, exports)
        let library = scene.library
        scene.ready = {
            return Self.thumbnailsLanded(library)
        }
        return scene
    }

    /// The first row or two of visible photos that can decode have their
    /// thumbnail (the rendered one when edited) in the shared cache: those
    /// cells have run their `.task` offscreen and landed. A lazy grid builds
    /// only the cells in the viewport, so the rest never load, as in the app.
    private static func thumbnailsLanded(_ library: Library) -> Bool {
        guard library.source != nil, !library.loupe else { return true }
        let first = library.visiblePhotos.filter { $0.name != SnapshotFixture.junk }.prefix(8)
        return first.allSatisfy { photo in
            Thumbnails.shared.cached(Thumbnails.Key(photo.id, recipe: library.recipe(for: photo.id))) != nil
        }
    }

    private func ids(_ lib: Library) -> [Photo.ID] { lib.photos.map(\.id) }

    private func id(_ name: String, in lib: Library) throws -> Photo.ID {
        try XCTUnwrap(lib.photos.first { $0.name == name }, "fixture \(name)").id
    }

    /// The marks and edits the grid states share: 3 edited, 2 picks, 1 reject,
    /// ratings 1-5 spread, one selected.
    private func decorate(_ lib: Library) {
        let all = ids(lib)
        var warm = Recipe.neutral; warm.set(.exposure, to: 0.8); warm.set(.temperature, to: 20)
        var cool = Recipe.neutral; cool.set(.temperature, to: -35); cool.set(.saturation, to: 20)
        var punch = Recipe.neutral; punch.set(.contrast, to: 30); punch.set(.vibrance, to: 40)
        lib.setRecipe(warm, for: all[0]); lib.setRecipe(cool, for: all[4]); lib.setRecipe(punch, for: all[9])
        lib.setFlag(.pick, for: [all[1], all[6]])
        lib.setFlag(.reject, for: [all[5]])
        for (i, n) in [(0, 1), (1, 5), (2, 3), (3, 4), (4, 2), (6, 5), (7, 3), (9, 4), (10, 1)] { lib.setRating(n, for: [all[i]]) }
        lib.click(all[2])
    }

    private func edited(_ lib: Library, _ id: Photo.ID, _ tweak: (inout Recipe) -> Void) {
        var r = lib.recipe(for: id)
        tweak(&r)
        lib.setRecipe(r, for: id)
    }

    /// Open the loupe on the first photo with an edit.
    private func loupe(_ lib: Library, name: String = "IMG_0001.jpg", tweak: (inout Recipe) -> Void = { r in
        r.set(.exposure, to: 0.6); r.set(.contrast, to: 20); r.set(.temperature, to: 15); r.set(.vibrance, to: 30)
    }) throws {
        let target = try id(name, in: lib)
        lib.click(target)
        edited(lib, target, tweak)
        lib.loupe = true
    }

    private func shot(_ number: String, _ name: String, _ what: String, model: String, caveat: String = "",
                      size: CGSize = UISnapshotTests.wide) -> SnapshotHarness.Shot {
        .init(number: number, name: name, what: what, model: model, caveat: caveat, size: size)
    }

    // MARK: The probe

    /// First: does `.task` fire in a window that is never on screen? A grid of
    /// fixtures must come out with its thumbnails landed (not spinners).
    func testProbeTasksFireOffscreen() async throws {
        let out = try SnapshotHarness.requireOutput()
        let harness = try SnapshotHarness(out: out)
        var landed = false
        let start = Date()
        await harness.shoot(shot("00", "probe", "the grid of fixtures, to prove tasks run offscreen", model: "grid, no edits")) {
            try await self.scene()
        }
        XCTAssertTrue(harness.failures.isEmpty, "the probe did not settle: \(harness.failures)")
        landed = harness.failures.isEmpty
        try "probe: tasks fire offscreen = \(landed), settled in \(String(format: "%.1f", Date().timeIntervalSince(start))) s\n"
            .write(to: out.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
        // The probe's files are not part of the catalogue.
        for mode in SnapshotHarness.Mode.allCases {
            try? FileManager.default.removeItem(at: out.appendingPathComponent(mode.rawValue).appendingPathComponent("00-probe.png"))
        }
    }

    // MARK: The catalogue, states 1-15

    /// `PHOTOLAB_SNAPSHOT_GROUP` = `main` or `sheets` takes only that group
    /// (while iterating); unset takes the whole catalogue into `index.txt`.
    func testCatalogueIsWrittenInBothModes() async throws {
        let out = try SnapshotHarness.requireOutput()
        let h = try SnapshotHarness(out: out)
        let group = ProcessInfo.processInfo.environment["PHOTOLAB_SNAPSHOT_GROUP"] ?? "all"
        if group != "sheets" { await shootMainWindowStates(h) }
        if group != "main" { await shootSheetStates(h) }
        try h.writeIndex(notes: Self.notes, file: group == "all" ? "index.txt" : "index-\(group).txt")
        XCTAssertEqual(h.failures, [], "states that failed to write")
        if group == "all" { XCTAssertEqual(h.written.count, 37, "every state of the catalogue was taken") }
        // Every state in both modes, none flat.
        for s in h.written {
            for mode in SnapshotHarness.Mode.allCases {
                let url = out.appendingPathComponent(mode.rawValue).appendingPathComponent(s.file)
                let data = try XCTUnwrap(FileManager.default.contents(atPath: url.path), "\(mode.rawValue)/\(s.file) was written")
                let stats = try SnapshotHarness.stats(data)
                XCTAssertFalse(stats.isFlat, "\(mode.rawValue)/\(s.file) is flat: \(stats)")
            }
        }
    }

    private func shootMainWindowStates(_ h: SnapshotHarness) async {
        let toolbarNote = "the window toolbar and title are drawn only if the hosted window's frame view includes them; look for them in the PNG"
        let materialNote = "materials (.thinMaterial badges, .bar) and vibrancy may render flat without the window server compositing them"

        // 1. welcome, with and without an app bundle
        for (suffix, name, bundle) in [("", "welcome", true), ("c", "welcome-no-bundle", false)] {
            await h.shoot(shot("01\(suffix)", name, "no source: the Welcome view" + (bundle ? "" : " as a bare swift run binary (no app bundle)"),
                               model: "Library with no source; hasBundle injected = \(bundle)", caveat: toolbarNote)) {
                var s = SnapshotHarness.Scene(presets: PresetLibrary(store: PresetStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("snap-p-\(UUID().uuidString)"))),
                                              exports: ExportQueue(remember: false, photos: FakePhotosWriter(), stagingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("snap-s-\(UUID().uuidString)")))
                s.hasBundle = bundle
                return s
            }
        }
        await h.shoot(shot("01b", "welcome-open-error", "Welcome with the error of opening a missing path",
                           model: "Library.open(<missing path>) so openError is set", caveat: toolbarNote)) {
            var s = SnapshotHarness.Scene(presets: PresetLibrary(store: PresetStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("snap-p-\(UUID().uuidString)"))),
                                          exports: ExportQueue(remember: false, photos: FakePhotosWriter(), stagingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("snap-s-\(UUID().uuidString)")))
            s.hasBundle = true
            s.library.open(URL(fileURLWithPath: "/nonexistent/Lake trip 2026"))
            return s
        }

        // 2. grid (and the floor size)
        let gridModel = "12 JPEGs + 1 PNG; 3 edited, 2 picks, 1 reject, ratings 1-5 spread, long name, filter All, the third photo (IMG_0002) selected"
        await h.shoot(shot("02", "grid", "the grid, mixed marks and edits", model: gridModel, caveat: materialNote + "; " + toolbarNote)) {
            try await self.scene { lib, _, _ in self.decorate(lib) }
        }
        await h.shoot(shot("02b", "grid-900x600", "the grid at the 900x600 floor", model: gridModel, caveat: materialNote,
                           size: Self.floor)) {
            try await self.scene { lib, _, _ in self.decorate(lib) }
        }
        // 3. filter
        await h.shoot(shot("03", "grid-filter", "the grid under the 3-star filter: a subset and the n of N count",
                           model: gridModel + "; filter = at least 3 stars", caveat: materialNote)) {
            try await self.scene { lib, _, _ in self.decorate(lib); lib.filter = .stars(3) }
        }
        // 4. filter with no match
        await h.shoot(shot("04", "grid-filter-empty", "a filter nothing matches: No photos match the filter",
                           model: "no marks at all; filter = Rejected", caveat: materialNote)) {
            try await self.scene { lib, _, _ in lib.filter = .rejected }
        }
        // 5. empty folder
        await h.shoot(shot("05", "grid-empty-folder", "an empty folder: No photos in this folder",
                           model: "Library opened on an empty folder", caveat: materialNote)) {
            let fx = try SnapshotFixture()
            for f in try FileManager.default.contentsOfDirectory(atPath: fx.folder.path) {
                try FileManager.default.removeItem(at: fx.folder.appendingPathComponent(f))
            }
            var s = SnapshotHarness.Scene(presets: PresetLibrary(store: PresetStore(directory: fx.presetDirectory)),
                                          exports: ExportQueue(remember: false, photos: FakePhotosWriter(), stagingDirectory: fx.stagingDirectory))
            s.library.open(fx.folder)
            s.cleanup = { fx.remove() }
            return s
        }
        // 6. batch
        await h.shoot(shot("06", "grid-batch", "four photos selected with an anchor: the batch bar",
                           model: gridModel + "; click the third photo then shift-click the sixth", caveat: materialNote)) {
            try await self.scene { lib, _, _ in
                self.decorate(lib)
                let all = self.ids(lib)
                lib.click(all[2]); lib.click(all[5], extending: true)
            }
        }
        // 7. export bar
        for (suffix, size, label) in [("", Self.wide, ""), ("c", Self.floor, "-900x600")] {
            await h.shoot(shot("07\(suffix.isEmpty ? "" : suffix)", "export-bar-running\(label)", "the export bar mid-run (2 of 5 written, the third in flight)",
                               model: "ExportQueue running 5 items, worker held on the third", caveat: materialNote, size: size)) {
                try await self.runningExport()
            }
        }
        await h.shoot(shot("07b", "export-bar-finished", "the export bar after a run: one failure, one skipped",
                           model: "ExportQueue finished: 6 items, IMG_0003 refused (disk full), IMG_0004 skipped", caveat: materialNote)) {
            try await self.finishedExport()
        }
        // 8-14. loupe
        await h.shoot(shot("08", "loupe", "the loupe on an edited photo: Basic open, presets strip, histogram",
                           model: "IMG_0001 selected, loupe on, exposure +0.6, contrast +20, temperature +15, vibrance +30; 2 presets",
                           caveat: materialNote + "; " + toolbarNote, )) {
            var s = try await self.scene { lib, _, _ in try self.loupe(lib) }
            s.needsCanvas = true
            return s
        }
        await h.shoot(shot("08z", "loupe-zoomed", "the loupe at 1:1 on a 3200x2000 photo, the 1:1 badge, centred",
                           model: "IMG_0000-big.jpg selected, loupe on, exposure +0.6, loupeZoom = .actual(centre of the frame); the filmstrip shows along the bottom as in 08",
                           caveat: materialNote + "; the window is zoomed (the bars are magnified, render line reads the 3200x2000 master) but the 1:1 badge at the top right is cut off at the canvas edge (\"1:\") - review whether that is real or an offscreen artifact; the folder has 14 files here (the big photo is added)")) {
            var s = try await self.scene(big: true) { lib, _, _ in
                try self.loupe(lib, name: SnapshotFixture.big)
                lib.loupeZoom = .actual(center: CGPoint(x: 0.5, y: 0.5))
            }
            s.needsCanvas = true
            return s
        }
        await h.shoot(shot("09", "loupe-sections", "every panel section expanded, HSL on Saturation",
                           model: "as 08 with PanelStart(all sections, saturation); the window is 2400 pt tall so the whole panel shows without scrolling",
                           caveat: materialNote, size: CGSize(width: 1280, height: 2400))) {
            var s = try await self.scene { lib, _, _ in try self.loupe(lib) }
            s.needsCanvas = true
            s.panelStart = PanelStart(sections: Set(AdjustmentKind.Section.allCases), hslChannel: .saturation)
            return s
        }
        await h.shoot(shot("09g", "loupe-grading", "Color Grading open: the three wheels with their pucks off centre, the luminance and balance sliders, Hue & Saturation open",
                           model: "as 08 with PanelStart(grading only, gradingExact); shadows hue 220 sat 40 (lower left), midtones hue 100 sat 20, highlights hue 40 sat 70 (upper right), shadow luminance -15, balance +20",
                           caveat: materialNote + "; the panel is scrolled to its top, so the grading section shows under the histogram and the closed sections", size: CGSize(width: 1280, height: 1000))) {
            var s = try await self.scene { lib, _, _ in
                try self.loupe(lib) { r in
                    r.set(.exposure, to: 0.3)
                    r.set(.gradeShadowHue, to: 220); r.set(.gradeShadowSat, to: 40); r.set(.gradeShadowLum, to: -15)
                    r.set(.gradeMidtoneHue, to: 100); r.set(.gradeMidtoneSat, to: 20)
                    r.set(.gradeHighlightHue, to: 40); r.set(.gradeHighlightSat, to: 70)
                    r.set(.gradeBalance, to: 20)
                }
            }
            s.needsCanvas = true
            s.panelStart = PanelStart(sections: [.grading], gradingExact: true)
            return s
        }
        await h.shoot(shot("10", "loupe-clipping", "exposure +3 with the clipping overlay: red highlights, lit histogram triangles",
                           model: "IMG_0001 exposure +3, showClipping on", caveat: materialNote)) {
            var s = try await self.scene { lib, _, _ in
                try self.loupe(lib) { $0.set(.exposure, to: 3) }
                lib.showClipping = true
            }
            s.needsCanvas = true
            return s
        }
        await h.shoot(shot("11", "loupe-compare", "Before and After side by side (Y)",
                           model: "as 08 with compare on", caveat: materialNote)) {
            var s = try await self.scene { lib, _, _ in try self.loupe(lib); lib.compare = true }
            s.needsCanvas = true
            return s
        }
        await h.shoot(shot("11b", "loupe-before", "the backslash Before badge on the single canvas",
                           model: "as 08 with showBefore on", caveat: materialNote)) {
            var s = try await self.scene { lib, _, _ in try self.loupe(lib); lib.showBefore = true }
            s.needsCanvas = true
            return s
        }
        await h.shoot(shot("12", "loupe-decode-failure", "the loupe on a file that will not decode",
                           model: "broken.JPG (junk bytes) selected, loupe on", caveat: materialNote)) {
            try await self.scene(junk: true) { lib, _, _ in
                lib.click(try self.id(SnapshotFixture.junk, in: lib)); lib.loupe = true
            }
        }
        await h.shoot(shot("12b", "grid-decode-failure-cell", "the grid with the junk file's cell (does it spin forever?)",
                           model: "13 good files + broken.JPG; the cell's thumbnail task never lands", caveat: "the spinner is the real state of a cell that never decodes; " + materialNote)) {
            try await self.scene(junk: true)
        }
        await h.shoot(shot("13", "loupe-unreadable-sidecar", "the panel's sidecar error line",
                           model: "IMG_0001's .photolab sidecar is junk JSON; IMG_0001 selected, loupe on", caveat: materialNote)) {
            var s = try await self.scene(sidecarJunkFor: "IMG_0001.jpg") { lib, _, _ in
                lib.click(try self.id("IMG_0001.jpg", in: lib)); lib.loupe = true
            }
            s.needsCanvas = true
            return s
        }
        await h.shoot(shot("14", "loupe-save-failed", "the 'could not be saved' line after an edit in a read-only folder",
                           model: "the photo folder is chmod 555, then an edit on IMG_0001", caveat: materialNote)) {
            var s = try await self.scene { lib, fx, _ in
                lib.click(try self.id("IMG_0001.jpg", in: lib))
                lib.loupe = true
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fx.folder.path)
                self.edited(lib, try self.id("IMG_0001.jpg", in: lib)) { $0.set(.exposure, to: 0.5) }
            }
            s.needsCanvas = true
            return s
        }
        // 15. Photos-sourced photo
        for (suffix, name, what, hold) in [("a", "loupe-photos-downloading", "a Photos asset whose original is downloading", true),
                                           ("b", "loupe-photos-fetch-failed", "a Photos asset whose original could not be fetched", false)] {
            await h.shoot(shot("15\(suffix)", name, what + ", edited so Save to Photos is enabled",
                               model: "FakePhotoKit authorized, Recents of 3 assets; first asset selected in the loupe; " + (hold ? "writeOriginal held" : "writeOriginal fails"),
                               caveat: materialNote + "; " + toolbarNote)) {
                try await self.photosScene(hold: hold)
            }
        }

    }

    private static let notes: [String] = [
            "Hosting: NSHostingController (sceneBridgingOptions = .all) as the contentViewController of a titled NSWindow that is never ordered on screen; the window's frame view is drawn with cacheDisplay into a 2x bitmap.",
            "Readiness: a state is written once its model predicate holds (grid: every decodable visible photo's thumbnail is in the shared cache) and two successive captures are identical; a loupe or canvas state must also show a non-flat canvas. A state that does not settle in 45 s fails by name.",
            "Light and dark: the window's appearance (aqua / darkAqua) and the colorScheme environment.",
            "Fixtures: 12 JPEGs (two portrait, one with a long name), one PNG; broken.JPG (junk bytes) only in states 12 and 12b; a junk sidecar only in state 13. Folders are temp, library and presets and export queue are injected (nothing remembered, nothing touching the real Photos library).",
            "Sheets (16-19) are each hosted as their own root view at the size they ask for (fittingSize), not presented over the main window: no dimming of the window behind, no sheet chrome or shadow. Their content, layout and copy are exact.",
            "Seams for the sheets: the hasBundle environment value (welcome 01/01c, Export 18d) and PhotosAlbumSheet(access:). No state ever calls requestAuthorization: the Allow buttons are drawn, never clicked.",
            "Not in the catalogue: the menu bar, system alerts and the open/save panels (not hostable offscreen); preset rename and delete confirmation dialogs; the export-destination folder chooser.",
        ]

    // MARK: Sheets, states 16-20

    private func shootSheetStates(_ h: SnapshotHarness) async {
        let sheetNote = "a sheet shown as its own root view at its fitting size, not presented over the window: no window dimming, no sheet chrome, no sheet shadow"
        let fit = SnapshotHarness.fitting

        await h.shoot(shot("16", "sync-sheet", "the Sync Settings sheet: From IMG_0001.jpg onto 3 photos, the sections collapsed, last mask",
                           model: "SyncRequest from an edited IMG_0001 onto the next three; mask = the library's lastSyncMask", caveat: sheetNote, size: fit)) {
            try await self.sheetScene { lib, _, _ in
                let ids = lib.photos.map(\.id)
                self.edited(lib, ids[0]) { $0.set(.exposure, to: 0.6); $0.set(.vibrance, to: 30) }
                return AnyView(SyncSheet(request: SyncRequest(source: lib.recipe(for: ids[0]), sourceName: "IMG_0001.jpg",
                                                              targets: Array(ids[1...3]), mask: lib.lastSyncMask)))
            }
        }
        await h.shoot(shot("17", "export-folder", "Export to a folder, a folder chosen, 4 photos",
                           model: "ExportSheet with 4 items, destination folder, the folder set; hasBundle true", caveat: sheetNote, size: fit)) {
            try await self.sheetScene { lib, exports, items in
                AnyView(ExportSheet(request: .init(items: items), options: exports.options,
                                    folder: URL(fileURLWithPath: "/Volumes/Archive/Lake trip exports", isDirectory: true), album: nil, toPhotos: false,
                                    presetStore: Self.noExportPresets))
            }
        }
        let photosVariants: [(String, String, PhotosAuthorization, Bool, String)] = [
            ("18a", "export-photos-authorized", .authorized, true, "FakePhotosWriter authorized; hasBundle true"),
            ("18b", "export-photos-not-determined", .notDetermined, true, "FakePhotosWriter notDetermined: the Allow Access row (never clicked); hasBundle true"),
            ("18c", "export-photos-denied", .denied, true, "FakePhotosWriter denied: the not-allowed row with its two buttons; hasBundle true"),
            ("18d", "export-photos-no-bundle", .authorized, false, "hasBundle false while Export to Photos was asked for: the sheet falls back to the folder and says why"),
        ]
        for (number, name, status, bundle, model) in photosVariants {
            await h.shoot(shot(number, name, "Export to Photos, 4 photos", model: model, caveat: sheetNote, size: fit)) {
                var s = try await self.sheetScene(status: status) { lib, exports, items in
                    AnyView(ExportSheet(request: .init(items: items), options: exports.options, folder: nil, album: ExportTarget.defaultAlbum, toPhotos: true,
                                        presetStore: Self.noExportPresets))
                }
                s.hasBundle = bundle
                return s
            }
        }
        let albums: [(String, String, PhotosAuthorization, [PhotosAlbum], String)] = [
            ("19a", "photos-sheet-not-determined", .notDetermined, [], "the permission prompt and its Allow button (never clicked)"),
            ("19b", "photos-sheet-denied", .denied, [], "the System Settings pointer and Check Again"),
            ("19c", "photos-sheet-albums", .authorized, [PhotosTests.recents, PhotosTests.trip], "Recents and a regular album with counts, none selected"),
            ("19d", "photos-sheet-empty", .authorized, [], "authorized but no albums: the No albums text"),
            ("19e", "photos-sheet-restricted", .restricted, [], "the restricted-on-this-Mac text"),
        ]
        for (number, name, status, list, what) in albums {
            await h.shoot(shot(number, name, "the Open Photos Library sheet: " + what,
                               model: "PhotosAlbumSheet(access:) on FakePhotoKit(status: \(status)), \(list.count) albums; requestAuthorization is never called",
                               caveat: sheetNote, size: fit)) {
                let base = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-snap-sheet-\(UUID().uuidString)", isDirectory: true)
                let kit = PhotosTests.FakePhotoKit(status: status)
                kit.albumList = list
                let access = PhotosAccess(client: kit, sidecarDirectory: base.appendingPathComponent("sidecars"),
                                          originalsDirectory: base.appendingPathComponent("originals"))
                var s = SnapshotHarness.Scene(presets: PresetLibrary(store: PresetStore(directory: base.appendingPathComponent("presets"))),
                                              exports: ExportQueue(remember: false, photos: FakePhotosWriter(),
                                                                   stagingDirectory: base.appendingPathComponent("staging")))
                s.view = AnyView(PhotosAlbumSheet(access: access))
                s.cleanup = { try? FileManager.default.removeItem(at: base) }
                return s
            }
        }
        await h.shoot(shot("20", "loupe-presets-unreadable", "the loupe's presets strip with a preset file that cannot be read",
                           model: "as 08, plus Faded film.json of junk in the presets folder, so the strip shows its two presets and the library carries the unreadable-file error",
                           caveat: "materials may render flat; if the error is an alert, it is a window-level sheet and may not draw offscreen (look in the PNG)")) {
            var s = try await self.scene(unreadablePreset: true) { lib, _, _ in try self.loupe(lib) }
            s.needsCanvas = true
            return s
        }
    }

    /// A scene for a sheet shown as its own root: a library on the fixture
    /// folder with 4 photos selected, an export queue whose Photos writer has
    /// `status`, and the view `make` builds from the library, the queue and
    /// the 4 export items.
    private func sheetScene(status: PhotosAuthorization = .authorized,
                            make: (Library, ExportQueue, [ExportQueue.Item]) throws -> AnyView) async throws -> SnapshotHarness.Scene {
        let fx = try SnapshotFixture()
        let presets = PresetLibrary(store: PresetStore(directory: fx.presetDirectory))
        let exports = ExportQueue(remember: false, photos: FakePhotosWriter(status: status), stagingDirectory: fx.stagingDirectory)
        var s = SnapshotHarness.Scene(presets: presets, exports: exports)
        s.cleanup = { fx.remove() }
        s.library.open(fx.folder)
        let lib = s.library
        lib.click(lib.photos[0].id); lib.click(lib.photos[3].id, extending: true)
        let items = try await lib.exportItems(for: lib.batchTargets)
        s.view = try make(lib, exports, items)
        return s
    }

    // MARK: Export bar scenes

    private func exportScene(items: Int, worker: @escaping ExportQueue.Worker) async throws -> (SnapshotHarness.Scene, ExportQueue, [ExportQueue.Item]) {
        let fx = try SnapshotFixture()
        let presets = PresetLibrary(store: PresetStore(directory: fx.presetDirectory))
        let exports = ExportQueue(remember: false, photos: FakePhotosWriter(), stagingDirectory: fx.stagingDirectory, worker: worker)
        var s = SnapshotHarness.Scene(presets: presets, exports: exports)
        s.cleanup = { fx.remove() }
        s.library.open(fx.folder)
        let lib = s.library
        lib.selectAll()
        lib.click(lib.photos[0].id); lib.click(lib.photos[items - 1].id, extending: true)
        let list = try await lib.exportItems(for: lib.batchTargets)
        s.ready = { Self.thumbnailsLanded(lib) }
        return (s, exports, list)
    }

    private final class Gate: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
    }

    private func runningExport() async throws -> SnapshotHarness.Scene {
        let gate = Gate()
        let out = FileManager.default.temporaryDirectory
        let (scene, exports, items) = try await exportScene(items: 5) { source, _, _, _, _, _, _, _ in
            if gate.next() > 2 { gate.semaphore.wait() }
            return .written(out.appendingPathComponent(source.lastPathComponent))
        }
        exports.start(items, into: out)
        var s = scene
        let library = scene.library
        s.ready = { Self.thumbnailsLanded(library) && exports.completed == 2 && exports.current != nil }
        let cleanup = scene.cleanup
        s.cleanup = {
            exports.cancel()
            for _ in 0..<8 { gate.semaphore.signal() }
            cleanup()
        }
        return s
    }

    private struct DiskFull: LocalizedError { var errorDescription: String? { "the disk is full" } }

    private func finishedExport() async throws -> SnapshotHarness.Scene {
        let out = FileManager.default.temporaryDirectory
        let (scene, exports, items) = try await exportScene(items: 6) { source, _, _, _, _, _, _, _ in
            let name = source.lastPathComponent
            if name == "IMG_0003.jpg" { throw DiskFull() }
            if name == "IMG_0004.jpg" { return .skipped(out.appendingPathComponent(name)) }
            return .written(out.appendingPathComponent(name))
        }
        exports.start(items, into: out)
        await exports.wait()
        return scene
    }

    // MARK: Photos scene

    private func photosScene(hold: Bool) async throws -> SnapshotHarness.Scene {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-snap-photos-\(UUID().uuidString)", isDirectory: true)
        let kit = PhotosTests.FakePhotoKit(status: .authorized)
        kit.albumList = [PhotosTests.recents, PhotosTests.trip]
        kit.assetsByAlbum[PhotosTests.recents.id] = PhotosTests.shoot
        let hold = hold ? DispatchSemaphore(value: 0) : nil
        kit.writeHold = hold
        kit.failWrites = hold == nil
        let access = PhotosAccess(client: kit, sidecarDirectory: base.appendingPathComponent("sidecars"),
                                  originalsDirectory: base.appendingPathComponent("originals"))
        var s = SnapshotHarness.Scene(presets: PresetLibrary(store: PresetStore(directory: base.appendingPathComponent("presets"))),
                                      exports: ExportQueue(remember: false, photos: FakePhotosWriter(),
                                                           stagingDirectory: base.appendingPathComponent("staging")))
        let lib = s.library
        lib.open(album: PhotosTests.recents, access: access)
        let first = try XCTUnwrap(lib.photos.first).id
        lib.click(first)
        edited(lib, first) { $0.set(.exposure, to: 0.5); $0.set(.vibrance, to: 20) }
        lib.loupe = true
        s.ready = { true }
        s.cleanup = {
            hold?.signal()
            try? FileManager.default.removeItem(at: base)
        }
        return s
    }
}
