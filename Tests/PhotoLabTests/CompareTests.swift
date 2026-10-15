import XCTest
import CoreImage
import ImageIO
@testable import PhotoLab

/// Before / After side by side (`Y`): in compare mode `PreviewModel` renders
/// two frames of the same master through the one chain at the same pixel
/// size, the Before one equal to the neutral render; a slider move does not
/// re-render Before; leaving compare mode drops it, including one that was
/// still rendering.
@MainActor
final class CompareTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-compare-\(UUID().uuidString)", isDirectory: true)
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

    private func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Lets every render the model has queued finish.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func exposure(_ ev: Double) -> Recipe {
        var r = Recipe.neutral
        r.set(.exposure, to: ev)
        r.setEnabled(.exposure, true)
        return r
    }

    /// The frame the model should show for `recipe`, rendered here from the
    /// same master the model decodes.
    private func direct(_ url: URL, _ recipe: Recipe, size: Int) throws -> CGImage {
        let master = try XCTUnwrap(Renderer.previewMaster(url, maxPixelSize: PreviewModel.masterPixelSize))
        return try XCTUnwrap(Renderer.shared.render(master, recipe: recipe, maxPixelSize: size)).image
    }

    func testCompareModeRendersBeforeAndAfterAtEqualSizeFromOneMaster() async throws {
        let url = try writePNG("a.png")
        let preview = PreviewModel()
        let recipe = exposure(1)
        preview.load(url)
        preview.setCompare(true)
        preview.request(url: url, recipe: recipe, maxPixelSize: 200)
        await preview.awaitLoad()
        await waitUntil { preview.image != nil && preview.beforeImage != nil }

        let after = try XCTUnwrap(preview.image)
        let before = try XCTUnwrap(preview.beforeImage, "compare mode produces a second frame")
        XCTAssertEqual(preview.beforeURL, url)
        XCTAssertEqual(preview.imageURL, url)
        XCTAssertEqual(before.width, after.width, "the two halves are the same pixel size")
        XCTAssertEqual(before.height, after.height)
        XCTAssertEqual(max(before.width, before.height), 200)

        let neutral = try direct(url, .neutral, size: 200)
        XCTAssertEqual(maxDiff(before, neutral), 0, "Before is exactly the neutral render of the master")
        XCTAssertEqual(maxDiff(after, try direct(url, recipe, size: 200)), 0, "After is the recipe's render")
        XCTAssertGreaterThan(maxDiff(after, neutral), 20, "After carries the recipe")
    }

    func testOffByDefaultNoBeforeFrame() async throws {
        let url = try writePNG("a.png")
        let preview = PreviewModel()
        preview.load(url)
        preview.request(url: url, recipe: exposure(1), maxPixelSize: 160)
        await preview.awaitLoad()
        await waitUntil { preview.image != nil }
        await settle()
        XCTAssertFalse(preview.compare)
        XCTAssertNil(preview.beforeImage, "no second render outside compare mode")
    }

    func testTurningCompareOnRendersBeforeForTheShownRequest() async throws {
        let url = try writePNG("a.png")
        let preview = PreviewModel()
        preview.load(url)
        preview.request(url: url, recipe: exposure(1), maxPixelSize: 160)
        await preview.awaitLoad()
        await waitUntil { preview.image != nil }
        XCTAssertNil(preview.beforeImage)

        preview.setCompare(true)
        await waitUntil { preview.beforeImage != nil }
        let before = try XCTUnwrap(preview.beforeImage)
        XCTAssertEqual(maxDiff(before, try direct(url, .neutral, size: 160)), 0)
    }

    func testARecipeChangeKeepsBeforeAndANewSizeReplacesIt() async throws {
        let url = try writePNG("a.png")
        let preview = PreviewModel()
        preview.load(url)
        preview.setCompare(true)
        preview.request(url: url, recipe: exposure(1), maxPixelSize: 160)
        await preview.awaitLoad()
        await waitUntil { preview.image != nil && preview.beforeImage != nil }
        let first = try XCTUnwrap(preview.beforeImage)

        // A slider drag: many requests, latest wins for After; Before is not
        // rendered again.
        for ev in stride(from: 1.1, through: 2.0, by: 0.1) {
            preview.request(url: url, recipe: exposure(ev), maxPixelSize: 160)
        }
        let last = try direct(url, exposure(2.0), size: 160)
        await waitUntil { preview.image.map { maxDiff($0, last) == 0 } ?? false }
        XCTAssertEqual(maxDiff(try XCTUnwrap(preview.image), last), 0, "the newest recipe wins")
        await settle()
        XCTAssertTrue(preview.beforeImage === first, "a recipe change does not re-render Before")

        // A new pane size renders both again at the new size.
        preview.request(url: url, recipe: exposure(2.0), maxPixelSize: 120)
        await waitUntil { preview.beforeImage.map { $0.width == 120 } ?? false }
        await waitUntil { preview.image.map { $0.width == 120 } ?? false }
        let before = try XCTUnwrap(preview.beforeImage)
        let after = try XCTUnwrap(preview.image)
        XCTAssertEqual(before.width, after.width)
        XCTAssertEqual(before.height, after.height)
        XCTAssertEqual(maxDiff(before, try direct(url, .neutral, size: 120)), 0)
    }

    func testLeavingCompareModeDropsTheSecondFrame() async throws {
        let url = try writePNG("a.png")
        let preview = PreviewModel()
        preview.load(url)
        preview.setCompare(true)
        preview.request(url: url, recipe: exposure(1), maxPixelSize: 160)
        await preview.awaitLoad()
        await waitUntil { preview.image != nil && preview.beforeImage != nil }
        XCTAssertNotNil(preview.beforeImage)

        preview.setCompare(false)
        XCTAssertFalse(preview.compare)
        XCTAssertNil(preview.beforeImage, "leaving compare mode drops the Before frame")
        XCTAssertNil(preview.beforeURL)
        XCTAssertNotNil(preview.image, "the After frame stays")

        // Later requests render After alone.
        preview.request(url: url, recipe: exposure(1.5), maxPixelSize: 140)
        await waitUntil { preview.image.map { $0.width == 140 } ?? false }
        await settle()
        XCTAssertNil(preview.beforeImage)

        // A Before still rendering when compare mode ends is dropped too.
        preview.setCompare(true)
        preview.request(url: url, recipe: exposure(1.5), maxPixelSize: 100)
        preview.setCompare(false)
        await waitUntil { preview.image.map { $0.width == 100 } ?? false }
        await settle()
        XCTAssertNil(preview.beforeImage, "a Before in flight when compare ends never lands")
    }

    /// Compare off and on again while a Before renders: the stale frame
    /// never shows, not even until the new one lands. The second request is
    /// large so its render leaves time to see a stale frame if one landed.
    func testABeforeFromAnEarlierCompareSessionNeverShows() async throws {
        let url = try writePNG("big.png", width: 3000, height: 2000)
        let preview = PreviewModel()
        preview.load(url)
        preview.request(url: url, recipe: .neutral, maxPixelSize: 100)
        await preview.awaitLoad()
        await waitUntil { preview.image != nil }
        await settle()

        preview.setCompare(true)          // Before at 100 px starts rendering
        preview.setCompare(false)
        preview.setCompare(true)
        preview.request(url: url, recipe: .neutral, maxPixelSize: 2400)
        var seen = Set<Int>()
        let deadline = Date().addingTimeInterval(10)
        while preview.beforeImage?.width != 2400 && Date() < deadline {
            if let w = preview.beforeImage?.width { seen.insert(w) }
            try? await Task.sleep(nanoseconds: 500_000)
        }
        XCTAssertEqual(preview.beforeImage?.width, 2400)
        XCTAssertFalse(seen.contains(100), "the Before from before the toggle never lands (seen \(seen.sorted()))")
    }

    /// Compare turned on in the middle of a slider drag: the drag keeps an
    /// After request waiting at every frame, and Before still lands during
    /// the drag rather than after it.
    func testBeforeLandsDuringASliderDrag() async throws {
        let url = try writePNG("big.png", width: 3000, height: 2000)
        let preview = PreviewModel()
        preview.load(url)
        preview.request(url: url, recipe: .neutral, maxPixelSize: 1600)
        await preview.awaitLoad()
        await waitUntil { preview.image != nil }

        // The drag is already rendering a frame when compare mode comes on.
        var ev = 0.01
        preview.request(url: url, recipe: exposure(ev), maxPixelSize: 1600)
        preview.setCompare(true)
        let deadline = Date().addingTimeInterval(3)
        while preview.beforeImage == nil && Date() < deadline {
            ev += 0.01
            preview.request(url: url, recipe: exposure(ev), maxPixelSize: 1600)
            try? await Task.sleep(nanoseconds: 200_000)
        }
        XCTAssertNotNil(preview.beforeImage, "Before is not starved by a drag (\(Int(ev * 100)) drag ticks)")
    }

    func testOpeningAFolderLeavesCompareMode() throws {
        _ = try writePNG("a.png")
        let library = Library(rememberFolder: false)
        library.compare = true
        library.open(folder)
        XCTAssertNotNil(library.source)
        XCTAssertFalse(library.compare, "a new folder opens with compare mode off")
    }
}
