import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Presets: a named recipe saved to a user-level folder comes back in a
/// fresh store (the quit-and-reopen proof), applies to another photo through
/// `Library.setRecipe` (sidecar written, undoable), keeps that photo's own
/// geometry, renames and deletes; the starter set seeds once; and the strip's
/// thumbnails render in time on a 24 MP photo. Every store here points at a
/// temp directory, never the user's Application Support folder.
@MainActor
final class PresetTests: XCTestCase {
    private var presetsDir: URL!
    private var folder: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-presets-\(UUID().uuidString)", isDirectory: true)
        presetsDir = base.appendingPathComponent("presets", isDirectory: true)
        folder = base.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: presetsDir.deletingLastPathComponent())
    }

    /// Writes a small PNG so `Library.scan` sees a real image.
    @discardableResult
    private func makePhoto(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private var sampleLook: Recipe {
        var r = Recipe.neutral
        r.set(.exposure, to: 0.8)
        r.set(.temperature, to: 22)
        r.set(.highlights, to: -35)
        r.set(.curveBlacks, to: 9)
        r.set(.satOrange, to: 15)
        r.set(.grain, to: 12)
        r.set(.vibrance, to: 40)
        r.setEnabled(.vibrance, false)
        return r
    }

    // MARK: Model

    func testStarterSetIsSixDistinctLooksWithoutGeometry() {
        let starters = Preset.starters
        XCTAssertEqual(starters.count, 6)
        XCTAssertEqual(Set(starters.map(\.name)).count, 6)
        XCTAssertEqual(starters.first?.name, "Neutral")
        XCTAssertTrue(starters[0].recipe.isNeutral)
        for p in starters.dropFirst() {
            XCTAssertFalse(p.recipe.isNeutral, "\(p.name) should change something")
            XCTAssertEqual(p.recipe.adjustments.count, AdjustmentKind.allCases.count, "\(p.name) is normalized")
            for kind in AdjustmentKind.geometryKinds {
                XCTAssertEqual(p.recipe.value(of: kind), 0, "\(p.name) carries no \(kind.rawValue)")
            }
        }
        XCTAssertEqual(starters.first { $0.name == "High-Contrast B&W" }?.recipe.value(of: .saturation), -100)
    }

    func testSavingDropsGeometryAndApplyingKeepsThePhotosOwn() {
        var cropped = sampleLook
        cropped.set(.rotate, to: 7)
        cropped.set(.cropLeft, to: 12)
        let preset = Preset(name: "Look", from: cropped)
        XCTAssertEqual(preset.recipe.value(of: .rotate), 0)
        XCTAssertEqual(preset.recipe.value(of: .cropLeft), 0)
        XCTAssertEqual(preset.recipe.value(of: .exposure), 0.8)

        var target = Recipe.neutral
        target.set(.rotate, to: -3)
        target.set(.cropTop, to: 20)
        target.set(.contrast, to: 60) // overwritten by the look
        let applied = preset.apply(to: target)
        XCTAssertEqual(applied.value(of: .rotate), -3)
        XCTAssertEqual(applied.value(of: .cropTop), 20)
        XCTAssertEqual(applied.value(of: .contrast), 0)
        XCTAssertEqual(applied.value(of: .exposure), 0.8)
        XCTAssertFalse(applied.isEnabled(.vibrance))
        XCTAssertTrue(preset.matches(applied))
        XCTAssertFalse(preset.matches(target))
    }

    // MARK: Store

    func testSaveThenLoadRoundTripsThroughAFreshStore() throws {
        let store = PresetStore(directory: presetsDir)
        let preset = Preset(name: "Golden Hour", from: sampleLook)
        try store.save(preset)
        XCTAssertEqual(store.url(for: "Golden Hour").path, presetsDir.appendingPathComponent("Golden Hour.json").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: "Golden Hour").path))

        // A second store on the same directory is what a relaunched app has.
        let reopened = PresetStore(directory: presetsDir)
        let loaded = try XCTUnwrap(try reopened.load("Golden Hour"))
        XCTAssertEqual(loaded.recipe, preset.recipe)
        XCTAssertEqual(loaded.name, "Golden Hour")
        XCTAssertEqual(reopened.loadAll().presets.map(\.name), ["Golden Hour"])
    }

    func testFileNameIsSanitizedAndTheNameKept() throws {
        let store = PresetStore(directory: presetsDir)
        try store.save(Preset(name: "  Warm / Film: v2 ", from: sampleLook))
        let all = store.loadAll()
        XCTAssertEqual(all.presets.map(\.name), ["Warm / Film: v2"])
        let files = try FileManager.default.contentsOfDirectory(atPath: presetsDir.path)
        XCTAssertEqual(files, ["Warm - Film- v2.json"])
        // A different name that maps to the same file is refused, not merged.
        XCTAssertThrowsError(try store.save(Preset(name: "Warm : Film/ v2", from: sampleLook))) { error in
            guard case PresetError.fileNameCollision = error else { return XCTFail("\(error)") }
        }
    }

    func testInvalidNamesAreRejected() {
        XCTAssertThrowsError(try PresetStore.validated(""))
        XCTAssertThrowsError(try PresetStore.validated("   \n"))
        XCTAssertThrowsError(try PresetStore.validated(".hidden"))
        XCTAssertThrowsError(try PresetStore.validated(String(repeating: "x", count: 81)))
        XCTAssertEqual(try PresetStore.validated(" Punchy "), "Punchy")
    }

    func testRenameKeepsTheRecipeRefusesATakenNameAndDeleteRemovesTheFile() throws {
        let store = PresetStore(directory: presetsDir)
        try store.save(Preset(name: "A", from: sampleLook))
        try store.save(Preset(name: "B", from: .neutral))
        XCTAssertThrowsError(try store.rename("A", to: "B")) { error in
            XCTAssertEqual(error as? PresetError, .nameExists("B"))
        }
        try store.rename("A", to: "C")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: "A").path))
        XCTAssertEqual(try store.load("C")?.recipe, Preset(name: "A", from: sampleLook).recipe)
        XCTAssertEqual(store.loadAll().presets.map(\.name), ["B", "C"])
        try store.remove("B")
        XCTAssertEqual(store.loadAll().presets.map(\.name), ["C"])
        XCTAssertThrowsError(try store.remove("B")) { error in
            XCTAssertEqual(error as? PresetError, .notFound("B"))
        }
    }

    func testUnreadablePresetIsListedAndLeftAlone() throws {
        let store = PresetStore(directory: presetsDir)
        try store.save(Preset(name: "Good", from: sampleLook))
        let bad = presetsDir.appendingPathComponent("Broken.json")
        try Data("{not json".utf8).write(to: bad)
        let all = store.loadAll()
        XCTAssertEqual(all.presets.map(\.name), ["Good"])
        // The directory listing resolves /var to /private/var (AGENTS.md).
        XCTAssertEqual(all.unreadable.map { $0.resolvingSymlinksInPath().path }, [bad.resolvingSymlinksInPath().path])
        XCTAssertEqual(try Data(contentsOf: bad), Data("{not json".utf8))
    }

    @MainActor
    func testFreshDirectoryIsSeededWithStartersOnce() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: presetsDir.path))
        let first = PresetLibrary(store: PresetStore(directory: presetsDir))
        XCTAssertNil(first.error)
        XCTAssertEqual(first.presets.map(\.name),
                       ["Cool Matte", "Faded", "High-Contrast B&W", "Neutral", "Punchy", "Warm Film"])
        XCTAssertEqual(first.presets.first { $0.name == "Faded" }?.recipe,
                       Preset.starters.first { $0.name == "Faded" }?.recipe)

        first.delete("Faded")
        XCTAssertNil(first.error)
        XCTAssertEqual(first.presets.count, 5)

        // A relaunch does not bring a deleted starter back; Restore does.
        let second = PresetLibrary(store: PresetStore(directory: presetsDir))
        XCTAssertEqual(second.presets.count, 5)
        XCTAssertNil(second.preset(named: "Faded"))
        second.restoreStarters()
        XCTAssertEqual(second.presets.count, 6)
    }

    @MainActor
    func testPresetLibraryReportsErrorsAndRecovers() throws {
        let lib = PresetLibrary(store: PresetStore(directory: presetsDir))
        XCTAssertNil(lib.save(sampleLook, as: "   "))
        XCTAssertEqual(lib.error, PresetError.emptyName.errorDescription)
        XCTAssertNotNil(lib.save(sampleLook, as: "Mine"))
        XCTAssertNil(lib.error)
        XCTAssertEqual(lib.preset(named: "Mine")?.recipe, Preset(name: "Mine", from: sampleLook).recipe)
        lib.rename("Mine", to: "Neutral")
        XCTAssertEqual(lib.error, PresetError.nameExists("Neutral").errorDescription)
        XCTAssertNotNil(lib.preset(named: "Mine"))
    }

    // MARK: Apply through the library (the done criterion)

    /// Save a look from photo A, "quit" (fresh store and fresh Library),
    /// apply the preset to photo B: B's recipe is the look, its sidecar is
    /// on disk, a third Library opened on the folder shows it, and undo takes
    /// B back.
    func testSavedPresetAppliedToAnotherPhotoAfterReopenReproducesTheEdit() throws {
        try makePhoto("a.png")
        try makePhoto("b.png")

        // Session 1: edit A, save the look.
        let session1 = Library(rememberFolder: false)
        session1.open(folder)
        let a = session1.photos[0].id, b = session1.photos[1].id
        session1.setRecipe(sampleLook, for: a)
        let store1 = PresetStore(directory: presetsDir)
        try store1.save(Preset(name: "From A", from: session1.recipe(for: a)))

        // Session 2: a fresh store and library, B has its own crop.
        let store2 = PresetStore(directory: presetsDir)
        let preset = try XCTUnwrap(try store2.load("From A"))
        let session2 = Library(rememberFolder: false)
        session2.open(folder)
        var bBefore = Recipe.neutral
        bBefore.set(.cropRight, to: 10)
        session2.setRecipe(bBefore, for: b)
        session2.apply(preset, to: b)

        var expected = sampleLook.normalized
        expected.set(.cropRight, to: 10)
        XCTAssertEqual(session2.recipe(for: b), expected)
        XCTAssertEqual(session2.recipe(for: a), sampleLook, "A is untouched by applying to B")
        XCTAssertEqual(try SidecarStore(folder: folder).load(for: b), expected, "the sidecar was written")

        // Session 3: reopen the folder; B shows the look.
        let session3 = Library(rememberFolder: false)
        session3.open(folder)
        XCTAssertEqual(session3.recipe(for: b), expected)
        XCTAssertTrue(preset.matches(session3.recipe(for: b)))

        // Undo in session 2 takes B back to its crop-only recipe and persists it.
        session2.selection = b
        XCTAssertTrue(session2.canUndo)
        session2.undo()
        XCTAssertEqual(session2.recipe(for: b), bBefore)
        XCTAssertEqual(try SidecarStore(folder: folder).load(for: b), bBefore)
        session2.redo()
        XCTAssertEqual(session2.recipe(for: b), expected)
    }

    func testApplyingThePresetAPhotoAlreadyShowsIsNoStep() throws {
        try makePhoto("a.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let a = lib.photos[0].id
        let preset = Preset.starters.first { $0.name == "Punchy" }!
        lib.apply(preset, to: a)
        lib.selection = a
        XCTAssertTrue(lib.canUndo)
        lib.undo()
        XCTAssertFalse(lib.canUndo)
        lib.redo()
        lib.apply(preset, to: a) // same recipe: setRecipe's early return, no second step
        lib.undo()
        XCTAssertTrue(lib.recipe(for: a).isNeutral, "one undo covers the one real apply")
    }

    // MARK: Thumbnails

    /// The strip renders every starter over the current photo; each must come
    /// back under 50 ms on a 24 MP photo (debug build, load-sensitive: read
    /// `uptime` before trusting a red). Prints the per-preset times.
    func testPresetThumbnailsRenderUnder50msEachOn24MP() throws {
        let url = try bench24MPImageURL()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let master = try XCTUnwrap(Renderer.previewMaster(url, maxPixelSize: PresetThumbnails.masterPixelSize))
        let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        XCTAssertLessThanOrEqual(max(master.extent.width, master.extent.height), CGFloat(PresetThumbnails.masterPixelSize))

        var base = Recipe.neutral
        base.set(.rotate, to: 2)
        // Warm the kernels once (the app's first strip pays this on its first photo).
        _ = PresetThumbnails.render(master: master, presets: Preset.starters, base: base, pixelSize: PresetThumbnails.cellPixelSize)
        var worst = 0.0
        var total = 0.0
        var lines: [String] = []
        for _ in 0..<3 {
            let strip = PresetThumbnails.render(master: master, presets: Preset.starters, base: base,
                                                pixelSize: PresetThumbnails.cellPixelSize)
            XCTAssertEqual(strip.count, Preset.starters.count)
            total = strip.reduce(0) { $0 + $1.milliseconds }
            lines = strip.map { String(format: "%@ %.1f ms (%d×%d)", $0.name, $0.milliseconds, $0.image.width, $0.image.height) }
            worst = strip.map(\.milliseconds).max() ?? 0
        }
        for t in PresetThumbnails.render(master: master, presets: Preset.starters, base: base, pixelSize: PresetThumbnails.cellPixelSize) {
            XCTAssertLessThan(t.milliseconds, 50, "\(t.name) thumbnail must render under 50 ms")
            XCTAssertLessThanOrEqual(max(t.image.width, t.image.height), PresetThumbnails.cellPixelSize)
        }
        // Different looks give different thumbnails (the strip is live, not a copy of one frame).
        let strip = PresetThumbnails.render(master: master, presets: Preset.starters, base: base, pixelSize: PresetThumbnails.cellPixelSize)
        let neutral = try XCTUnwrap(strip.first { $0.name == "Neutral" }?.image)
        let bw = try XCTUnwrap(strip.first { $0.name == "High-Contrast B&W" }?.image)
        XCTAssertGreaterThan(maxDiff(neutral, bw), 20)
        print(String(format: "BENCH-PRESETS %@: master %d×%d decoded in %.0f ms; strip of %d at %d px: %.1f ms total, slowest %.1f ms",
                     url.lastPathComponent, Int(master.extent.width), Int(master.extent.height), decodeMs,
                     Preset.starters.count, PresetThumbnails.cellPixelSize, total, worst))
        for line in lines { print("BENCH-PRESET " + line) }
    }


    // MARK: Unreadable files are kept, never overwritten

    private func backups(of file: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(file.lastPathComponent + ".unreadable-") }
            .sorted { $0.path < $1.path }
    }

    func testUnreadablePresetIsNotAnEmptySlotAndIsKeptAsTheBackupOfASave() throws {
        let store = PresetStore(directory: presetsDir)
        try FileManager.default.createDirectory(at: presetsDir, withIntermediateDirectories: true)
        let bad = presetsDir.appendingPathComponent("Broken.json")
        let junk = Data("{not json".utf8)
        try junk.write(to: bad)
        XCTAssertTrue(store.exists("Broken"), "an undecodable file is still a preset, not an empty slot")
        XCTAssertThrowsError(try store.load("Broken"))

        let when = Date()
        try store.save(Preset(name: "Broken", from: sampleLook), now: when)
        let kept = try backups(of: bad)
        XCTAssertEqual(kept.map(\.lastPathComponent), ["Broken.json.unreadable-\(UnreadableBackup.stamp(when))"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(kept.first)), junk)
        XCTAssertEqual(try store.load("Broken")?.recipe, Preset(name: "Broken", from: sampleLook).recipe)
        let all = store.loadAll()
        XCTAssertEqual(all.presets.map(\.name), ["Broken"])
        XCTAssertTrue(all.unreadable.isEmpty, "the backup is not a .json and is not listed")

        // Restore Starters over a damaged starter file keeps the damaged bytes too.
        let neutral = presetsDir.appendingPathComponent("Neutral.json")
        try junk.write(to: neutral)
        try store.writeStarters()
        XCTAssertEqual(try backups(of: neutral).count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups(of: neutral).first)), junk)
        XCTAssertEqual(store.loadAll().presets.count, Preset.starters.count + 1)
    }

    @MainActor
    func testPresetFromANewerBuildIsRefusedListedUnreadableAndKeptOnSave() throws {
        let store = PresetStore(directory: presetsDir)
        try store.save(Preset(name: "Future", from: sampleLook))
        let file = store.url(for: "Future")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        obj["version"] = Preset.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try newer.write(to: file)

        XCTAssertThrowsError(try store.load("Future")) { error in
            XCTAssertEqual(error as? PresetError, .unsupportedVersion("Future", Preset.currentVersion + 1))
        }
        XCTAssertTrue(store.exists("Future"))
        let all = store.loadAll()
        XCTAssertTrue(all.presets.isEmpty)
        XCTAssertEqual(all.unreadable.map { $0.resolvingSymlinksInPath().path }, [file.resolvingSymlinksInPath().path])
        XCTAssertEqual(try Data(contentsOf: file), newer, "a read never rewrites")

        // The library shows it as unreadable; saving over it keeps the newer file as the backup.
        let lib = PresetLibrary(store: store)
        XCTAssertEqual(lib.unreadable.count, 1)
        XCTAssertNotNil(lib.error)
        XCTAssertNotNil(lib.save(sampleLook, as: "Future"))
        XCTAssertNil(lib.error)
        XCTAssertTrue(lib.unreadable.isEmpty)
        XCTAssertEqual(lib.preset(named: "Future")?.recipe, Preset(name: "Future", from: sampleLook).recipe)
        let kept = try backups(of: file)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(kept.first)), newer)
    }
}
