import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// The crop's aspect lock (`CropMath.Aspect`, `CropMath.drag(_:from:by:fit:ratio:)`,
/// `CropMath.refit`): every preset holds its ratio to within a pixel of a
/// 24 MP frame after any corner drag, the swap turns it on its side, a
/// refit stays inside the image and the sliders' bound, and picking an
/// aspect in the library is one undo step and one sidecar write.
@MainActor
final class AspectMathTests: XCTestCase {
    /// A 24 MP frame, landscape and portrait.
    private let frames = [CGSize(width: 6000, height: 4000), CGSize(width: 4000, height: 6000)]

    /// Every locked aspect: each preset but Free, each way round.
    private var lockedAspects: [CropMath.Aspect] {
        CropMath.Aspect.Preset.allCases.filter { $0 != .free }.flatMap { p in
            [false, true].map { CropMath.Aspect(preset: p, swapped: $0) }
        }
    }

    /// The crop's kept size in pixels of `frame`.
    private func pixels(_ c: CropMath.Crop, _ frame: CGSize) -> CGSize {
        CGSize(width: c.rect.width * frame.width, height: c.rect.height * frame.height)
    }

    private func assertInBounds(_ c: CropMath.Crop, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for edge in CropMath.Edge.allCases {
            XCTAssertGreaterThanOrEqual(c[edge], 0, "\(what): \(edge) inside the image", file: file, line: line)
            XCTAssertLessThanOrEqual(c[edge], CropMath.maxInset + 1e-9, "\(what): \(edge) within the slider's bound",
                                     file: file, line: line)
        }
    }

    func testEachRatioHoldsWithinOnePixelAt24MPAfterACornerDrag() {
        let drags = [CGSize(width: 300, height: -50), CGSize(width: -800, height: -800), CGSize(width: 2000, height: 2000),
                     CGSize(width: -50, height: 400), CGSize(width: 120, height: 90), CGSize(width: -2000, height: 30)]
        for frame in frames {
            // The fit frame the overlay lays the photo out in: same aspect, points.
            let fit = ZoomMath.fitRect(frame: frame, pane: CGSize(width: 1000, height: 700)).size
            for aspect in lockedAspects {
                let ratio = try! XCTUnwrap(aspect.ratio(frame: frame))
                let k = try! XCTUnwrap(aspect.normalized(frame: fit))
                // The overlay's fit and the frame agree on the ratio.
                XCTAssertEqual(k, try! XCTUnwrap(aspect.normalized(frame: frame)), accuracy: 1e-3)
                let start = CropMath.refit(.none, ratio: k)
                for handle in CropMath.Handle.allCases where handle.isCorner {
                    for t in drags {
                        let what = "\(aspect.title) \(handle) \(t) on \(frame)"
                        let c = CropMath.drag(handle, from: start, by: t, fit: fit, ratio: k)
                        let px = pixels(c, frame)
                        XCTAssertEqual(px.width, ratio * px.height, accuracy: 1, what)
                        assertInBounds(c, what)
                        for edge in CropMath.Edge.allCases where !handle.edges.contains(edge) {
                            XCTAssertEqual(c[edge], start[edge], "\(what): the opposite corner stays")
                        }
                        // Through the recipe (percent) and the renderer's own cut.
                        var r = Recipe.neutral
                        CropMath.write(c, edges: CropMath.Edge.allCases, into: &r)
                        let back = pixels(CropMath.crop(of: r), frame)
                        XCTAssertEqual(back.width, ratio * back.height, accuracy: 1, "\(what), read back")
                        let source = CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: frame))
                        let cut = Renderer.shared.apply(r, to: source).extent
                        XCTAssertEqual(cut.width, px.width, accuracy: 2, "\(what): what the renderer cuts")
                        XCTAssertEqual(cut.height, px.height, accuracy: 2, "\(what): what the renderer cuts")
                    }
                }
            }
        }
    }

    /// A corner drag under a lock still follows the pointer, sized by
    /// whichever axis it moved further: inward shrinks the crop, outward
    /// grows it, and the opposite corner stays.
    func testALockedCornerFollowsThePointer() {
        let fit = CGSize(width: 900, height: 600)
        let k = CropMath.Aspect(preset: .square).normalized(frame: fit)!
        let base = CropMath.refit(CropMath.Crop(left: 0.3, top: 0.1, right: 0.2, bottom: 0.1), ratio: k)
        XCTAssertTrue(CropMath.holds(base, ratio: k))
        XCTAssertEqual(base.rect.midX, 0.55, accuracy: 1e-12, "the refit keeps the crop's centre")
        // 60 points of 900 across, 10 of 600 down: the horizontal move wins.
        let inward = CropMath.drag(.bottomRight, from: base, by: CGSize(width: -60, height: -10), fit: fit, ratio: k)
        XCTAssertEqual(inward.rect.width, base.rect.width - 60.0 / 900, accuracy: 1e-9)
        XCTAssertTrue(CropMath.holds(inward, ratio: k))
        // 5 across, 30 down: the vertical move wins.
        let outward = CropMath.drag(.bottomRight, from: inward, by: CGSize(width: 5, height: 30), fit: fit, ratio: k)
        XCTAssertEqual(outward.rect.height, inward.rect.height + 30.0 / 600, accuracy: 1e-9)
        XCTAssertGreaterThan(outward.rect.width, inward.rect.width)
        XCTAssertEqual(outward.left, inward.left, accuracy: 1e-12, "the top-left corner is the anchor")
        XCTAssertEqual(outward.top, inward.top, accuracy: 1e-12)
    }

    func testTheSwapFlipsTheRatio() {
        let frame = CGSize(width: 6000, height: 4000)
        for p in CropMath.Aspect.Preset.allCases {
            let a = CropMath.Aspect(preset: p), b = CropMath.Aspect(preset: p, swapped: true)
            guard let ra = a.ratio(frame: frame) else {
                XCTAssertEqual(p, .free)
                XCTAssertFalse(a.canSwap)
                XCTAssertNil(a.normalized(frame: frame))
                continue
            }
            let rb = try! XCTUnwrap(b.ratio(frame: frame))
            XCTAssertEqual(rb, 1 / ra, accuracy: 1e-12, "\(p)")
            XCTAssertEqual(a.canSwap, p != .square, "\(p)")
        }
        XCTAssertEqual(CropMath.Aspect(preset: .original).ratio(frame: frame)!, 1.5, accuracy: 1e-12)
        XCTAssertEqual(CropMath.Aspect(preset: .original, swapped: true).ratio(frame: frame)!, 4000.0 / 6000, accuracy: 1e-12)
        XCTAssertEqual(CropMath.Aspect(preset: .fourFive).title, "4:5")
        XCTAssertEqual(CropMath.Aspect(preset: .fourFive, swapped: true).title, "5:4")
        XCTAssertEqual(CropMath.Aspect(preset: .sixteenNine, swapped: true).title, "9:16")
        XCTAssertEqual(CropMath.Aspect(preset: .threeTwo).ratio(frame: frame)!, 1.5, accuracy: 1e-12)

        // A 3:2 crop swapped to 2:3 is portrait in pixels after the refit.
        let k32 = CropMath.Aspect(preset: .threeTwo).normalized(frame: frame)!
        let k23 = CropMath.Aspect(preset: .threeTwo, swapped: true).normalized(frame: frame)!
        let land = CropMath.refit(.none, ratio: k32)
        let port = CropMath.refit(land, ratio: k23)
        XCTAssertEqual(pixels(land, frame).width / pixels(land, frame).height, 1.5, accuracy: 1e-9)
        XCTAssertEqual(pixels(port, frame).width / pixels(port, frame).height, 2.0 / 3, accuracy: 1e-9)
    }

    func testARefitStaysInsideTheImage() {
        let starts = [CropMath.Crop.none,
                      CropMath.Crop(left: 0.4, top: 0, right: 0, bottom: 0.4),
                      CropMath.Crop(left: 0, top: 0.35, right: 0.4, bottom: 0),
                      CropMath.Crop(left: 0.1, top: 0.2, right: 0.3, bottom: 0.05),
                      CropMath.Crop(left: 0.4, top: 0.4, right: 0.4, bottom: 0.4)]
        for frame in frames {
            for aspect in lockedAspects {
                let k = aspect.normalized(frame: frame)!
                let ratio = aspect.ratio(frame: frame)!
                for s in starts {
                    let what = "\(aspect.title) from \(s) on \(frame)"
                    let c = CropMath.refit(s, ratio: k)
                    assertInBounds(c, what)
                    XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -1e-12, dy: -1e-12).contains(c.rect), what)
                    let px = pixels(c, frame)
                    XCTAssertEqual(px.width, ratio * px.height, accuracy: 1, what)
                    XCTAssertTrue(CropMath.holds(c, ratio: k), what)
                    // The largest it can be: one axis is at its limit.
                    XCTAssertTrue(c.rect.width > 1 - 1e-9 || c.rect.height > 1 - 1e-9
                                  || c.left < 1e-9 || c.right < 1e-9 || c.top < 1e-9 || c.bottom < 1e-9,
                                  "\(what): touches the image edge")
                }
            }
        }
        // A centred crop keeps its centre.
        let k = CropMath.Aspect(preset: .square).normalized(frame: frames[0])!
        let c = CropMath.refit(CropMath.Crop(left: 0.1, top: 0.1, right: 0.1, bottom: 0.1), ratio: k)
        XCTAssertEqual(c.rect.midX, 0.5, accuracy: 1e-12)
        XCTAssertEqual(c.rect.midY, 0.5, accuracy: 1e-12)
        XCTAssertEqual(c.rect.height, 1, accuracy: 1e-12, "1:1 on 3:2 fills the height")
    }

    /// Under a lock the overlay shows the four corners alone, and an edge
    /// handle does not move the crop; Free keeps all eight and the free drag.
    func testEdgeHandlesAreHiddenAndInertUnderALock() {
        XCTAssertEqual(CropMath.handles(locked: true), [.topLeft, .topRight, .bottomRight, .bottomLeft])
        XCTAssertEqual(CropMath.handles(locked: false), CropMath.Handle.allCases)
        let fit = CGSize(width: 900, height: 600)
        let k = CropMath.Aspect(preset: .original).normalized(frame: fit)!
        XCTAssertEqual(k, 1, accuracy: 1e-12, "Original is the frame's own shape")
        XCTAssertEqual(CropMath.drag(.left, from: .none, by: CGSize(width: 90, height: 0), fit: fit, ratio: k), .none)
        XCTAssertEqual(CropMath.drag(.left, from: .none, by: CGSize(width: 90, height: 0), fit: fit, ratio: nil),
                       CropMath.drag(.left, from: .none, by: CGSize(width: 90, height: 0), fit: fit))
    }

    // MARK: Through the library

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-aspect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makePhoto(_ name: String) throws {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// Picking a ratio refits the crop at once through `setRecipe` (one undo
    /// step, the sidecar written), a locked corner drag holds it and is one
    /// step too, and Free or a crop that already holds the ratio changes nothing.
    func testPickingAnAspectRefitsAsOneUndoStepAndALockedDragHoldsIt() throws {
        try makePhoto("aspect.png")
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let photo = try XCTUnwrap(lib.photos.first).id
        lib.selection = photo
        lib.loupe = true
        lib.cropMode = true
        let frame = CGSize(width: 6000, height: 4000)
        var before = Recipe.neutral
        before.set(.exposure, to: 0.4)
        lib.setRecipe(before, for: photo)

        lib.setCropAspect(CropMath.Aspect(preset: .fourFive), frame: frame, for: photo)
        XCTAssertEqual(lib.cropAspect, CropMath.Aspect(preset: .fourFive))
        let fitted = lib.recipe(for: photo)
        let px = pixels(CropMath.crop(of: fitted), frame)
        XCTAssertEqual(px.width / px.height, 0.8, accuracy: 1e-9)
        XCTAssertEqual(fitted.value(of: .exposure), 0.4, "the look is kept")
        XCTAssertEqual(try store.load(for: photo), fitted, "written at once")
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), before, "the refit is one undo step")
        lib.redo()

        // Picking the same ratio again, or Free, writes nothing.
        lib.setCropAspect(CropMath.Aspect(preset: .fourFive), frame: frame, for: photo)
        lib.setCropAspect(.free, frame: frame, for: photo)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), before, "no step was added")
        lib.redo()

        // The swap: 5:4, landscape.
        lib.setCropAspect(CropMath.Aspect(preset: .fourFive), frame: frame, for: photo)
        lib.swapCropAspect(frame: frame, for: photo)
        XCTAssertEqual(lib.cropAspect.title, "5:4")
        let swapped = pixels(CropMath.crop(of: lib.recipe(for: photo)), frame)
        XCTAssertEqual(swapped.width / swapped.height, 1.25, accuracy: 1e-9)

        // A corner drag under the lock, over a fit frame of the photo's shape.
        let fit = CGSize(width: 900, height: 600)
        for x in stride(from: -10.0, through: -80.0, by: -10.0) {
            lib.dragCrop(.bottomRight, by: CGSize(width: x, height: x / 3), fit: fit, for: photo)
        }
        lib.endCropDrag(photo)
        let dragged = pixels(CropMath.crop(of: lib.recipe(for: photo)), frame)
        XCTAssertEqual(dragged.width, 1.25 * dragged.height, accuracy: 1)
        XCTAssertLessThan(dragged.width, swapped.width)
        XCTAssertEqual(try store.load(for: photo), lib.recipe(for: photo))
        lib.undo()
        XCTAssertEqual(pixels(CropMath.crop(of: lib.recipe(for: photo)), frame), swapped, "the drag is one step")

        // The lock is tool state: kept across a reopen of the photo, never in the recipe.
        lib.setCropAspect(.free, frame: frame, for: photo)
        XCTAssertFalse(lib.cropAspect.isLocked)
    }
}
