import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Culling: a flag (pick / reject / none) and a rating 0–5 live in the
/// sidecar beside the recipe, are not edits (no undo step, never in a recipe,
/// preset or sync), keep a default recipe's file, and drive the grid filter
/// that every selection path respects.
@MainActor
final class CullingTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-culling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Writes a small PNG so `Library.scan` sees a real image.
    @discardableResult
    private func makePhoto(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private var sampleRecipe: Recipe {
        var r = Recipe.neutral
        r.set(.exposure, to: 0.75)
        r.set(.contrast, to: 15)
        return r
    }

    private func id(_ lib: Library, _ name: String) throws -> Photo.ID {
        try XCTUnwrap(lib.photos.first { $0.name == name }, "no photo \(name)").id
    }

    private func sidecarText(_ store: SidecarStore, _ photo: Photo.ID) throws -> String {
        try String(contentsOf: store.url(for: photo), encoding: .utf8)
    }

    // MARK: Round trip

    func testFlagAndRatingRoundTripWithANeutralRecipeThroughAFreshLibrary() throws {
        try makePhoto("a.png")
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let a = try id(lib, "a.png")
        lib.selection = a
        XCTAssertEqual(lib.marks(for: a), .none)
        XCTAssertFalse(store.exists(for: a), "an unmarked, unedited photo has no sidecar")

        lib.setFlag(.pick, for: [a])
        lib.setRating(3, for: [a])
        XCTAssertEqual(lib.flag(for: a), .pick)
        XCTAssertEqual(lib.rating(for: a), 3)
        XCTAssertEqual(lib.recipe(for: a), .neutral, "marks never enter the recipe")
        XCTAssertFalse(lib.isEdited(a), "a marked photo is not an edited photo")
        XCTAssertFalse(lib.canUndo, "a flag or rating is not an undo step")
        XCTAssertTrue(store.exists(for: a), "a default recipe with marks keeps its sidecar")
        let text = try sidecarText(store, a)
        XCTAssertTrue(text.contains("\"flag\" : \"pick\""), text)
        XCTAssertTrue(text.contains("\"rating\" : 3"), text)
        XCTAssertTrue(text.contains("\"recipe\""), "the recipe field stays beside the marks")

        // Quit and reopen: a fresh Library with nothing in memory.
        let again = Library(rememberFolder: false)
        again.open(folder)
        XCTAssertEqual(again.marks(for: a), Marks(flag: .pick, rating: 3))
        XCTAssertEqual(again.recipe(for: a), .neutral)
        XCTAssertFalse(again.isEdited(a))
        XCTAssertNil(again.sidecarError)

        // Clearing both removes the file: neutral and unmarked leaves no trace.
        again.setRating(0, for: [a])
        XCTAssertTrue(store.exists(for: a), "the flag alone still keeps the file")
        XCTAssertFalse(try sidecarText(store, a).contains("\"rating\""), "0 stars is omitted, not written as 0")
        again.setFlag(nil, for: [a])
        XCTAssertFalse(store.exists(for: a))
        XCTAssertEqual(again.marks(for: a), .none)
        XCTAssertNil(try store.read(for: a))

        // Out-of-range ratings clamp.
        again.setRating(9, for: [a])
        XCTAssertEqual(again.rating(for: a), 5)
        again.setRating(-2, for: [a])
        XCTAssertEqual(again.rating(for: a), 0)
        XCTAssertFalse(store.exists(for: a))
    }

    func testResetKeepsTheFlagAndAnUnmarkedResetRemovesTheFile() throws {
        try makePhoto("b.png")
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let b = try id(lib, "b.png")
        lib.selection = b
        lib.setRecipe(sampleRecipe, for: b)
        lib.setFlag(.pick, for: [b])
        lib.setRating(2, for: [b])
        XCTAssertTrue(lib.canUndo)

        lib.resetRecipe(for: b)
        XCTAssertEqual(lib.recipe(for: b), .neutral)
        XCTAssertFalse(lib.isEdited(b))
        XCTAssertEqual(lib.marks(for: b), Marks(flag: .pick, rating: 2), "Reset keeps the flag and the stars")
        XCTAssertTrue(store.exists(for: b), "the sidecar stays for the marks")
        XCTAssertEqual(try store.read(for: b)?.recipe.isDefault, true)

        let again = Library(rememberFolder: false)
        again.open(folder)
        XCTAssertEqual(again.marks(for: b), Marks(flag: .pick, rating: 2))
        XCTAssertEqual(again.recipe(for: b), .neutral)

        // Undo walks the recipe only; the marks are not in its history.
        lib.undo()
        XCTAssertEqual(lib.recipe(for: b), sampleRecipe)
        XCTAssertEqual(lib.marks(for: b), Marks(flag: .pick, rating: 2))
        lib.redo()
        XCTAssertEqual(lib.recipe(for: b), .neutral)
        XCTAssertEqual(lib.marks(for: b), Marks(flag: .pick, rating: 2))

        // Unmarked and neutral: the reset removes the file, as before.
        lib.setFlag(nil, for: [b])
        lib.setRating(0, for: [b])
        XCTAssertFalse(store.exists(for: b))
        lib.setRecipe(sampleRecipe, for: b)
        XCTAssertTrue(store.exists(for: b))
        lib.resetRecipe(for: b)
        XCTAssertFalse(store.exists(for: b))
    }

    func testMarksNeverEnterASyncAPresetOrCopiedSettings() throws {
        try makePhoto("c.png")
        try makePhoto("d.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let c = try id(lib, "c.png"), d = try id(lib, "d.png")
        lib.setRecipe(sampleRecipe, for: c)
        lib.setFlag(.pick, for: [c])
        lib.setRating(4, for: [c])
        lib.setFlag(.reject, for: [d])

        XCTAssertEqual(lib.sync(lib.recipe(for: c), mask: .everything, to: [d]), 1)
        XCTAssertEqual(lib.recipe(for: d), sampleRecipe.normalized)
        XCTAssertEqual(lib.marks(for: d), Marks(flag: .reject, rating: 0), "a sync carries the recipe only")
        XCTAssertEqual(lib.marks(for: c), Marks(flag: .pick, rating: 4))

        let preset = Preset(name: "Look", from: lib.recipe(for: c))
        lib.resetRecipe(for: d)
        XCTAssertEqual(lib.apply(preset, to: [d]), 1)
        XCTAssertEqual(lib.marks(for: d), Marks(flag: .reject, rating: 0), "a preset carries the recipe only")

        lib.copySettings(from: c)
        lib.selection = d
        lib.requestPaste()
        let request = try XCTUnwrap(lib.syncRequest)
        XCTAssertEqual(request.source, sampleRecipe)
        XCTAssertEqual(request.targets, [d])

        // The sidecar of the sync target records the recipe and its own flag.
        let store = SidecarStore(folder: folder)
        let doc = try XCTUnwrap(try store.read(for: d))
        XCTAssertEqual(doc.flag, .reject)
        XCTAssertNil(doc.rating)
    }

    // MARK: Filter

    func testFilterReturnsTheSubsetInFolderOrderAndBatchTargetsNeverIncludeAHiddenPhoto() throws {
        for n in ["a", "b", "c", "d", "e", "f"] { try makePhoto("\(n).png") }
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let a = try id(lib, "a.png"), b = try id(lib, "b.png"), c = try id(lib, "c.png")
        let d = try id(lib, "d.png"), e = try id(lib, "e.png"), f = try id(lib, "f.png")
        lib.setFlag(.pick, for: [a, d])
        lib.setFlag(.reject, for: [b, f])
        lib.setRating(5, for: [a])
        lib.setRating(3, for: [c])
        lib.setRating(1, for: [f])

        func names(_ filter: PhotoFilter) -> [String] {
            lib.filter = filter
            return lib.visiblePhotos.map(\.name)
        }
        XCTAssertEqual(names(.all), ["a.png", "b.png", "c.png", "d.png", "e.png", "f.png"])
        XCTAssertEqual(names(.picks), ["a.png", "d.png"])
        XCTAssertEqual(names(.unflagged), ["c.png", "e.png"])
        XCTAssertEqual(names(.rejected), ["b.png", "f.png"])
        XCTAssertEqual(names(.stars(1)), ["a.png", "c.png", "f.png"])
        XCTAssertEqual(names(.stars(3)), ["a.png", "c.png"])
        XCTAssertEqual(names(.stars(5)), ["a.png"])
        XCTAssertEqual(names(.stars(4)), ["a.png"])

        // Select All then filter: the hidden photos leave the selection.
        lib.filter = .all
        lib.selectAll()
        XCTAssertEqual(lib.batchTargets, [a, b, c, d, e, f])
        lib.filter = .picks
        XCTAssertEqual(lib.batchTargets, [a, d], "folder order, no hidden photo")
        XCTAssertEqual(lib.selectedIDs, [a, d])
        XCTAssertEqual(lib.selection, a)

        // Select All under a filter selects the visible photos only.
        lib.filter = .rejected
        lib.selectAll()
        XCTAssertEqual(lib.batchTargets, [b, f])
        XCTAssertEqual(lib.selection, b)

        // A shift-click range spans the visible photos only.
        lib.filter = .stars(1)
        lib.click(a)
        lib.click(f, extending: true)
        XCTAssertEqual(lib.batchTargets, [a, c, f])
        lib.filter = .stars(3)
        XCTAssertEqual(lib.batchTargets, [a, c])

        // A click on a hidden photo is ignored.
        lib.click(b)
        XCTAssertEqual(lib.selection, a)
        XCTAssertEqual(lib.batchTargets, [a, c])

        // Even an anchor forced onto a hidden photo (set by code, not by any
        // selection path) is no batch target: a hidden photo is never acted on.
        lib.selection = b
        XCTAssertEqual(lib.selectedIDs, [b])
        XCTAssertEqual(lib.batchTargets, [])
        lib.selectAll()
        XCTAssertEqual(lib.selection, a, "Select All moves a hidden anchor to the first visible photo")
        XCTAssertEqual(lib.batchTargets, [a, c])

        // A hidden anchor moves to the nearest visible photo after it.
        lib.filter = .all
        lib.selection = b
        lib.filter = .picks
        XCTAssertEqual(lib.selection, d)
        XCTAssertEqual(lib.batchTargets, [d])
        lib.filter = .all
        lib.selection = f
        lib.filter = .picks
        XCTAssertEqual(lib.selection, d, "nothing after f: the nearest before")

        // The arrows walk the visible list and clamp at its ends.
        lib.selection = a
        lib.select(offset: 1)
        XCTAssertEqual(lib.selection, d)
        lib.select(offset: 1)
        XCTAssertEqual(lib.selection, d)
        lib.select(offset: -1)
        XCTAssertEqual(lib.selection, a)
        lib.select(offset: -5)
        XCTAssertEqual(lib.selection, a)
        XCTAssertEqual(lib.visibleIndex, 0)
        XCTAssertEqual(lib.selectedIndex, 0)

        // Marking under a filter: rejecting a pick hides it and the anchor
        // moves on (culling flow), and the loupe is left when nothing is shown.
        lib.loupe = true
        lib.setFlag(.reject, for: lib.batchTargets)
        XCTAssertEqual(lib.visiblePhotos.map(\.name), ["d.png"])
        XCTAssertEqual(lib.selection, d)
        XCTAssertEqual(lib.batchTargets, [d])
        XCTAssertTrue(lib.loupe)
        lib.setFlag(nil, for: lib.batchTargets)
        XCTAssertTrue(lib.visiblePhotos.isEmpty)
        XCTAssertNil(lib.selection)
        XCTAssertEqual(lib.batchTargets, [])
        XCTAssertFalse(lib.loupe)
        lib.selectAll()
        XCTAssertEqual(lib.batchTargets, [])

        // Opening a folder resets the filter.
        lib.open(folder)
        XCTAssertEqual(lib.filter, .all)
        XCTAssertEqual(lib.visiblePhotos.count, 6)
        XCTAssertEqual(lib.flag(for: a), .reject, "the marks came back from the sidecars")
    }

    // MARK: Compatibility

    /// A sidecar written before flags and ratings existed (the shape in
    /// Documentation/Architecture.md, verbatim) still decodes: its recipe is
    /// read, its marks are none, and a flag added later keeps the recipe.
    func testChunkThreeSidecarStillDecodes() throws {
        let photo = try makePhoto("IMG_0001.JPG")
        let store = SidecarStore(folder: folder)
        let verbatim = """
        {
          "original" : "IMG_0001.JPG",
          "recipe" : {
            "adjustments" : [
              { "enabled" : true,  "kind" : "exposure",   "value" : 0.3 },
              { "enabled" : true,  "kind" : "highlights", "value" : -20 },
              { "enabled" : false, "kind" : "vignette",   "value" : -25 },
              { "enabled" : true,  "kind" : "cropLeft",   "value" : 5 }
            ]
          },
          "updated" : "2026-10-15T20:14:07Z",
          "version" : 1
        }
        """
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(verbatim.utf8).write(to: store.url(for: photo))

        let doc = try XCTUnwrap(try store.read(for: photo))
        XCTAssertNil(doc.flag)
        XCTAssertNil(doc.rating)
        XCTAssertEqual(doc.marks, .none)
        XCTAssertEqual(doc.recipe.value(of: .exposure), 0.3)
        XCTAssertEqual(doc.recipe.value(of: .highlights), -20)
        XCTAssertFalse(doc.recipe.isEnabled(.vignette))
        XCTAssertEqual(doc.recipe.value(of: .cropLeft), 5)
        XCTAssertEqual(try store.load(for: photo), doc.recipe)

        let all = store.loadAll(for: [photo])
        XCTAssertEqual(all.recipes[photo], doc.recipe)
        XCTAssertTrue(all.marks.isEmpty)
        XCTAssertTrue(all.unreadable.isEmpty)

        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let p = try id(lib, "IMG_0001.JPG")
        XCTAssertTrue(lib.isEdited(p))
        XCTAssertEqual(lib.marks(for: p), .none)
        XCTAssertNil(lib.sidecarError)

        // A flag set on it keeps the recipe and adds only the flag key.
        lib.setFlag(.pick, for: [p])
        let rewritten = try XCTUnwrap(try store.read(for: photo))
        XCTAssertEqual(rewritten.recipe, doc.recipe)
        XCTAssertEqual(rewritten.flag, .pick)
        XCTAssertNil(rewritten.rating)
        let text = try sidecarText(store, .file(photo))
        XCTAssertTrue(text.contains("\"flag\" : \"pick\""))
        XCTAssertFalse(text.contains("\"rating\""))

        // The recipe-only save path keeps the marks that are on disk.
        var r = doc.recipe
        r.set(.contrast, to: 10)
        try store.save(r, for: photo)
        XCTAssertEqual(try store.read(for: photo)?.flag, .pick)
        XCTAssertEqual(try store.read(for: photo)?.recipe, r)
    }
}
