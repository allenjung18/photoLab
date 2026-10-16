import XCTest
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// One session through the real model layer, the way a photographer goes:
/// open a folder, drag a slider, save the look as a preset and apply it,
/// flag and rate, filter, select under the filter, sync with the Grade mask,
/// undo and redo, export to a folder and to Photos (a fake writer), then
/// reopen everything in a fresh `Library` and `PresetLibrary`. Nothing here
/// is faked but the Photos writer: real files, real sidecars, the real
/// renderer and exporter. Every folder is a temp directory.
///
/// Each failure is prefixed with the step it happened in (`step`).
@MainActor
final class WorkflowTests: XCTestCase {
    /// The step the session is in, put in front of every failure message.
    nonisolated(unsafe) private var currentStep: String?

    private func step(_ name: String) { currentStep = name }

    nonisolated override func record(_ issue: XCTIssue) {
        var issue = issue
        if let currentStep { issue.compactDescription = "[\(currentStep)] " + issue.compactDescription }
        super.record(issue)
    }

    private var base: URL!
    private var folder: URL!
    private var otherFolder: URL!
    private var presetDir: URL!
    private var exportDir: URL!
    private var neutralDir: URL!
    private var referenceDir: URL!
    private var staging: URL!

    /// The fixture folder in the order the grid must show it (natural order:
    /// `beach 2` before `beach 10`). `beach 10` is the portrait.
    private static let names = ["beach 1.jpg", "beach 2.png", "beach 10.jpg", "city 1.jpg", "city 2.png", "city 3.jpg"]
    private static let landscape = (width: 96, height: 64)

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-workflow-\(UUID().uuidString)", isDirectory: true)
        folder = base.appendingPathComponent("shoot", isDirectory: true)
        otherFolder = base.appendingPathComponent("second shoot", isDirectory: true)
        presetDir = base.appendingPathComponent("presets", isDirectory: true)
        exportDir = base.appendingPathComponent("export", isDirectory: true)
        neutralDir = base.appendingPathComponent("neutral", isDirectory: true)
        referenceDir = base.appendingPathComponent("reference", isDirectory: true)
        staging = base.appendingPathComponent("staging", isDirectory: true)
        for dir in [folder!, otherFolder!, exportDir!, neutralDir!, referenceDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Written out of order: the grid's order is the library's, not the disk's.
        for name in Self.names.reversed() {
            let portrait = name == "beach 10.jpg"
            try writePhoto(folder.appendingPathComponent(name),
                           width: portrait ? Self.landscape.height : Self.landscape.width,
                           height: portrait ? Self.landscape.width : Self.landscape.height)
        }
        try writePhoto(otherFolder.appendingPathComponent("harbour 1.jpg"), width: 96, height: 64)
        try writePhoto(otherFolder.appendingPathComponent("harbour 2.jpg"), width: 96, height: 64)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: The session

    func testAPhotographersSessionFromOpenToExportAndBack() async throws {
        let lib = Library(rememberFolder: false)
        let presets = PresetLibrary(store: PresetStore(directory: presetDir))
        let thumbs = Thumbnails()
        let writer = FakePhotosWriter()

        // 1. Open: the grid's order and names; every photo has a plain thumbnail.
        let ids: [Photo.ID]
        step("1. Open the folder"); do {
            lib.open(folder)
            XCTAssertNil(lib.openError)
            XCTAssertEqual(lib.folder?.standardizedFileURL, folder.standardizedFileURL)
            XCTAssertEqual(lib.photos.map(\.name), Self.names, "natural order, as the grid shows it")
            XCTAssertEqual(lib.visiblePhotos.map(\.name), Self.names)
            XCTAssertNil(lib.selection)
            XCTAssertFalse(lib.loupe)
            XCTAssertEqual(try sidecarCount(folder), 0, "opening writes nothing")
            for photo in lib.photos {
                let result = await thumbs.thumbnail(for: photo.id)
                let thumb = try XCTUnwrap(result, "\(photo.name) has a thumbnail")
                XCTAssertTrue(thumbs.cached(photo.id) === thumb, "\(photo.name): the plain entry is cached")
                XCTAssertTrue(Thumbnails.Key(photo.id, recipe: lib.recipe(for: photo.id)).isPlain)
                let portrait = photo.name == "beach 10.jpg"
                XCTAssertEqual(thumb.size.height > thumb.size.width, portrait, "\(photo.name): orientation kept")
            }
            ids = lib.photos.map(\.id)
        }
        let (a, b, c, d, e, f) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5])

        // 2. A slider drag on A: one undo step, one sidecar, a brighter thumbnail.
        step("2. Drag Exposure on A"); do {
            lib.click(a)
            lib.loupe = true
            lib.beginEdit(a)
            for v in stride(from: 0.1, through: 1.0, by: 0.1) {
                var r = lib.recipe(for: a)
                r.set(.exposure, to: v)
                lib.setRecipe(r, for: a)
            }
            XCTAssertEqual(try sidecarCount(folder), 0, "mid-drag nothing is written")
            lib.endEdit(a)
            XCTAssertEqual(lib.recipe(for: a).value(of: .exposure), 1.0, accuracy: 1e-9)
            XCTAssertEqual(try sidecarCount(folder), 1, "the drag wrote one sidecar")
            XCTAssertEqual(try SidecarStore(folder: folder).load(for: a)?.value(of: .exposure) ?? 0, 1.0, accuracy: 1e-9)

            lib.undo()
            XCTAssertFalse(lib.isEdited(a), "one undo takes the whole drag back")
            XCTAssertFalse(lib.canUndo, "the drag was one step")
            lib.redo()
            XCTAssertEqual(lib.recipe(for: a).value(of: .exposure), 1.0, accuracy: 1e-9)

            let plainResult = await thumbs.thumbnail(for: a)
            let editedResult = await thumbs.thumbnail(for: a, recipe: lib.recipe(for: a))
            let plain = try meanLuma(try XCTUnwrap(plainResult))
            let edited = try meanLuma(try XCTUnwrap(editedResult))
            XCTAssertGreaterThan(edited, plain + 10, "the edited thumbnail is brighter")
        }

        // A's look gains a grade and a crop (single edits, one step each).
        var lookA = lib.recipe(for: a)
        lookA.set(.temperature, to: 25)
        lookA.set(.contrast, to: 20)
        lookA.set(.cropLeft, to: 10)
        lib.setRecipe(lookA, for: a)

        // 3. Save A's look as a preset; apply it to B, which keeps its own framing.
        step("3. Save A's look as a preset and apply it to B"); do {
            var framingB = Recipe.neutral
            framingB.set(.rotate, to: 5)
            framingB.set(.cropTop, to: 8)
            lib.setRecipe(framingB, for: b)

            let saved = try XCTUnwrap(presets.save(lib.recipe(for: a), as: "Beach Look"))
            XCTAssertNil(presets.error)
            XCTAssertEqual(presets.preset(named: "Beach Look"), saved)
            XCTAssertEqual(saved.recipe.value(of: .cropLeft), 0, "a preset carries no geometry")

            lib.apply(saved, to: b)
            let rb = lib.recipe(for: b)
            for kind in [AdjustmentKind.exposure, .temperature, .contrast] {
                XCTAssertEqual(rb.value(of: kind), lib.recipe(for: a).value(of: kind), "B took A's \(kind)")
            }
            XCTAssertEqual(rb.value(of: .rotate), 5, "B keeps its rotation")
            XCTAssertEqual(rb.value(of: .cropTop), 8, "B keeps its crop")
            XCTAssertEqual(rb.value(of: .cropLeft), 0, "A's crop did not travel")
            XCTAssertTrue(saved.matches(rb), "the strip shows the check mark on B")
            XCTAssertFalse(saved.matches(.neutral))
        }

        // B drifts from the look (its own grade), C and D get edits of their own.
        var rb = lib.recipe(for: b)
        rb.set(.temperature, to: -30)
        lib.setRecipe(rb, for: b)
        var rc = Recipe.neutral
        rc.set(.contrast, to: 40)
        lib.setRecipe(rc, for: c)
        var rd = Recipe.neutral
        rd.set(.exposure, to: 0.6)
        rd.set(.cropRight, to: 12)
        lib.setRecipe(rd, for: d)

        // 4. Flag and rate; a reset takes the edit and leaves the marks.
        step("4. Flag, rate, reset"); do {
            lib.setFlag(.pick, for: [a, b, d])
            lib.setFlag(.reject, for: [c])
            lib.setRating(3, for: [a, e])
            lib.setRating(5, for: [b])
            XCTAssertEqual(lib.flag(for: a), .pick)
            XCTAssertEqual(lib.flag(for: c), .reject)
            XCTAssertEqual(lib.rating(for: e), 3)
            XCTAssertTrue(lib.isEdited(a), "a mark leaves the recipe alone")

            let before = lib.recipe(for: a)
            lib.selection = a
            lib.resetRecipe(for: a)
            XCTAssertFalse(lib.isEdited(a), "the edit goes")
            XCTAssertEqual(lib.flag(for: a), .pick, "the flag stays")
            XCTAssertEqual(lib.rating(for: a), 3, "the rating stays")
            XCTAssertTrue(try SidecarStore(folder: folder).exists(for: a), "the sidecar stays for the marks")
            XCTAssertEqual(try SidecarStore(folder: folder).read(for: a)?.marks, Marks(flag: .pick, rating: 3))
            lib.undo()
            XCTAssertEqual(lib.recipe(for: a), before, "undo brings the edit back")
            XCTAssertEqual(lib.flag(for: a), .pick)
        }

        // 5. Filter to Picks with the loupe on a reject: the anchor moves on.
        step("5. Filter to Picks"); do {
            lib.selection = c
            lib.loupe = true
            lib.filter = .picks
            XCTAssertEqual(lib.visiblePhotos.map(\.id), [a, b, d])
            XCTAssertEqual(lib.selection, d, "a hidden anchor moves to the next visible photo in folder order")
            XCTAssertTrue(lib.loupe, "the loupe stays up on the next pick")
            XCTAssertEqual(lib.visibleIndex, 2)
            lib.select(offset: -1)
            XCTAssertEqual(lib.selection, b, "the arrows walk the picks only")
            lib.select(offset: 1)
            XCTAssertEqual(lib.selection, d)

            lib.selectAll()
            XCTAssertEqual(lib.selectedIDs, [a, b, d], "Select All takes the visible photos")
            XCTAssertEqual(lib.selection, d, "and keeps the anchor")
            XCTAssertEqual(lib.batchTargets, [a, b, d])

            // Under 5 stars only B shows; a rating that hides it too leaves
            // nothing visible: no anchor, no loupe.
            lib.filter = .stars(5)
            XCTAssertEqual(lib.visiblePhotos.map(\.id), [b])
            XCTAssertEqual(lib.selection, b)
            lib.setRating(4, for: [b])
            XCTAssertTrue(lib.visiblePhotos.isEmpty)
            XCTAssertNil(lib.selection, "nothing visible, nothing selected")
            XCTAssertFalse(lib.loupe, "and the loupe closes")
            XCTAssertTrue(lib.batchTargets.isEmpty)
            lib.setRating(5, for: [b])
            lib.filter = .picks
            lib.loupe = false
        }

        // 6. Select under the filter and sync the Grade.
        let beforeSync = Dictionary(uniqueKeysWithValues: ids.map { ($0, lib.recipe(for: $0)) })
        step("6. Select A…D under Picks and sync the Grade"); do {
            lib.click(a)
            lib.click(d, extending: true)
            XCTAssertEqual(lib.selectedIDs, [a, b, d], "a shift-click spans the visible photos, never the hidden reject")
            XCTAssertEqual(lib.selection, a)
            lib.requestSync()
            let request = try XCTUnwrap(lib.syncRequest)
            XCTAssertEqual(request.targets, [b, d], "the anchor is the source, not a target")
            XCTAssertEqual(request.sourceName, "beach 1.jpg")
            XCTAssertEqual(request.mask, .look, "the first sheet opens on the look")

            // The sheet: Grade chosen, Synchronize clicked.
            lib.syncRequest = nil
            lib.lastSyncMask = .grade
            XCTAssertEqual(lib.sync(request.source, mask: .grade, to: request.targets), 2)

            let anchor = lib.recipe(for: a)
            for t in [b, d] {
                let r = lib.recipe(for: t), old = beforeSync[t]!
                XCTAssertEqual(r.value(of: .exposure), old.value(of: .exposure), "\(lib.name(for: t)) keeps its exposure")
                for kind in AdjustmentKind.geometryKinds {
                    XCTAssertEqual(r[kind], old[kind], "\(lib.name(for: t)) keeps its \(kind)")
                }
                for kind in SyncMask.grade.kinds {
                    XCTAssertEqual(r[kind], anchor[kind], "\(lib.name(for: t)) takes the anchor's \(kind)")
                }
            }
            for untouched in [a, c, e, f] {
                XCTAssertEqual(lib.recipe(for: untouched), beforeSync[untouched], "\(lib.name(for: untouched)) untouched")
            }
            XCTAssertEqual(try SidecarStore(folder: folder).load(for: d)?.normalized, lib.recipe(for: d).normalized,
                           "D's sidecar holds the sync")
        }
        let afterSync = Dictionary(uniqueKeysWithValues: ids.map { ($0, lib.recipe(for: $0)) })

        // 7. Undo takes the whole sync back in one step; marks are not edits.
        step("7. Undo and redo the sync"); do {
            lib.selection = d
            lib.undo()
            XCTAssertEqual(lib.recipe(for: b), beforeSync[b], "one undo on D takes B back too")
            XCTAssertEqual(lib.recipe(for: d), beforeSync[d])
            XCTAssertEqual(try SidecarStore(folder: folder).load(for: b)?.normalized, beforeSync[b]!.normalized,
                           "B's sidecar is written back by the undo")
            lib.redo()
            XCTAssertEqual(lib.recipe(for: b), afterSync[b], "redo brings the sync back on both")
            XCTAssertEqual(lib.recipe(for: d), afterSync[d])

            // A rating is not an undo step: ⌘Z after it undoes the last EDIT.
            lib.setRating(4, for: [d])
            lib.undo()
            XCTAssertEqual(lib.rating(for: d), 4, "undo does not take the rating back")
            XCTAssertEqual(lib.recipe(for: d), beforeSync[d], "it undoes the sync, the last edit")
            lib.redo()
            XCTAssertEqual(lib.recipe(for: d), afterSync[d])
            XCTAssertEqual(lib.recipe(for: b), afterSync[b])
        }

        // 8. Export the picks to a folder and to Photos.
        step("8. Export the picks"); do {
            lib.selectAll()
            XCTAssertEqual(lib.batchTargets, [a, b, d])
            let items = try await lib.exportItems(for: lib.batchTargets)
            XCTAssertEqual(items.map(\.recipe), [a, b, d].map { lib.recipe(for: $0) })

            var options = ExportOptions()
            options.suffix = "-edit"
            options.resize = .longSide(48)
            let queue = ExportQueue(remember: false, photos: writer, stagingDirectory: staging)
            queue.start(items, into: exportDir, options: options)
            await queue.wait()
            XCTAssertEqual(queue.state, .finished)
            XCTAssertEqual(queue.failures.map(\.message), [])
            let written = try FileManager.default.contentsOfDirectory(atPath: exportDir.path).sorted()
            XCTAssertEqual(written, ["beach 1-edit.jpg", "beach 2-edit.jpg", "city 1-edit.jpg"],
                           "the picks, with the suffix; the hidden reject is not exported")

            for (id, file) in zip([a, b, d], written) {
                let out = exportDir.appendingPathComponent(file)
                let (luma, w, h) = try meanLuma(of: out)
                XCTAssertEqual(max(w, h), 48, "\(file): long side resized")
                XCTAssertGreaterThan(w, h, "\(file): a landscape stays landscape")
                // The queue writes exactly what the exporter makes of the
                // photo's recipe, and that recipe's exposure is in the pixels
                // (brighter than the same recipe at exposure 0). Not "brighter
                // than neutral": + contrast darkens a photo (the pinned
                // `RendererTests.testContrastLeavesMiddleGrayWhereItIs`), so
                // city 1's +0.6 EV under A's +20 contrast comes out darker.
                let src = try XCTUnwrap(id.fileURL)
                let recipe = lib.recipe(for: id)
                let direct = try Exporter.export(src, recipe: recipe, into: referenceDir, options: options).url
                XCTAssertLessThanOrEqual(maxDiff(try rgba(out), try rgba(direct)), 1, "\(file): the queue wrote the recipe")
                var flat = recipe
                flat.set(.exposure, to: 0)
                let control = try Exporter.export(src, recipe: flat, into: neutralDir, options: options).url
                let (flatLuma, _, _) = try meanLuma(of: control)
                XCTAssertGreaterThan(luma, flatLuma + 5, "\(file): its exposure (\(recipe.value(of: .exposure))) is in the pixels")
            }

            queue.dismiss()
            queue.start(items, to: .photosLibrary(album: "Beach"), options: options)
            await queue.wait()
            XCTAssertEqual(queue.state, .finished)
            XCTAssertEqual(writer.imports.map(\.name), ["beach 1-edit.jpg", "beach 2-edit.jpg", "city 1-edit.jpg"])
            XCTAssertEqual(Set(writer.imports.map(\.album)), ["Beach"])
            XCTAssertEqual(writer.imports.map(\.pixelWidth), [48, 48, 48])
            XCTAssertEqual(queue.imported, ["fake-1", "fake-2", "fake-3"])
            let left = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
            XCTAssertEqual(left, [], "nothing left staged")
        }

        // 7b. Copy A's settings, paste them onto a photo of another folder.
        let session = Dictionary(uniqueKeysWithValues: ids.map { ($0, lib.recipe(for: $0)) })
        let sessionMarks = Dictionary(uniqueKeysWithValues: ids.map { ($0, lib.marks(for: $0)) })
        let harbour: Photo.ID
        step("7b. Copy and paste onto another folder"); do {
            lib.copySettings(from: a)
            lib.open(otherFolder)
            XCTAssertNil(lib.openError)
            XCTAssertEqual(lib.photos.map(\.name), ["harbour 1.jpg", "harbour 2.jpg"])
            XCTAssertEqual(lib.filter, .all, "a new folder opens unfiltered")
            let g = lib.photos[0].id
            var own = Recipe.neutral
            own.set(.exposure, to: -0.4)
            lib.setRecipe(own, for: g)
            lib.click(g)
            lib.requestPaste()
            let request = try XCTUnwrap(lib.syncRequest, "Paste Settings survives opening another folder")
            XCTAssertEqual(request.targets, [g])
            XCTAssertEqual(request.sourceName, "beach 1.jpg")
            XCTAssertEqual(request.mask, .grade, "the sheet reopens on the last mask")
            lib.syncRequest = nil
            XCTAssertEqual(lib.sync(request.source, mask: request.mask, to: request.targets), 1)
            let rg = lib.recipe(for: g)
            XCTAssertEqual(rg.value(of: .exposure), -0.4, "Grade keeps the photo's exposure")
            XCTAssertEqual(rg.value(of: .temperature), session[a]!.value(of: .temperature))
            XCTAssertEqual(rg.value(of: .contrast), session[a]!.value(of: .contrast))
            XCTAssertEqual(rg.value(of: .cropLeft), 0)
            XCTAssertFalse(lib.isEdited(lib.photos[1].id))
            lib.undo()
            XCTAssertEqual(lib.recipe(for: g), own, "the paste is one undo step")
            lib.redo()
            harbour = g
        }

        // 9. Reopen in a fresh Library and PresetLibrary: everything comes back.
        step("9. Reopen in a fresh Library"); do {
            let fresh = Library(rememberFolder: false)
            fresh.open(folder)
            XCTAssertEqual(fresh.photos.map(\.id), ids)
            for id in ids {
                XCTAssertEqual(fresh.recipe(for: id), session[id], "\(fresh.name(for: id)): recipe")
                XCTAssertEqual(fresh.marks(for: id), sessionMarks[id], "\(fresh.name(for: id)): marks")
                fresh.selection = id
                XCTAssertFalse(fresh.canUndo, "\(fresh.name(for: id)): a load is not an undo step")
                XCTAssertFalse(fresh.canRedo)
            }
            XCTAssertEqual(fresh.filter, .all)
            XCTAssertFalse(fresh.compare)
            XCTAssertFalse(fresh.showBefore)
            XCTAssertNil(fresh.sidecarError)
            XCTAssertTrue(fresh.unreadableSidecars.isEmpty)

            let freshPresets = PresetLibrary(store: PresetStore(directory: presetDir))
            XCTAssertNil(freshPresets.error)
            XCTAssertEqual(freshPresets.preset(named: "Beach Look")?.recipe, presets.preset(named: "Beach Look")?.recipe)
            XCTAssertEqual(Set(freshPresets.presets.map(\.name)), Set(presets.presets.map(\.name)))

            // Away to the other folder and back: both keep everything.
            fresh.open(otherFolder)
            XCTAssertEqual(fresh.recipe(for: harbour), lib.recipe(for: harbour))
            fresh.open(folder)
            for id in ids {
                XCTAssertEqual(fresh.recipe(for: id), session[id])
                XCTAssertEqual(fresh.marks(for: id), sessionMarks[id])
            }
            for name in Self.names {
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path),
                              "\(name): the original is still there")
            }
        }
    }

    // MARK: Seams the session found

    /// The Sync sheet is up for the first folder and ⌘O opens another (the
    /// File menu stays live under a sheet). Opening a source drops the
    /// pending request, and a sync that still names photos of another
    /// source changes nothing: before, the targets' sidecars were written
    /// into the NEW folder's `.photolab/` under their bare file names, onto
    /// the sidecar of a photo there with the same name.
    func testASyncSheetLeftOpenAcrossAFolderChangeCannotWriteIntoTheNewFolder() throws {
        try writePhoto(otherFolder.appendingPathComponent("beach 2.png"), width: 96, height: 64)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let (a, b) = (lib.photos[0].id, lib.photos[1].id)
        var look = Recipe.neutral
        look.set(.temperature, to: 40)
        lib.setRecipe(look, for: a)
        lib.click(a)
        lib.click(b, extending: true)
        lib.requestSync()
        let request = try XCTUnwrap(lib.syncRequest)
        XCTAssertEqual(request.targets, [b])

        lib.open(otherFolder)
        XCTAssertNil(lib.syncRequest, "opening another folder drops the pending sheet")
        XCTAssertEqual(lib.sync(request.source, mask: .look, to: request.targets), 0,
                       "a photo of another source is not a target")
        XCTAssertEqual(try sidecarCount(otherFolder), 0, "nothing written into the new folder")

        let reopened = Library(rememberFolder: false)
        reopened.open(otherFolder)
        let namesake = try XCTUnwrap(reopened.photos.first { $0.name == "beach 2.png" })
        XCTAssertFalse(reopened.isEdited(namesake.id), "the namesake in the new folder keeps its own (no) edit")
    }

    // MARK: Helpers

    /// A JPEG or PNG (by extension) of the shared synthetic ramp.
    private func writePhoto(_ url: URL, width: Int, height: Int) throws {
        let type = url.pathExtension == "png" ? UTType.png : UTType.jpeg
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, syntheticImage(width: width, height: height), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func sidecarCount(_ folder: URL) throws -> Int {
        let dir = folder.appendingPathComponent(".photolab", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.count
    }

    /// Mean of R, G and B (0…255) of `cg` redrawn into sRGB RGBA8.
    private func meanLuma(_ cg: CGImage) throws -> Double {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let m = meanRGB(try XCTUnwrap(ctx.makeImage()))
        return (m.r + m.g + m.b) / 3
    }

    private func meanLuma(_ image: NSImage) throws -> Double {
        try meanLuma(try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    }

    private func meanLuma(of file: URL) throws -> (Double, Int, Int) {
        let cg = try rgba(file)
        return (try meanLuma(cg), cg.width, cg.height)
    }

    /// The file decoded and redrawn into sRGB RGBA8 (what `meanRGB` and
    /// `maxDiff` read).
    private func rgba(_ file: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return try XCTUnwrap(ctx.makeImage())
    }
}
