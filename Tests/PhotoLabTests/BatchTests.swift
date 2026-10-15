import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Batch: the grid's multi-selection, applying a preset or copying settings
/// onto many photos with a sync mask (one sidecar each, one undo step for
/// the lot), and the export queue (full-size JPEGs through the one renderer,
/// with progress and cancel). Every folder here is a temp directory: photos,
/// sidecars and exports never touch the user's files.
@MainActor
final class BatchTests: XCTestCase {
    private var base: URL!
    private var folder: URL!
    private var outDir: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-batch-\(UUID().uuidString)", isDirectory: true)
        folder = base.appendingPathComponent("photos", isDirectory: true)
        outDir = base.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// Writes a small gray PNG so `Library.scan` sees a real image; `level`
    /// is its gray (0…1).
    @discardableResult
    private func makePhoto(_ name: String, level: CGFloat = 0.4, size: Int = 8) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func openLibrary() -> Library {
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        return lib
    }

    private var sidecarDir: URL { folder.appendingPathComponent(".photolab", isDirectory: true) }

    private func sidecarCount() throws -> Int {
        guard FileManager.default.fileExists(atPath: sidecarDir.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(atPath: sidecarDir.path).filter { $0.hasSuffix(".json") }.count
    }

    /// Mean gray of an exported file, decoded through ImageIO into RGBA8.
    private func meanGray(_ url: URL) throws -> (mean: Double, width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let m = meanRGB(try XCTUnwrap(ctx.makeImage()))
        return ((m.r + m.g + m.b) / 3, cg.width, cg.height)
    }

    // MARK: Sync mask

    func testSyncingTakesOnlyTheMaskedKindsFromTheSource() {
        var source = Recipe.neutral
        source.set(.exposure, to: 1.5)
        source.set(.temperature, to: 20)
        source.set(.grain, to: 30)
        source.set(.cropLeft, to: 10)
        source.set(.vibrance, to: 50)
        source.setEnabled(.vibrance, false)

        var target = Recipe.neutral
        target.set(.exposure, to: -0.7)
        target.set(.cropTop, to: 15)
        target.set(.contrast, to: 25)

        let grade = target.syncing(.grade, from: source)
        XCTAssertEqual(grade.value(of: .exposure), -0.7, "grade keeps the target's exposure")
        XCTAssertEqual(grade.value(of: .cropTop), 15, "grade keeps the target's crop")
        XCTAssertEqual(grade.value(of: .cropLeft), 0, "and never brings the source's crop")
        XCTAssertEqual(grade.value(of: .temperature), 20)
        XCTAssertEqual(grade.value(of: .grain), 30)
        XCTAssertEqual(grade.value(of: .contrast), 0, "a kind in the mask the source has at zero is zeroed")
        XCTAssertEqual(grade.value(of: .vibrance), 50)
        XCTAssertFalse(grade.isEnabled(.vibrance), "the enabled flag travels with the value")
        XCTAssertEqual(grade.adjustments.count, AdjustmentKind.allCases.count, "canonical form")

        let look = target.syncing(.look, from: source)
        XCTAssertEqual(look.value(of: .exposure), 1.5, "look brings exposure")
        XCTAssertEqual(look.value(of: .cropTop), 15)

        let everything = target.syncing(.everything, from: source)
        XCTAssertEqual(everything, source.normalized)
        XCTAssertEqual(target.syncing(.nothing, from: source), target.normalized)

        XCTAssertEqual(SyncMask.look.kinds.count, AdjustmentKind.allCases.count - AdjustmentKind.geometryKinds.count)
        XCTAssertEqual(SyncMask.grade.kinds.count, SyncMask.look.kinds.count - 1)
        var m = SyncMask.nothing
        XCTAssertEqual(m.state(of: AdjustmentKind.Section.basic.kinds), false)
        m.set(.exposure, true)
        XCTAssertNil(m.state(of: AdjustmentKind.Section.basic.kinds), "mixed")
        m.set(AdjustmentKind.Section.basic.kinds, true)
        XCTAssertEqual(m.state(of: AdjustmentKind.Section.basic.kinds), true)
    }

    // MARK: Apply to a selection (the done criterion)

    /// A preset applied to 20 selected photos writes 20 sidecars, each the
    /// look over that photo's own geometry; one undo takes all 20 back
    /// (sidecars restored or removed), one redo brings all 20 again, and a
    /// fresh Library sees the result.
    func testApplyingAPresetToTwentySelectedPhotosWritesTwentySidecarsAndUndoRevertsAllTwenty() throws {
        for i in 0..<20 { try makePhoto(String(format: "p%02d.png", i)) }
        let lib = openLibrary()
        XCTAssertEqual(lib.photos.count, 20)
        let ids = lib.photos.map(\.id)

        // Photo 3 has its own crop, photo 5 its own exposure, before the batch.
        var crop = Recipe.neutral
        crop.set(.cropRight, to: 12)
        lib.setRecipe(crop, for: ids[3])
        var bright = Recipe.neutral
        bright.set(.exposure, to: 1)
        lib.setRecipe(bright, for: ids[5])
        XCTAssertEqual(try sidecarCount(), 2)

        lib.click(ids[0])
        lib.selectAll()
        XCTAssertEqual(lib.batchTargets, ids)
        let preset = Preset.starters.first { $0.name == "Punchy" }!
        let changed = lib.apply(preset, to: lib.batchTargets)
        XCTAssertEqual(changed, 20)

        XCTAssertEqual(try sidecarCount(), 20, "one sidecar per photo")
        let store = SidecarStore(folder: folder)
        for (i, id) in ids.enumerated() {
            let r = lib.recipe(for: id)
            XCTAssertTrue(preset.matches(r), "photo \(i) shows the preset")
            XCTAssertEqual(r.value(of: .cropRight), i == 3 ? 12 : 0, "photo \(i) keeps its own crop")
            XCTAssertEqual(r.value(of: .exposure), preset.recipe.value(of: .exposure), "the look's exposure replaces photo \(i)'s")
            XCTAssertEqual(try store.load(for: id), r, "photo \(i)'s sidecar matches")
        }

        // A fresh Library (quit and reopen) sees all 20.
        let reopened = openLibrary()
        XCTAssertEqual(ids.filter { preset.matches(reopened.recipe(for: $0)) }.count, 20)

        // One undo, from any photo of the batch, takes all 20 back.
        lib.selection = ids[11]
        XCTAssertTrue(lib.canUndo)
        lib.undo()
        XCTAssertEqual(try sidecarCount(), 2, "18 sidecars removed, the two earlier edits restored")
        for (i, id) in ids.enumerated() {
            let expected: Recipe = i == 3 ? crop : (i == 5 ? bright : .neutral)
            XCTAssertEqual(lib.recipe(for: id), expected, "photo \(i) is back")
        }
        XCTAssertEqual(try store.load(for: ids[3]), crop)
        XCTAssertEqual(try store.load(for: ids[5]), bright)
        XCTAssertFalse(lib.canUndo, "the batch was the only step on photo 11")

        // One redo brings all 20 again.
        XCTAssertTrue(lib.canRedo)
        lib.redo()
        XCTAssertEqual(try sidecarCount(), 20)
        XCTAssertEqual(ids.filter { preset.matches(lib.recipe(for: $0)) }.count, 20)
        XCTAssertEqual(lib.recipe(for: ids[3]).value(of: .cropRight), 12)

        // Applying the same preset again changes nothing: no step, no write.
        XCTAssertEqual(lib.apply(preset, to: lib.batchTargets), 0)
        lib.undo()
        XCTAssertEqual(try sidecarCount(), 2, "the second apply was no step")
    }

    /// A photo edited after the batch keeps its later edit when the batch is
    /// undone from another photo; on that photo itself undo takes the later
    /// edit first, then the batch (wherever it is still the latest step).
    func testABatchIsOneStepAndALaterSingleEditSitsOnTopOfIt() throws {
        for i in 0..<5 { try makePhoto("p\(i).png") }
        let lib = openLibrary()
        let ids = lib.photos.map(\.id)
        var look = Recipe.neutral
        look.set(.contrast, to: 30)
        lib.sync(look, mask: .look, to: ids)
        XCTAssertEqual(try sidecarCount(), 5)

        var later = lib.recipe(for: ids[2])
        later.set(.grain, to: 40)
        lib.setRecipe(later, for: ids[2])

        // Undo from photo 0: the batch goes on 0, 1, 3, 4; photo 2's later edit stays.
        lib.selection = ids[0]
        lib.undo()
        XCTAssertEqual(try sidecarCount(), 1)
        XCTAssertEqual(lib.recipe(for: ids[2]), later)
        XCTAssertTrue(lib.recipe(for: ids[1]).isNeutral)

        // On photo 2: first the grain, then (its batch step now on top) the batch's remainder.
        lib.selection = ids[2]
        lib.undo()
        XCTAssertEqual(lib.recipe(for: ids[2]).value(of: .grain), 0)
        XCTAssertEqual(lib.recipe(for: ids[2]).value(of: .contrast), 30)
        lib.undo()
        XCTAssertTrue(lib.recipe(for: ids[2]).isNeutral)
        XCTAssertEqual(try sidecarCount(), 0)
        XCTAssertFalse(lib.canUndo)

        // Redo from photo 4 brings the batch back on every photo whose redo
        // top is the batch: all five now, photo 2's batch step being back on
        // top of its redo stack; its grain edit is the step after that.
        lib.selection = ids[4]
        lib.redo()
        XCTAssertEqual(ids.filter { lib.recipe(for: $0).value(of: .contrast) == 30 }.count, 5)
        XCTAssertEqual(lib.recipe(for: ids[2]).value(of: .grain), 0)
        XCTAssertEqual(try sidecarCount(), 5)
        lib.selection = ids[2]
        XCTAssertTrue(lib.canRedo)
        lib.redo()
        XCTAssertEqual(lib.recipe(for: ids[2]), later, "then photo 2's own edit")
        XCTAssertEqual(lib.recipe(for: ids[1]).value(of: .grain), 0, "a single step touches one photo")
    }

    // MARK: Copy settings

    /// Copy Settings from A, paste onto B and C with the grade mask: B and C
    /// take A's grade and keep their own exposure and crop; A is untouched;
    /// the two writes are one undo step.
    func testCopySettingsWithTheGradeMaskKeepsEachPhotosOwnExposureAndCrop() throws {
        try makePhoto("a.png")
        try makePhoto("b.png")
        try makePhoto("c.png")
        let lib = openLibrary()
        let a = lib.photos[0].id, b = lib.photos[1].id, c = lib.photos[2].id

        var aRecipe = Recipe.neutral
        aRecipe.set(.exposure, to: 1.5)
        aRecipe.set(.cropLeft, to: 10)
        aRecipe.set(.temperature, to: 20)
        aRecipe.set(.grain, to: 30)
        aRecipe.set(.satBlue, to: -40)
        lib.setRecipe(aRecipe, for: a)
        var bRecipe = Recipe.neutral
        bRecipe.set(.exposure, to: -0.5)
        bRecipe.set(.cropTop, to: 20)
        bRecipe.set(.contrast, to: 15)
        lib.setRecipe(bRecipe, for: b)

        lib.copySettings(from: a)
        XCTAssertEqual(lib.copiedSettings?.name, "a.png")
        lib.click(b)
        lib.click(c, toggling: true)
        XCTAssertEqual(lib.batchTargets, [b, c])
        lib.lastSyncMask = .grade
        lib.requestPaste()
        let request = try XCTUnwrap(lib.syncRequest)
        XCTAssertEqual(request.targets, [b, c])
        XCTAssertEqual(request.source, aRecipe)
        XCTAssertEqual(request.mask, .grade)
        XCTAssertEqual(lib.sync(request.source, mask: request.mask, to: request.targets), 2)

        let bAfter = lib.recipe(for: b)
        XCTAssertEqual(bAfter.value(of: .exposure), -0.5, "B keeps its exposure")
        XCTAssertEqual(bAfter.value(of: .cropTop), 20, "B keeps its crop")
        XCTAssertEqual(bAfter.value(of: .cropLeft), 0, "A's crop does not travel")
        XCTAssertEqual(bAfter.value(of: .temperature), 20)
        XCTAssertEqual(bAfter.value(of: .grain), 30)
        XCTAssertEqual(bAfter.value(of: .satBlue), -40)
        XCTAssertEqual(bAfter.value(of: .contrast), 0, "A's zero contrast replaces B's")
        let cAfter = lib.recipe(for: c)
        XCTAssertEqual(cAfter.value(of: .exposure), 0)
        XCTAssertEqual(cAfter.value(of: .temperature), 20)
        XCTAssertEqual(lib.recipe(for: a), aRecipe, "the source is untouched")
        let store = SidecarStore(folder: folder)
        XCTAssertEqual(try store.load(for: b), bAfter)
        XCTAssertEqual(try store.load(for: c), cAfter)

        lib.selection = c
        lib.undo()
        XCTAssertEqual(lib.recipe(for: b), bRecipe, "one undo covers both")
        XCTAssertTrue(lib.recipe(for: c).isNeutral)
        XCTAssertFalse(store.exists(for: c))

        // Sync Settings (anchor onto the rest) builds the same request from the selection.
        lib.click(a)
        lib.click(c, extending: true)
        lib.requestSync()
        let sync = try XCTUnwrap(lib.syncRequest)
        XCTAssertEqual(sync.sourceName, "a.png")
        XCTAssertEqual(sync.targets, [b, c], "the anchor is the source, not a target")
    }

    // MARK: Selection

    func testClickShiftClickCommandClickAndSelectAll() throws {
        for i in 0..<6 { try makePhoto("p\(i).png") }
        let lib = openLibrary()
        let p = lib.photos.map(\.id)
        XCTAssertTrue(lib.batchTargets.isEmpty)

        lib.click(p[1])
        XCTAssertEqual(lib.selectedIDs, [p[1]])
        XCTAssertEqual(lib.selection, p[1])

        lib.click(p[4], extending: true)
        XCTAssertEqual(lib.selectedIDs, Set(p[1...4]))
        XCTAssertEqual(lib.selection, p[1], "shift keeps the anchor")
        XCTAssertEqual(lib.batchTargets, Array(p[1...4]), "folder order")

        lib.click(p[2], toggling: true)
        XCTAssertEqual(lib.selectedIDs, [p[1], p[3], p[4]])
        XCTAssertEqual(lib.selection, p[1])

        lib.click(p[5], toggling: true)
        XCTAssertEqual(lib.selectedIDs, [p[1], p[3], p[4], p[5]])
        XCTAssertEqual(lib.selection, p[5], "command-adding moves the anchor")

        lib.click(p[5], toggling: true)
        XCTAssertEqual(lib.selectedIDs, [p[1], p[3], p[4]])
        XCTAssertEqual(lib.selection, p[1], "removing the anchor moves it to the first selected")

        lib.selectAll()
        XCTAssertEqual(lib.selectedIDs, Set(p))
        XCTAssertEqual(lib.selection, p[1])

        lib.collapseSelection()
        XCTAssertEqual(lib.selectedIDs, [p[1]])

        lib.selectAll()
        lib.selection = p[3]
        XCTAssertEqual(lib.selectedIDs, [p[3]], "setting the anchor collapses the selection")
        lib.select(offset: 1)
        XCTAssertEqual(lib.selectedIDs, [p[4]])

        lib.click(p[0])
        XCTAssertEqual(lib.selectedIDs, [p[0]])
        lib.click(p[0], toggling: true)
        XCTAssertTrue(lib.selectedIDs.isEmpty)
        XCTAssertNil(lib.selection)
    }

    // MARK: Export

    /// Five photos with edits go through the queue into a temp folder: five
    /// JPEGs at full size, the brightened one brighter than the neutral one
    /// (the export is the rendered recipe, not a copy), originals untouched,
    /// nothing written into the photo folder.
    @MainActor
    func testExportQueueWritesEveryPhotoThroughTheRendererAsJPEG() async throws {
        for i in 0..<5 { try makePhoto("p\(i).png", level: 0.3, size: 24) }
        let lib = openLibrary()
        let ids = lib.photos.map(\.id)
        var bright = Recipe.neutral
        bright.set(.exposure, to: 2)
        lib.setRecipe(bright, for: ids[1])
        var cropped = Recipe.neutral
        cropped.set(.cropLeft, to: 25)
        cropped.set(.cropRight, to: 25)
        lib.setRecipe(cropped, for: ids[2])
        let originalBytes = try Data(contentsOf: try XCTUnwrap(ids[1].fileURL))
        let entriesBefore = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

        let queue = ExportQueue()
        lib.selectAll()
        queue.start(try await lib.exportItems(for: lib.batchTargets), into: outDir)
        XCTAssertEqual(queue.state, .running)
        XCTAssertEqual(queue.total, 5)
        await queue.wait()

        XCTAssertEqual(queue.state, .finished)
        XCTAssertEqual(queue.done, 5)
        XCTAssertTrue(queue.failures.isEmpty, "\(queue.failures.map(\.message))")
        XCTAssertEqual(queue.completed, 5)
        XCTAssertNil(queue.current)
        let files = try FileManager.default.contentsOfDirectory(atPath: outDir.path).sorted()
        XCTAssertEqual(files, ["p0.jpg", "p1.jpg", "p2.jpg", "p3.jpg", "p4.jpg"])
        XCTAssertEqual(queue.exported.map(\.lastPathComponent), files)

        let neutral = try meanGray(outDir.appendingPathComponent("p0.jpg"))
        let brighter = try meanGray(outDir.appendingPathComponent("p1.jpg"))
        let narrow = try meanGray(outDir.appendingPathComponent("p2.jpg"))
        XCTAssertEqual(neutral.width, 24)
        XCTAssertEqual(neutral.height, 24, "full size, no resize")
        XCTAssertGreaterThan(brighter.mean, neutral.mean + 60, "exposure +2 went through the renderer")
        XCTAssertEqual(narrow.width, 12, "the crop went through too")
        XCTAssertEqual(narrow.height, 24)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outDir.appendingPathComponent("p1.jpg") as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)

        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(ids[1].fileURL)), originalBytes, "the original is untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), entriesBefore,
                       "nothing new in the photo folder")

        // A second export into the same folder never overwrites: " 2" names.
        queue.dismiss()
        XCTAssertEqual(queue.state, .idle)
        queue.start(try await lib.exportItems(for: [ids[0]]), into: outDir)
        await queue.wait()
        XCTAssertEqual(queue.exported.map(\.lastPathComponent), ["p0 2.jpg"])
        XCTAssertEqual(Exporter.destination(for: try XCTUnwrap(ids[0].fileURL), in: outDir).lastPathComponent, "p0 3.jpg")
    }

    /// Cancel stops the queue after the file in flight: with a worker that
    /// takes 80 ms per item, cancelling once the first is done leaves most of
    /// the ten unwritten, the state is `cancelled`, and the worker was called
    /// exactly as many times as there are results.
    @MainActor
    func testExportQueueCancelStopsAfterTheItemInFlight() async throws {
        for i in 0..<10 { try makePhoto("p\(i).png") }
        let lib = openLibrary()
        let calls = Counter()
        let queue = ExportQueue { source, _, folder, _ in
            calls.increment()
            Thread.sleep(forTimeInterval: 0.08)
            let out = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".jpg")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([0xFF, 0xD8]).write(to: out)
            return .written(out)
        }
        lib.selectAll()
        queue.start(try await lib.exportItems(for: lib.batchTargets), into: outDir)
        XCTAssertEqual(queue.total, 10)

        // Wait for the first file, then cancel.
        let deadline = Date().addingTimeInterval(5)
        while queue.done < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThanOrEqual(queue.done, 1)
        queue.cancel()
        await queue.wait()

        XCTAssertEqual(queue.state, .cancelled)
        XCTAssertLessThanOrEqual(queue.done, 3, "stopped after the item in flight")
        XCTAssertLessThan(queue.done, queue.total)
        XCTAssertNil(queue.current)
        XCTAssertEqual(calls.value, queue.done, "no job started after cancel")
        let files = try FileManager.default.contentsOfDirectory(atPath: outDir.path)
        XCTAssertEqual(files.count, queue.done, "what was written stays")

        // The queue is reusable after a cancel.
        queue.dismiss()
        queue.start(try await lib.exportItems(for: Array(lib.batchTargets.prefix(2))), into: outDir)
        await queue.wait()
        XCTAssertEqual(queue.state, .finished)
        XCTAssertEqual(queue.done, 2)

        // A failing worker is reported per item and the run still finishes.
        let failing = ExportQueue { source, _, _, _ in
            if source.lastPathComponent == "p1.png" { throw Exporter.Failure.cannotDecode(source) }
            return .written(source)
        }
        failing.start(try await lib.exportItems(for: Array(lib.batchTargets.prefix(3))), into: outDir)
        await failing.wait()
        XCTAssertEqual(failing.state, .finished)
        XCTAssertEqual(failing.done, 2)
        XCTAssertEqual(failing.failures.map(\.source.lastPathComponent), ["p1.png"])
        XCTAssertEqual(failing.completed, 3)
    }
}

/// A thread-safe call counter for the injected export worker.
private final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
