import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// View > My Edits (`MyEditsRow.rows`, `EditSummary`, `MyEditsSheet`): the
/// open source's edited photos with their slider values and the habits over
/// them. Read only. Every file is synthetic in a temp folder.
@MainActor
final class MyEditsTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-myedits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writePNG(_ name: String) throws {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            folder.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func recipe(_ values: [(AdjustmentKind, Double)], disabled: [(AdjustmentKind, Double)] = []) -> Recipe {
        var r = Recipe.neutral
        for (k, v) in values { r.set(k, to: v) }
        for (k, v) in disabled { r.set(k, to: v); r.setEnabled(k, false) }
        return r
    }

    /// a: exposure +0.5, contrast 20, saturation 40 switched off, one mask.
    /// b: exposure +1.5, sharpening 30. c: only a disabled entry. d: no sidecar.
    private func makeLibrary() throws -> Library {
        for n in ["a.png", "b.png", "c.png", "d.png"] { try writePNG(n) }
        let store = SidecarStore(folder: folder)
        var a = recipe([(.exposure, 0.5), (.contrast, 20)], disabled: [(.saturation, 40)])
        a.masks = [LocalMask(shape: .linear(start: MaskPoint(x: 0.5, y: 0.2), end: MaskPoint(x: 0.5, y: 0.8)),
                             adjustments: [Adjustment(kind: .exposure, value: 0.4)])]
        try store.save(a, for: .file(folder.appendingPathComponent("a.png")))
        try store.save(recipe([(.exposure, 1.5), (.sharpening, 30)]), for: .file(folder.appendingPathComponent("b.png")))
        try store.save(recipe([], disabled: [(.vibrance, 50)]), for: .file(folder.appendingPathComponent("c.png")))
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        return lib
    }

    func testRowsListTheEditedPhotosWithTheirValuesAndMasks() throws {
        let lib = try makeLibrary()
        let rows = MyEditsRow.rows(photos: lib.photos, recipes: lib.recipes)
        XCTAssertEqual(rows.map(\.photo.caption), ["a.png", "b.png"], "c has only a disabled entry, d is unedited")
        let a = rows[0]
        XCTAssertEqual(a.groups.map(\.section), [.basic])
        XCTAssertEqual(a.groups[0].entries.map(\.kind), [.exposure, .contrast])
        XCTAssertEqual(a.groups[0].entries.map(\.text), [AdjustmentKind.exposure.format(0.5), AdjustmentKind.contrast.format(20)])
        XCTAssertEqual(a.masksText, "1 mask")
        XCTAssertFalse(a.groups.flatMap(\.entries).contains { $0.kind == .saturation }, "a disabled entry is not shown")
        let b = rows[1]
        XCTAssertEqual(b.groups.map(\.section), [.basic, .detail])
        XCTAssertEqual(b.groups[1].entries.map(\.text), [AdjustmentKind.sharpening.format(30)])
        XCTAssertNil(b.masksText)
    }

    func testAVirtualCopyIsItsOwnRow() throws {
        let lib = try makeLibrary()
        let master = try XCTUnwrap(lib.photos.first { $0.caption == "b.png" }).id
        let copy = try XCTUnwrap(lib.createVirtualCopy(of: master))
        lib.setRecipe(recipe([(.exposure, -1)]), for: copy)
        let rows = MyEditsRow.rows(photos: lib.photos, recipes: lib.recipes)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.id).filter { $0.master == master }.count, 2)
        let copyRow = try XCTUnwrap(rows.first { $0.id == copy })
        XCTAssertEqual(copyRow.groups[0].entries.map(\.text), [AdjustmentKind.exposure.format(-1)])
        XCTAssertTrue(copyRow.photo.caption.contains("Copy"))
    }

    func testTheSummaryCountsPhotosAndTakesTheMedian() throws {
        let lib = try makeLibrary()
        let rows = MyEditsRow.rows(photos: lib.photos, recipes: lib.recipes)
        let s = EditSummary(recipes: rows.map(\.recipe))
        XCTAssertEqual(s.editedPhotos, 2)
        let first = try XCTUnwrap(s.habits.first)
        XCTAssertEqual(first.kind, .exposure, "used on two photos: most used first")
        XCTAssertEqual(first.photos, 2)
        XCTAssertEqual(first.median, 1.0, accuracy: 1e-9, "median of 0.5 and 1.5")
        XCTAssertEqual(s.habits.map(\.kind), [.exposure, .contrast, .sharpening], "ties keep the panel order")
        XCTAssertFalse(s.habits.contains { $0.kind == .saturation || $0.kind == .vibrance }, "disabled entries are not habits")
        // Odd count: the middle value.
        let three = EditSummary(recipes: [1.0, 5.0, 2.0].map { recipe([(.exposure, $0)]) })
        XCTAssertEqual(three.habits.first?.median, 2.0)
        // Straight from the library, over the same rows.
        XCTAssertEqual(lib.myEdits.summary, s)
    }

    func testOpeningARowSelectsThePhotoAndTheLoupeAndWritesNothing() throws {
        let lib = try makeLibrary()
        let before = try Data(contentsOf: SidecarStore(folder: folder).url(for: try XCTUnwrap(lib.photos.first { $0.caption == "a.png" }).id))
        lib.myEditsSheet = true
        let id = try XCTUnwrap(lib.myEdits.rows.first).id
        lib.openFromMyEdits(id)
        XCTAssertEqual(lib.selection, id)
        XCTAssertTrue(lib.loupe)
        XCTAssertFalse(lib.myEditsSheet)
        XCTAssertEqual(try Data(contentsOf: SidecarStore(folder: folder).url(for: id)), before)
    }

    func testOpeningAHiddenRowClearsTheFilterSoTheAnchorIsVisible() throws {
        let lib = try makeLibrary()
        let id = try XCTUnwrap(lib.myEdits.rows.first).id
        lib.searchText = "zzz-no-match"
        XCTAssertFalse(lib.isVisible(id))
        lib.openFromMyEdits(id)
        XCTAssertTrue(lib.isVisible(id))
        XCTAssertEqual(lib.selection, id)
        XCTAssertEqual(lib.batchTargets, [id])
    }

    func testTheCommandOpensTheSheetOnlyWithASource() {
        let empty = Library(rememberFolder: false)
        let ctx = CommandContext(library: empty)
        XCTAssertFalse(AppCommand.command(.myEdits).isEnabled(ctx))
        XCTAssertNil(AppCommand.command(.myEdits).key)
    }
}
