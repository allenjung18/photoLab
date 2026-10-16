import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import PhotoLab

/// The `PhotoSource` seam: a library opens any source in the source's own
/// order, keeps its edits in the source's `SidecarStore` (flat naming for a
/// source without a folder, the folder naming for `FolderSource`), and
/// takes names and original files from the source.
@MainActor
final class SourceTests: XCTestCase {
    private var base: URL!
    private var folder: URL!
    private var sidecarDir: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-source-\(UUID().uuidString)", isDirectory: true)
        folder = base.appendingPathComponent("photos", isDirectory: true)
        sidecarDir = base.appendingPathComponent("sidecars", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    private func makePhoto(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
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

    /// Three assets in a fixed (non-alphabetical) order, sidecars in a flat
    /// directory, every original the same file; a failing listing on demand.
    private struct FakeSource: PhotoSource {
        var title = "Fake album"
        var listed: [Photo]
        var directory: URL
        var original: URL
        var failure: String?

        func photos() throws -> [Photo] {
            if let failure { throw NSError(domain: "FakeSource", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]) }
            return listed
        }
        var sidecars: SidecarStore { SidecarStore(directory: directory, naming: .flat) }
        func thumbnail(for id: PhotoID, maxPixelSize: Int) -> NSImage? { nil }
        func originalFile(for id: PhotoID) async throws -> URL {
            guard listed.contains(where: { $0.id == id }) else { throw PhotoSourceError.notInThisSource(id) }
            return original
        }
    }

    private func fake(failure: String? = nil) throws -> FakeSource {
        let file = try makePhoto("original.png")
        return FakeSource(
            listed: [
                Photo(id: .asset("C/L0/003"), name: "IMG_0003.HEIC"),
                Photo(id: .asset("A/L0/001"), name: "IMG_0001.HEIC"),
                Photo(id: .asset("B/L0/002"), name: "IMG_0002.HEIC"),
            ],
            directory: sidecarDir, original: file, failure: failure)
    }

    // MARK: A fake source

    func testAFakeSourceOpensInTheSortOrderWithItsNamesAndTitle() throws {
        let source = try fake()
        let lib = Library(rememberFolder: false)
        lib.open(source)
        XCTAssertNil(lib.openError)
        XCTAssertEqual(lib.sort, .photosDefault, "a source that is not a folder sorts like a Photos album")
        XCTAssertEqual(lib.photos.map(\.id), [.asset("A/L0/001"), .asset("B/L0/002"), .asset("C/L0/003")],
                       "no capture dates: the tie is broken by name, not the source's listing order")
        XCTAssertEqual(lib.photos.map(\.name), ["IMG_0001.HEIC", "IMG_0002.HEIC", "IMG_0003.HEIC"])
        XCTAssertEqual(lib.source?.title, "Fake album")
        XCTAssertNil(lib.folder, "a source that is not a folder has none")
        XCTAssertEqual(lib.name(for: .asset("A/L0/001")), "IMG_0001.HEIC", "names come from the source")
        XCTAssertEqual(lib.name(for: .asset("Z/L0/999")), "Z/L0/999", "a photo not listed falls back to its id")
        XCTAssertNil(lib.photos[0].fileURL, "an asset has no file until its source produces one")

        // Copy Settings and Sync name the photo as the source does.
        lib.setRecipe(sampleRecipe, for: .asset("A/L0/001"))
        lib.copySettings(from: .asset("A/L0/001"))
        XCTAssertEqual(lib.copiedSettings?.name, "IMG_0001.HEIC")
        lib.selection = .asset("A/L0/001")
        lib.selectAll()
        lib.requestSync()
        XCTAssertEqual(lib.syncRequest?.sourceName, "IMG_0001.HEIC")
    }

    func testARecipeOnAnAssetPersistsFlatAndReloadsThroughAFreshLibrary() throws {
        let source = try fake()
        let lib = Library(rememberFolder: false)
        lib.open(source)
        lib.setRecipe(sampleRecipe, for: .asset("A/L0/001"))
        lib.setFlag(.pick, for: [.asset("B/L0/002")])

        let file = sidecarDir.appendingPathComponent("A_L0_001.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "flat naming: / becomes _ in \(sidecarDir.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarDir.appendingPathComponent("B_L0_002.json").path))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"original\" : \"IMG_0001.HEIC\""), "the source's name is the recorded original: \(text)")

        let again = Library(rememberFolder: false)
        again.open(source)
        XCTAssertEqual(again.recipe(for: .asset("A/L0/001")), sampleRecipe)
        XCTAssertEqual(again.marks(for: .asset("B/L0/002")), Marks(flag: .pick, rating: 0))
        XCTAssertEqual(again.recipe(for: .asset("C/L0/003")), .neutral)

        // Reset removes the flat file like a folder sidecar.
        again.resetRecipe(for: .asset("A/L0/001"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testExportItemsTakeTheirFileFromTheSource() async throws {
        let source = try fake()
        let lib = Library(rememberFolder: false)
        lib.open(source)
        lib.setRecipe(sampleRecipe, for: .asset("A/L0/001"))
        let items = try await lib.exportItems(for: [.asset("A/L0/001"), .asset("C/L0/003")])
        XCTAssertEqual(items.map(\.source), [source.original, source.original])
        XCTAssertEqual(items.map(\.recipe), [sampleRecipe, .neutral])
        let file = try await lib.originalFile(for: .asset("B/L0/002"))
        XCTAssertEqual(file, source.original)
        do {
            _ = try await lib.originalFile(for: .asset("Z/L0/999"))
            XCTFail("an id the source does not list has no file")
        } catch let error as PhotoSourceError {
            XCTAssertEqual(error, .notInThisSource(.asset("Z/L0/999")))
        }
    }

    func testASourceWhoseListingFailsIsRefusedAndTheOpenSourceStays() throws {
        let bad = try fake(failure: "album gone")   // also writes original.png into the folder
        try makePhoto("a.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        XCTAssertEqual(lib.folder, folder)
        lib.open(bad)
        XCTAssertEqual(lib.openError, "album gone")
        XCTAssertEqual(lib.folder, folder, "the folder stays open")
        XCTAssertEqual(lib.photos.map(\.name), ["a.png", "original.png"])
    }

    // MARK: The folder source

    func testAFolderOpensThroughFolderSourceAndItsSidecarsKeepTheFolderNaming() async throws {
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let a = try makePhoto("a.png")
        let b = try makePhoto("sub/b.png")

        let lib = Library(rememberFolder: false)
        lib.open(folder)
        XCTAssertTrue(lib.source is FolderSource)
        XCTAssertEqual(lib.source?.title, folder.lastPathComponent)
        XCTAssertEqual(lib.folder, folder)
        XCTAssertEqual(lib.photos.map(\.id), lib.photos.compactMap(\.fileURL).map { PhotoID.file($0) },
                       "a folder photo's id is its file")
        XCTAssertEqual(lib.photos.compactMap(\.fileURL).map { $0.resolvingSymlinksInPath() },
                       [a, b].map { $0.resolvingSymlinksInPath() }, "the scan resolves /var -> /private/var")
        XCTAssertEqual(lib.photos.map(\.name), ["a.png", "b.png"])
        XCTAssertEqual(lib.photos.compactMap(\.fileURL).map(\.lastPathComponent), ["a.png", "b.png"],
                       "a folder photo's file is known at once")
        let ids = lib.photos.map(\.id)
        let original = try await lib.originalFile(for: ids[1])
        XCTAssertEqual(original, ids[1].fileURL, "a folder photo's original is its own file")

        lib.setRecipe(sampleRecipe, for: ids[1])
        let expected = folder.appendingPathComponent(".photolab/sub/b.png.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path), "folder naming: .photolab/<relative path>.json")
        XCTAssertEqual(lib.source?.sidecars.url(for: ids[1]).standardizedFileURL.resolvingSymlinksInPath(),
                       expected.standardizedFileURL.resolvingSymlinksInPath())

        // `PhotoLab <file>` still opens the file's folder with that photo in
        // the loupe, and the folder's sidecars come back.
        let byFile = Library(rememberFolder: false)
        byFile.open(a)
        XCTAssertEqual(byFile.folder?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(byFile.selection, ids[0])
        XCTAssertTrue(byFile.loupe)
        XCTAssertEqual(byFile.recipe(for: ids[1]), sampleRecipe)
    }

    func testTheTwoNamingsMapIdsToFiles() {
        let folderStore = SidecarStore(folder: folder)
        XCTAssertEqual(folderStore.directory, folder.appendingPathComponent(".photolab", isDirectory: true))
        XCTAssertEqual(folderStore.folder, folder)
        XCTAssertEqual(folderStore.relativeName(for: .file(folder.appendingPathComponent("sub/a.jpg"))), "sub/a.jpg")
        XCTAssertEqual(folderStore.relativeName(for: .file(URL(fileURLWithPath: "/elsewhere/x.jpg"))), "x.jpg",
                       "a file outside the folder keeps its name")
        XCTAssertEqual(folderStore.relativeName(for: .asset("A/L0/001")), "A_L0_001",
                       "an asset in a folder store takes the flat form")
        XCTAssertEqual(folderStore.url(for: .file(folder.appendingPathComponent("a.jpg"))),
                       folderStore.url(for: folder.appendingPathComponent("a.jpg")), "the URL form is .file(url)")

        let flat = SidecarStore(directory: sidecarDir, naming: .flat)
        XCTAssertNil(flat.folder)
        XCTAssertEqual(flat.url(for: .asset("A/L0/001")), sidecarDir.appendingPathComponent("A_L0_001.json", isDirectory: false))
        XCTAssertEqual(flat.relativeName(for: .file(URL(fileURLWithPath: "/Users/me/p/x.jpg"))), "Users_me_p_x.jpg")
        XCTAssertEqual(SidecarStore.flatName("/a//b/"), "a_b")
    }

    // MARK: Ids

    func testPhotoIDRoundTripsThroughJSONAndKeysOneThumbnailCache() throws {
        let ids: [PhotoID] = [.file(URL(fileURLWithPath: "/tmp/a.jpg")), .asset("A/L0/001")]
        let data = try JSONEncoder().encode(ids)
        XCTAssertEqual(try JSONDecoder().decode([PhotoID].self, from: data), ids)
        XCTAssertNotEqual(ids[0].cacheKey, ids[1].cacheKey)
        XCTAssertNotEqual(PhotoID.file(URL(fileURLWithPath: "/x")).cacheKey, PhotoID.asset("/x").cacheKey,
                          "a file and an asset with the same text never share a key")
        XCTAssertEqual(ids[0].defaultName, "a.jpg")
        XCTAssertEqual(ids[1].defaultName, "A/L0/001")
        XCTAssertEqual(ids[0].fileURL, URL(fileURLWithPath: "/tmp/a.jpg"))
        XCTAssertNil(ids[1].fileURL)
        XCTAssertNil(ImageLoading.downsampled(ids[1], maxPixelSize: 480), "an asset has no ImageIO thumbnail")
    }
}
