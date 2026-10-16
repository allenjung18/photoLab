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

    // MARK: Scenes

    /// A scene on a fresh fixture folder: the library open on it, then `setup`.
    private func scene(junk: Bool = false,
                       sidecarJunkFor: String? = nil,
                       setup: (Library, SnapshotFixture, ExportQueue) async throws -> Void = { _, _, _ in }) async throws
        -> SnapshotHarness.Scene {
        let fx = try SnapshotFixture(junk: junk)
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

    func testMainWindowStatesAreWrittenInBothModes() async throws {
        let out = try SnapshotHarness.requireOutput()
        let h = try SnapshotHarness(out: out)
        let hasBundle = PhotosAccess.hasBundle
        let toolbarNote = "the window toolbar and title are drawn only if the hosted window's frame view includes them; look for them in the PNG"
        let materialNote = "materials (.thinMaterial badges, .bar) and vibrancy may render flat without the window server compositing them"

        // 1. welcome
        await h.shoot(shot("01", "welcome", "no source: the Welcome view",
                           model: "Library with no source; PhotosAccess.hasBundle = \(hasBundle) in this test process",
                           caveat: "the other bundle variant is not selectable until hasBundle is injectable; " + toolbarNote)) {
            SnapshotHarness.Scene(presets: PresetLibrary(store: PresetStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("snap-p-\(UUID().uuidString)"))),
                                  exports: ExportQueue(remember: false, photos: FakePhotosWriter(), stagingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("snap-s-\(UUID().uuidString)")))
        }
        await h.shoot(shot("01b", "welcome-open-error", "Welcome with the error of opening a missing path",
                           model: "Library.open(<missing path>) so openError is set", caveat: toolbarNote)) {
            let s = SnapshotHarness.Scene(presets: PresetLibrary(store: PresetStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("snap-p-\(UUID().uuidString)"))),
                                          exports: ExportQueue(remember: false, photos: FakePhotosWriter(), stagingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("snap-s-\(UUID().uuidString)")))
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
        await h.shoot(shot("09", "loupe-sections", "every panel section expanded, HSL on Saturation",
                           model: "as 08 with PanelStart(all sections, saturation); the window is 2400 pt tall so the whole panel shows without scrolling",
                           caveat: materialNote, size: CGSize(width: 1280, height: 2400))) {
            var s = try await self.scene { lib, _, _ in try self.loupe(lib) }
            s.needsCanvas = true
            s.panelStart = PanelStart(sections: Set(AdjustmentKind.Section.allCases), hslChannel: .saturation)
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

        try h.writeIndex(notes: [
            "Hosting: NSHostingController (sceneBridgingOptions = .all) as the contentViewController of a titled NSWindow that is never ordered on screen; the window's frame view is drawn with cacheDisplay into a 2x bitmap.",
            "Readiness: a state is written once its model predicate holds (grid: every decodable visible photo's thumbnail is in the shared cache) and two successive captures are identical; a loupe or canvas state must also show a non-flat canvas. A state that does not settle in 45 s fails by name.",
            "Light and dark: the window's appearance (aqua / darkAqua) and the colorScheme environment.",
            "Fixtures: 12 JPEGs (two portrait, one with a long name), one PNG; broken.JPG (junk bytes) only in states 12 and 12b; a junk sidecar only in state 13. Folders are temp, library and presets and export queue are injected (nothing remembered, nothing touching the real Photos library).",
            "Not here: the Photos sheets, the Sync and Export sheets (their own root views), preset alert dialogs and the menu bar; they are reviewed from code or in the sheets states.",
        ])
        XCTAssertEqual(h.failures, [], "states that failed to write")
        XCTAssertEqual(h.written.count, 22, "every state of the catalogue was taken")
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
        let (scene, exports, items) = try await exportScene(items: 5) { source, _, _, _, _, _ in
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
        let (scene, exports, items) = try await exportScene(items: 6) { source, _, _, _, _, _ in
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
