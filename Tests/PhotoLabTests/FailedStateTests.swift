import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import PhotoLab

/// States that must resolve: a file that will not decode, and a Photos
/// original that will not fetch, each reach a visible failed state through
/// the model layer the views read, and the controls carry distinct names.
@MainActor
final class FailedStateTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-failed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writePNG(_ side: Int, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, syntheticImage(width: side, height: side), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    // MARK: A file that will not decode

    func testAJunkJPEGResolvesToFailedNotNothing() async throws {
        let junk = dir.appendingPathComponent("broken.JPG")
        try Data("this is not an image".utf8).write(to: junk)
        let thumbs = Thumbnails()
        let result = await thumbs.resolve(Thumbnails.Key(.file(junk)), showing: nil)
        guard case .failed = result else { return XCTFail("a junk file must resolve .failed, got \(result)") }
        // An edited recipe on the same junk file resolves the same way.
        var recipe = Recipe.neutral
        recipe.set(.exposure, to: 0.5)
        let edited = await thumbs.resolve(Thumbnails.Key(.file(junk), recipe: recipe), showing: nil)
        guard case .failed = edited else { return XCTFail("an edited junk file must resolve .failed, got \(edited)") }
    }

    func testAGoodFileResolvesToAnImageAndACancelledRequestIsNotFailed() async throws {
        let good = dir.appendingPathComponent("ok.png")
        try writePNG(32, to: good)
        let thumbs = Thumbnails()
        let ok = await thumbs.resolve(Thumbnails.Key(.file(good)), showing: nil)
        guard case .image = ok else { return XCTFail("a decodable file must resolve .image, got \(ok)") }

        let junk = dir.appendingPathComponent("broken.JPG")
        try Data("nope".utf8).write(to: junk)
        let task = Task { () -> Thumbnails.CellImage in
            withUnsafeCurrentTask { $0?.cancel() }
            return await Thumbnails().resolve(Thumbnails.Key(.file(junk)), showing: nil)
        }
        let cancelled = await task.value
        guard case .unchanged = cancelled else { return XCTFail("a cancelled request is not a failure, got \(cancelled)") }
    }

    // MARK: A Photos original that will not fetch

    func testAFailedPhotosFetchResolvesToAnUnavailableStateInPanelAndStrip() async throws {
        let client = PhotosTests.FakePhotoKit(status: .authorized)
        client.albumList = [PhotosTests.recents]
        client.assetsByAlbum[PhotosTests.recents.id] = PhotosTests.shoot
        client.failWrites = true
        let access = PhotosAccess(client: client,
                                  sidecarDirectory: dir.appendingPathComponent("s"),
                                  originalsDirectory: dir.appendingPathComponent("o"))
        let source = access.source(for: PhotosTests.recents)
        _ = try source.photos()

        let result = await OriginalFetch.load(.asset("A/L0/001"), using: { try await source.originalFile(for: $0) })
        let state = try XCTUnwrap(result)
        XCTAssertNil(state.file)
        guard case .failed = state.state else { return XCTFail("fetch failure must be .failed, got \(state.state)") }
        XCTAssertEqual(state.state.unavailableNote, "Original not available", "the panel footer's text")
        XCTAssertTrue(PresetStrip.cellFailed(unavailable: state.state.unavailableNote != nil, file: nil, failedFile: nil),
                      "preset cells read Could not open, they do not spin")

        XCTAssertNil(OriginalFetch.none.unavailableNote)
        XCTAssertNil(OriginalFetch.fetching.unavailableNote)
        XCTAssertFalse(PresetStrip.cellFailed(unavailable: false, file: nil, failedFile: nil), "still fetching: spins")
    }

    // MARK: Accessible names

    func testTheIconControlsHaveDistinctNonEmptyNames() {
        var names = [AccessibleName.undo, AccessibleName.redo, AccessibleName.pick, AccessibleName.reject,
                     AccessibleName.unflag, AccessibleName.moreActions]
        names += (1...Marks.maxRating).map(AccessibleName.stars)
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(names).count, names.count, "no two controls share a name")
        let kinds = AdjustmentKind.allCases.map(AccessibleName.applyAdjustment)
        XCTAssertEqual(Set(kinds).count, kinds.count, "each adjustment's toggle names its adjustment")
        let sliders = AdjustmentKind.allCases.map(AccessibleName.adjustment)
        XCTAssertEqual(Set(sliders).count, sliders.count, "each adjustment's slider has its own name")
    }
}
