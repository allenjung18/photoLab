import XCTest
import CoreImage
import ImageIO
@testable import PhotoLab

/// The two live models behind the loupe canvas and the preset strip: a file
/// that is not an image is reported as `failed` (the views label it instead
/// of spinning), the same url is decoded again on the next request, and a
/// decode that succeeds clears the failure.
@MainActor
final class PreviewTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writePNG(_ name: String, _ image: CGImage) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// A `.png` that holds text, not an image.
    private func writeJunk(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("not an image".utf8).write(to: url)
        return url
    }

    /// Polls `condition` for up to `seconds`, yielding to the model's tasks.
    private func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testPreviewModelReportsAFailedDecodeRetriesItAndClearsItOnSuccess() async throws {
        let junk = try writeJunk("junk.png")
        let good = try writePNG("good.png", syntheticImage(width: 64, height: 48))
        let preview = PreviewModel()

        preview.load(junk)
        preview.request(url: junk, recipe: .neutral, maxPixelSize: 32)
        await preview.awaitLoad()
        XCTAssertEqual(preview.failed, junk, "a file that is not an image is reported")
        XCTAssertNil(preview.image)
        XCTAssertEqual(preview.masterSize, .zero)

        // The next load of the same url decodes again: once the file is a
        // real image, the frame arrives and the failure is cleared.
        try FileManager.default.removeItem(at: junk)
        _ = try writePNG("junk.png", syntheticImage(width: 64, height: 48))
        preview.load(junk)
        await preview.awaitLoad()
        XCTAssertNil(preview.failed, "a decode that succeeds clears the failure")
        await waitUntil { preview.image != nil }
        XCTAssertEqual(preview.imageURL, junk)
        XCTAssertEqual(preview.masterSize, CGSize(width: 64, height: 48))

        // A failure on another photo does not take the good one's frame away.
        preview.load(good)
        await preview.awaitLoad()
        XCTAssertNil(preview.failed)
        preview.request(url: good, recipe: .neutral, maxPixelSize: 32)
        await waitUntil { preview.imageURL == good }
        XCTAssertEqual(preview.imageURL, good)
    }

    func testPresetThumbnailsReportAFailedDecodeAndClearItOnTheNextGoodPhoto() async throws {
        let junk = try writeJunk("junk.png")
        let good = try writePNG("good.png", syntheticImage(width: 64, height: 48))
        let strip = PresetThumbnails()
        let presets = Array(Preset.starters.prefix(2))

        strip.request(url: junk, presets: presets, base: .neutral, pixelSize: 16)
        await waitUntil { !strip.isBusy }
        XCTAssertEqual(strip.failed, junk, "the strip reports the photo it could not decode")
        XCTAssertNil(strip.url)
        XCTAssertTrue(strip.thumbnails.isEmpty)

        strip.request(url: good, presets: presets, base: .neutral, pixelSize: 16)
        await waitUntil { !strip.isBusy }
        XCTAssertNil(strip.failed, "a decode that succeeds clears the failure")
        XCTAssertEqual(strip.url, good)
        XCTAssertEqual(Set(strip.thumbnails.keys), Set(presets.map(\.name)))

        // Back to the broken file: the strip reports it again; the good
        // photo's thumbnails stay keyed to its url, so its cells still show.
        strip.request(url: junk, presets: presets, base: .neutral, pixelSize: 16)
        await waitUntil { !strip.isBusy }
        XCTAssertEqual(strip.failed, junk)
        XCTAssertEqual(strip.url, good)
    }
}
