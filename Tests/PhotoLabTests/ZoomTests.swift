import XCTest
import CoreImage
import ImageIO
@testable import PhotoLab

/// 1:1 zoom in `PreviewModel`: the window is the one chain over the whole
/// full-resolution image with the output cut to the view's region, so it
/// equals the same crop of a full-resolution (export) render, at a centre
/// and at a corner, with crop and rotate applied first; a region step fits
/// the frame budget; the full-resolution master is decoded on the first 1:1
/// of a photo and dropped when the photo changes; the histogram stays the
/// fit frame's.
@MainActor
final class ZoomTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-zoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writePNG(_ name: String, width: Int = 640, height: Int = 480) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, syntheticImage(width: width, height: height), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ seconds: Double = 30, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func set(_ r: inout Recipe, _ kind: AdjustmentKind, _ value: Double) {
        r.set(kind, to: value)
        r.setEnabled(kind, true)
    }

    /// Clarity, sharpening and vignette on: the three stages whose radii are
    /// fractions of the whole image, so a render of a cropped input differs.
    private var spatial: Recipe {
        var r = Recipe.neutral
        set(&r, .clarity, 60)
        set(&r, .sharpening, 80)
        set(&r, .vignette, -60)
        set(&r, .exposure, 0.3)
        return r
    }

    /// Largest per-channel difference between `crop` and the pixels of
    /// `full` under `rect` (top-left, whole pixels), read in place.
    private func maxDiff(_ crop: CGImage, in full: CGImage, at rect: CGRect) -> Int {
        guard let dc = crop.dataProvider?.data, let pc = CFDataGetBytePtr(dc),
              let df = full.dataProvider?.data, let pf = CFDataGetBytePtr(df),
              crop.width == Int(rect.width), crop.height == Int(rect.height),
              Int(rect.maxX) <= full.width, Int(rect.maxY) <= full.height else { return Int.max }
        let ox = Int(rect.minX), oy = Int(rect.minY)
        var worst = 0
        for y in 0..<crop.height {
            for x in 0..<crop.width {
                for c in 0..<3 {
                    let a = Int(pc[y * crop.bytesPerRow + x * 4 + c])
                    let b = Int(pf[(y + oy) * full.bytesPerRow + (x + ox) * 4 + c])
                    worst = max(worst, abs(a - b))
                }
            }
        }
        return worst
    }

    // MARK: The window

    func testRegionRectSlidesInsideTheFrame() {
        let frame = CGSize(width: 6000, height: 4000)
        let size = CGSize(width: 1200, height: 800)
        XCTAssertEqual(Renderer.Region(center: CGPoint(x: 0.5, y: 0.5), size: size).rect(in: frame),
                       CGRect(x: 2400, y: 1600, width: 1200, height: 800))
        XCTAssertEqual(Renderer.Region(center: .zero, size: size).rect(in: frame),
                       CGRect(x: 0, y: 0, width: 1200, height: 800), "a corner centre shows the corner")
        XCTAssertEqual(Renderer.Region(center: CGPoint(x: 1, y: 1), size: size).rect(in: frame),
                       CGRect(x: 4800, y: 3200, width: 1200, height: 800))
        XCTAssertEqual(Renderer.Region(center: CGPoint(x: 0.5, y: 0.5), size: CGSize(width: 9000, height: 900)).rect(in: frame),
                       CGRect(x: 0, y: 1550, width: 6000, height: 900), "a window wider than the frame is the frame's width")
        XCTAssertEqual(PreviewZoom.actual(center: CGPoint(x: -1, y: 2)).clamped, .actual(center: CGPoint(x: 0, y: 1)))
    }

    /// The pixel-for-pixel gate: through the model, on a synthetic 24 MP
    /// photo, the 1:1 window at a centre and at a corner equals the same
    /// crop of a full-resolution render of the whole image (the export's
    /// input and chain). Then again with crop and rotate on, so the centre
    /// is in the rendered frame's coordinates; that pass uses moderate
    /// clarity and sharpening, because Core Image's result depends on the
    /// area it is asked for by up to 1 level, and strong sharpening across
    /// the synthetic photo's hard edges can lift that to 2 to 4 on a few
    /// edge pixels (Architecture, The loupe at 1:1).
    func testOneToOneRegionEqualsTheSameCropOfAFullResolutionRender() async throws {
        let url = try bench24MPImageURL()
        var cropped = spatial
        set(&cropped, .clarity, 30)
        set(&cropped, .sharpening, 40)
        set(&cropped, .cropLeft, 10)
        set(&cropped, .cropTop, 5)
        set(&cropped, .rotate, 3)
        let view = CGSize(width: 1200, height: 800)

        let preview = PreviewModel()
        preview.load(url)
        await preview.awaitLoad()
        for recipe in [spatial, cropped] {
            let full = try XCTUnwrap(Renderer.shared.render(try XCTUnwrap(Renderer.fullResolution(url)), recipe: recipe)).image
            for center in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.02, y: 0.97)] {
                preview.request(url: url, recipe: recipe, maxPixelSize: 1200, viewPixelSize: view)
                preview.setZoom(.actual(center: center))
                let expected = Renderer.Region(center: center, size: view).rect(in: CGSize(width: full.width, height: full.height))
                await waitUntil { preview.zoomRegion == expected && preview.zoomURL == url }
                let window = try XCTUnwrap(preview.zoomImage, "a 1:1 window lands at \(center)")
                XCTAssertEqual(preview.zoomRegion, expected)
                XCTAssertEqual(preview.zoomFrameSize, CGSize(width: full.width, height: full.height),
                               "the frame the window is cut from is the full-resolution rendered frame")
                XCTAssertEqual(window.width, 1200, "one image pixel per view pixel")
                XCTAssertEqual(window.height, 800)
                let d = maxDiff(window, in: full, at: expected)
                XCTAssertLessThanOrEqual(d, 1, "the 1:1 window at \(center) is the export's pixels (maxDiff \(d))")
            }
        }
        XCTAssertEqual(preview.fullResolutionSize, CGSize(width: 6000, height: 4000))
        let master = try XCTUnwrap(Renderer.previewMaster(url, maxPixelSize: PreviewModel.masterPixelSize))
        let fit = try XCTUnwrap(Renderer.shared.render(master, recipe: cropped, maxPixelSize: 1200)).image
        await waitUntil { preview.image.map { PhotoLabTests.maxDiff($0, fit) == 0 } ?? false }
        let shown = try XCTUnwrap(preview.image)
        XCTAssertEqual(PhotoLabTests.maxDiff(shown, fit), 0, "`image` stays the fit frame")
        let expected = try XCTUnwrap(Histogram.compute(shown))
        let same = { (h: Histogram?) in h.map { $0.pixelCount == expected.pixelCount && $0.luminance == expected.luminance && $0.red == expected.red } ?? false }
        await waitUntil { same(preview.histogram) }
        XCTAssertTrue(same(preview.histogram), "the histogram is the fit frame's, never the window's")
    }

    // MARK: Lifecycle

    func testTheFullResolutionMasterIsDecodedOnTheFirstOneToOneAndDroppedWhenThePhotoChanges() async throws {
        let a = try writePNG("a.png", width: 1600, height: 1200)
        let b = try writePNG("b.png", width: 1200, height: 900)
        let preview = PreviewModel()
        preview.load(a)
        preview.request(url: a, recipe: spatial, maxPixelSize: 400, viewPixelSize: CGSize(width: 400, height: 300))
        await preview.awaitLoad()
        await waitUntil { preview.image != nil }
        XCTAssertNil(preview.fullResolutionURL, "fit decodes no full-resolution master")

        preview.setZoom(.actual(center: CGPoint(x: 0.5, y: 0.5)))
        await preview.awaitFullResolution()
        await waitUntil { preview.zoomImage != nil }
        XCTAssertEqual(preview.fullResolutionURL, a)
        XCTAssertEqual(preview.fullResolutionSize, CGSize(width: 1600, height: 1200))
        XCTAssertEqual(preview.zoomURL, a)

        // Back to fit: the window goes, the master stays for this photo.
        preview.setZoom(.fit)
        XCTAssertNil(preview.zoomImage)
        XCTAssertNil(preview.zoomRegion)
        XCTAssertEqual(preview.fullResolutionURL, a, "fit keeps the master until the photo changes")

        // A new photo drops the master and the window cut from it.
        preview.setZoom(.actual(center: CGPoint(x: 0.25, y: 0.25)))
        await waitUntil { preview.zoomImage != nil }
        preview.load(b)
        XCTAssertNil(preview.fullResolutionURL, "changing the photo drops the full-resolution master")
        XCTAssertEqual(preview.fullResolutionSize, .zero)
        XCTAssertNil(preview.zoomImage, "and the window cut from it")
        XCTAssertNil(preview.zoomURL)

        // Still 1:1: the new photo's first window decodes its own master.
        preview.request(url: b, recipe: spatial, maxPixelSize: 400, viewPixelSize: CGSize(width: 400, height: 300))
        await preview.awaitLoad()
        await preview.awaitFullResolution()
        await waitUntil { preview.zoomURL == b }
        XCTAssertEqual(preview.fullResolutionURL, b)
        XCTAssertEqual(preview.fullResolutionSize, CGSize(width: 1200, height: 900))
        XCTAssertEqual(preview.zoomFrameSize, CGSize(width: 1200, height: 900))
    }

    func testAWindowStillRenderingWhenFitReturnsNeverLands() async throws {
        let url = try writePNG("a.png", width: 3000, height: 2000)
        let preview = PreviewModel()
        preview.load(url)
        preview.request(url: url, recipe: spatial, maxPixelSize: 300, viewPixelSize: CGSize(width: 300, height: 200))
        await preview.awaitLoad()
        preview.setZoom(.actual(center: CGPoint(x: 0.5, y: 0.5)))
        await preview.awaitFullResolution()
        preview.setZoom(.fit)
        await settle()
        XCTAssertNil(preview.zoomImage, "a window wanted before fit returned is discarded")
        XCTAssertNotNil(preview.image)
    }

    func testASliderDragWhileZoomedRendersTheNewestRecipeInBothFrames() async throws {
        let url = try writePNG("a.png", width: 2400, height: 1600)
        let preview = PreviewModel()
        let view = CGSize(width: 600, height: 400)
        preview.load(url)
        preview.setZoom(.actual(center: CGPoint(x: 0.3, y: 0.6)))
        var r = spatial
        for ev in stride(from: -1.0, through: 1.0, by: 0.2) {
            set(&r, .exposure, ev)
            preview.request(url: url, recipe: r, maxPixelSize: 600, viewPixelSize: view)
        }
        // The newest recipe's window, rendered here the same way.
        let newest = try XCTUnwrap(Renderer.shared.render(try XCTUnwrap(Renderer.fullResolution(url, decodeNow: true)), recipe: r,
                                                          region: .init(center: CGPoint(x: 0.3, y: 0.6), size: view))).image
        await waitUntil { preview.zoomImage.map { PhotoLabTests.maxDiff($0, newest) == 0 } ?? false }
        let window = try XCTUnwrap(preview.zoomImage)
        XCTAssertEqual(PhotoLabTests.maxDiff(window, newest), 0, "the newest recipe wins in the window")
        let master = try XCTUnwrap(Renderer.previewMaster(url, maxPixelSize: PreviewModel.masterPixelSize))
        let fit = try XCTUnwrap(Renderer.shared.render(master, recipe: r, maxPixelSize: 600)).image
        await waitUntil { preview.image.map { PhotoLabTests.maxDiff($0, fit) == 0 } ?? false }
        XCTAssertEqual(PhotoLabTests.maxDiff(try XCTUnwrap(preview.image), fit), 0, "and in the fit frame")
    }

    /// A photo whose rendered frame fits the view whole goes back to fit by
    /// itself: 1:1 would only show it smaller. One wider than the view on
    /// one axis zooms.
    func testAPhotoSmallerThanTheViewStaysAtFit() async throws {
        let small = try writePNG("small.png", width: 640, height: 480)
        let preview = PreviewModel()
        preview.load(small)
        preview.request(url: small, recipe: spatial, maxPixelSize: 1200, viewPixelSize: CGSize(width: 1200, height: 800))
        await preview.awaitLoad()
        preview.setZoom(.actual(center: CGPoint(x: 0.3, y: 0.3)))
        await preview.awaitFullResolution()
        await waitUntil { preview.zoom == .fit }
        XCTAssertEqual(preview.zoom, .fit)
        await settle()
        XCTAssertNil(preview.zoomImage, "no window for a photo that fits")
        XCTAssertNotNil(preview.image)

        let wide = try writePNG("wide.png", width: 2000, height: 400)
        preview.load(wide)
        preview.request(url: wide, recipe: spatial, maxPixelSize: 1200, viewPixelSize: CGSize(width: 1200, height: 800))
        await preview.awaitLoad()
        preview.setZoom(.actual(center: CGPoint(x: 0.3, y: 0.3)))
        await preview.awaitFullResolution()
        await waitUntil { preview.zoomImage != nil }
        XCTAssertEqual(preview.zoom, .actual(center: CGPoint(x: 0.3, y: 0.3)))
        XCTAssertEqual(preview.zoomRegion, CGRect(x: 0, y: 0, width: 1200, height: 400),
                       "the window is the view's width and the photo's height")
    }

    /// The clipping overlay paints on the 1:1 window exactly as on the fit
    /// frame: the same compose over the plain window.
    func testTheClippingOverlayPaintsOnTheWindow() async throws {
        let url = try writePNG("a.png", width: 2400, height: 1600)
        var blown = spatial
        set(&blown, .exposure, 2.5)
        let view = CGSize(width: 600, height: 400)
        let preview = PreviewModel()
        preview.load(url)
        preview.request(url: url, recipe: blown, maxPixelSize: 600, viewPixelSize: view)
        await preview.awaitLoad()
        preview.setZoom(.actual(center: CGPoint(x: 0.5, y: 0.5)))
        await preview.awaitFullResolution()
        await waitUntil { preview.zoomImage != nil }
        let plain = try XCTUnwrap(preview.zoomImage)

        preview.setClipping(true)
        await waitUntil { preview.zoomImage.map { PhotoLabTests.maxDiff($0, plain) > 0 } ?? false }
        let painted = try XCTUnwrap(preview.zoomImage)
        let expected = try XCTUnwrap(ClippingOverlay.compose(over: plain, context: Renderer.shared.context))
        XCTAssertGreaterThan(PhotoLabTests.maxDiff(painted, plain), 0, "the overlay shows at 1:1")
        XCTAssertEqual(PhotoLabTests.maxDiff(painted, expected), 0, "and it is the fit frame's overlay")

        // A pan keeps it on.
        preview.setZoom(.actual(center: CGPoint(x: 0.2, y: 0.7)))
        await waitUntil { preview.zoomRegion == CGRect(x: 180, y: 920, width: 600, height: 400) }
        let moved = try XCTUnwrap(preview.zoomImage)
        let movedPlain = try XCTUnwrap(Renderer.shared.render(try XCTUnwrap(Renderer.fullResolution(url, decodeNow: true)),
                                                              recipe: blown,
                                                              region: .init(center: CGPoint(x: 0.2, y: 0.7), size: view))).image
        let movedExpected = try XCTUnwrap(ClippingOverlay.compose(over: movedPlain, context: Renderer.shared.context))
        XCTAssertEqual(PhotoLabTests.maxDiff(moved, movedExpected), 0)
    }

    // MARK: Timing

    /// A region step (a slider move while zoomed): the window of a 24 MP
    /// full-resolution master at a 2600×1600 view, with clarity, sharpening
    /// and vignette on, gated at 16 ms through `assertFrameBudget` (best
    /// median of up to three sweeps).
    func testRegionStepRendersWithinTheFrameBudget() throws {
        var load = loadAverage()
        let url = try bench24MPImageURL()
        let full = try XCTUnwrap(Renderer.fullResolution(url, decodeNow: true))
        let region = Renderer.Region(center: CGPoint(x: 0.5, y: 0.5), size: CGSize(width: 2600, height: 1600))
        var r = spatial
        _ = Renderer.shared.render(full, recipe: r, region: region)   // warm the pipeline
        var median = Double.infinity
        var attempts = 0
        repeat {
            attempts += 1
            var sweep: [Double] = []
            for step in 0..<20 {
                set(&r, .exposure, -1 + Double(step) * 0.1)
                let out = try XCTUnwrap(Renderer.shared.render(full, recipe: r, region: region))
                XCTAssertEqual(out.image.width, 2600)
                sweep.append(out.milliseconds)
            }
            median = min(median, sweep.sorted()[sweep.count / 2])
            load = max(load, loadAverage())
        } while attempts < 3 && median >= frameBudgetBound(16, load: load)
        print(String(format: "BENCH %@: 1:1 region 2600×1600 of %.0f×%.0f: median %.1f ms over 20 steps, load %.2f",
                     url.lastPathComponent, full.extent.width, full.extent.height, median, load))
        if attempts > 1 { print("BENCH-RETRY best of \(attempts) sweeps at load \(String(format: "%.2f", load))") }
        try assertFrameBudget(median, bound: 16, load: load, "a 1:1 region step must fit one 60 Hz frame")
    }
}
