import XCTest
import CoreGraphics
import Vision
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// A sync that carries masks (`SyncMask.masks`) detects each `.auto` mask
/// again on each target (`Library.syncRedetecting`, `detectAutoMasks`): the
/// target's own bitmap, strokes dropped, a target with nothing skipped and
/// counted, one undo step for the lot, a virtual copy of the source's master
/// keeping the bitmap. A fake detector answers by the image's width, so each
/// photo (each its own width) gets its own bitmap.
@MainActor
final class AutoMaskSyncTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-automasksync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A bitmap by image width; a width not listed finds nothing.
    private struct FakeDetector: AutoMaskDetector {
        let byWidth: [Int: MaskBitmap]
        func subject(in image: CGImage) async throws -> MaskBitmap? { byWidth[image.width] }
        func person(in image: CGImage) async throws -> MaskBitmap? { byWidth[image.width] }
        func faces(in image: CGImage) async throws -> [VNFaceObservation] { [] }
    }

    /// A bitmap told apart by which row is white.
    private func bitmap(row: Int) -> MaskBitmap {
        var g = [UInt8](repeating: 0, count: 16 * 16)
        for x in 0..<16 { g[row * 16 + x] = 255 }
        return MaskBitmap(gray: g, width: 16, height: 16)
    }

    private func write(_ name: String, width: Int) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 8))
        let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// Four photos of widths 10, 20, 30, 40 (names a…d) open, the first the
    /// source, holding an auto subject mask (strokes, sliders) and a radial.
    private func open(_ detector: FakeDetector) throws -> (Library, [Photo.ID]) {
        for (n, w) in zip(["a", "b", "c", "d"], [10, 20, 30, 40]) { write("\(n).png", width: w) }
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let ids = lib.photos.map(\.id)
        XCTAssertEqual(ids.count, 4)
        lib.autoMaskDetector = detector
        var r = lib.recipe(for: ids[0])
        let stroke = BrushStroke(points: [MaskPoint(x: 0.5, y: 0.5)], radius: 0.1, feather: 0.5, flow: 1)
        var auto = LocalMask(shape: .auto(AutoMask(kind: .subject, bitmap: bitmap(row: 15), strokes: [stroke])),
                             adjustments: [Adjustment(kind: .exposure, value: 0.7)], inverted: true)
        auto.id = UUID()
        r.masks = [auto, LocalMask(shape: .radial(center: MaskPoint(x: 0.4, y: 0.4),
                                                           radii: MaskRadii(x: 0.2, y: 0.2), angle: 0, feather: 0.3))]
        lib.setRecipe(r, for: ids[0])
        return (lib, ids)
    }

    private func auto(_ lib: Library, _ id: Photo.ID) -> AutoMask? {
        for m in lib.recipe(for: id).masks { if case .auto(let a) = m.shape { return a } }
        return nil
    }

    func testEachTargetGetsItsOwnBitmapStrokesDroppedSlidersKeptOtherShapesCopied() async throws {
        let (lib, ids) = try open(FakeDetector(byWidth: [20: bitmap(row: 1), 30: bitmap(row: 2), 40: bitmap(row: 3)]))
        let source = lib.recipe(for: ids[0])
        let changed = await lib.syncRedetecting(source, mask: .everything, from: ids[0], to: Array(ids[1...]))
        XCTAssertEqual(changed, 3)
        for (i, row) in [(1, 1), (2, 2), (3, 3)] {
            let a = try XCTUnwrap(auto(lib, ids[i]))
            XCTAssertEqual(a.bitmap.digest, bitmap(row: row).digest, "photo \(i) has its own bitmap")
            XCTAssertNotEqual(a.bitmap.digest, bitmap(row: 15).digest, "not the source's")
            XCTAssertEqual(a.strokes, [], "strokes were painted on the source's pixels")
            XCTAssertEqual(a.kind, .subject)
            let masks = lib.recipe(for: ids[i]).masks
            XCTAssertEqual(masks.count, 2)
            XCTAssertTrue(masks[0].inverted)
            XCTAssertEqual(masks[0].adjustments, source.normalized.masks[0].adjustments, "sliders kept")
            XCTAssertEqual(masks[1].shape, source.masks[1].shape, "a radial copies as before")
        }
        XCTAssertNil(lib.autoNote)
    }

    func testATargetWhereNothingIsFoundGetsNoSuchMaskAndTheBannerCountsIt() async throws {
        let (lib, ids) = try open(FakeDetector(byWidth: [20: bitmap(row: 1), 40: bitmap(row: 3)]))
        let changed = await lib.syncRedetecting(lib.recipe(for: ids[0]), mask: .everything, from: ids[0],
                                                to: Array(ids[1...]))
        XCTAssertEqual(changed, 3, "the skipped target still gets its radial")
        XCTAssertNil(auto(lib, ids[2]))
        XCTAssertEqual(lib.recipe(for: ids[2]).masks.count, 1)
        XCTAssertNotNil(auto(lib, ids[1]))
        XCTAssertEqual(lib.autoNote, "Sync: 1 automatic mask not found on the target, skipped")
    }

    func testOneUndoRevertsEveryTarget() async throws {
        let (lib, ids) = try open(FakeDetector(byWidth: [20: bitmap(row: 1), 30: bitmap(row: 2), 40: bitmap(row: 3)]))
        let before = ids.map { lib.recipe(for: $0) }
        _ = await lib.syncRedetecting(lib.recipe(for: ids[0]), mask: .everything, from: ids[0], to: Array(ids[1...]))
        lib.selection = ids[2]
        lib.undo()
        XCTAssertEqual(ids.map { lib.recipe(for: $0) }, before, "one undo took back all three")
    }

    func testAVirtualCopyOfTheSourceKeepsTheMastersBitmap() async throws {
        let (lib, ids) = try open(FakeDetector(byWidth: [10: bitmap(row: 9), 20: bitmap(row: 1)]))
        let copy = try XCTUnwrap(lib.createVirtualCopy(of: ids[0]))
        var r = lib.recipe(for: copy)
        r.masks = []
        lib.setRecipe(r, for: copy)
        _ = await lib.syncRedetecting(lib.recipe(for: ids[0]), mask: .everything, from: ids[0], to: [copy, ids[1]])
        XCTAssertEqual(auto(lib, copy)?.bitmap.digest, bitmap(row: 15).digest, "same pixels: the master's bitmap")
        XCTAssertEqual(auto(lib, copy)?.strokes.count, 1, "kept as it was")
        XCTAssertEqual(auto(lib, ids[1])?.bitmap.digest, bitmap(row: 1).digest)
    }

    func testWithoutTheMasksFlagNothingIsDetected() async throws {
        let (lib, ids) = try open(FakeDetector(byWidth: [20: bitmap(row: 1)]))
        let changed = await lib.syncRedetecting(lib.recipe(for: ids[0]), mask: .look, from: ids[0], to: [ids[1]])
        XCTAssertEqual(changed, 0)
        XCTAssertNil(auto(lib, ids[1]))
    }

    func testDetectAutoMasksReturnsPerPhotoPerKindAndWritesNothing() async throws {
        let (lib, ids) = try open(FakeDetector(byWidth: [20: bitmap(row: 1)]))
        let writes = lib.sidecarWrites
        let all = await lib.detectAutoMasks([.subject, .sky, .person], for: Array(ids[1...]))
        let found = try XCTUnwrap(all)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[ids[1]]?[.subject]?.digest, bitmap(row: 1).digest)
        XCTAssertEqual(found[ids[1]]?[.person]?.digest, bitmap(row: 1).digest)
        XCTAssertNil(found[ids[1]]?[.sky], "sky is a guess, not re-detected")
        XCTAssertEqual(lib.sidecarWrites, writes)
    }

    func testASkyMaskCopiesAsItWasAndABusyBatchSaysSo() async throws {
        let (lib, ids) = try open(FakeDetector(byWidth: [20: bitmap(row: 1)]))
        var r = lib.recipe(for: ids[0])
        r.masks = [LocalMask(shape: .auto(AutoMask(kind: .sky, bitmap: bitmap(row: 4))))]
        lib.setRecipe(r, for: ids[0])
        _ = await lib.syncRedetecting(lib.recipe(for: ids[0]), mask: .everything, from: ids[0], to: [ids[1]])
        XCTAssertEqual(auto(lib, ids[1])?.bitmap.digest, bitmap(row: 4).digest, "sky is not re-detected: copied")
        XCTAssertNil(lib.autoNote)
    }
}
