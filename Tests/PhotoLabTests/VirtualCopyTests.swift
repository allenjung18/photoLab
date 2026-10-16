import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Virtual copies, the model: a copy is a second identity of one file or
/// asset (`PhotoID.copy`) with its own recipe, marks and sidecar beside its
/// master's (`<name>@copy<n>.json`), found again by `Library.open`, listed
/// right after its master, and removed by deleting only its own file.
@MainActor
final class VirtualCopyTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-vcopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The scan lists resolved paths (/private/var, not /var).
        let real = realpath(folder.path, nil)!
        defer { free(real) }
        folder = URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func makePhoto(_ name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? folder).appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func recipe(exposure: Double) -> Recipe {
        var r = Recipe.neutral
        r.set(.exposure, to: exposure)
        return r
    }

    private func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    private var sidecarDir: URL { folder.appendingPathComponent(".photolab", isDirectory: true) }

    // MARK: Identity

    func testCopyIdentityReadsTheMastersFileWithItsOwnCacheKey() throws {
        let file = folder.appendingPathComponent("IMG_0001.JPG")
        let master = PhotoID.file(file)
        let copy = PhotoID.copy(of: master, number: 2)
        XCTAssertEqual(copy.fileURL, file)
        XCTAssertEqual(copy.defaultName, "IMG_0001.JPG")
        XCTAssertNotEqual(copy.cacheKey, master.cacheKey)
        XCTAssertNotEqual(copy.cacheKey, PhotoID.copy(of: master, number: 3).cacheKey)
        XCTAssertEqual(copy.master, master)
        XCTAssertEqual(PhotoID.copy(of: copy, number: 3).master, master, "a copy of a copy is the master's")
        let asset = PhotoID.copy(of: .asset("A/L0/001"), number: 2)
        XCTAssertNil(asset.fileURL)
        XCTAssertEqual(asset.master, .asset("A/L0/001"))
        let decoded = try JSONDecoder().decode(PhotoID.self, from: JSONEncoder().encode(copy))
        XCTAssertEqual(decoded, copy)
    }

    func testCopySidecarNamesUnderBothNamings() {
        let file = folder.appendingPathComponent("IMG_0001.JPG")
        let folderStore = SidecarStore(folder: folder)
        XCTAssertEqual(folderStore.url(for: .copy(of: .file(file), number: 2)).path,
                       sidecarDir.appendingPathComponent("IMG_0001.JPG@copy2.json").path)
        let flat = SidecarStore(directory: folder, naming: .flat)
        XCTAssertEqual(flat.relativeName(for: .copy(of: .asset("A/L0/001"), number: 3)), "A_L0_001@copy3")
        XCTAssertEqual(flat.relativeName(for: .copy(of: .file(file), number: 2)),
                       flat.relativeName(for: .file(file)) + "@copy2")
    }

    /// No real photo's sidecar name reads as a copy's, even one whose own
    /// name contains the suffix; every copy's name reads back to its master.
    func testNoRealPhotoSidecarNameParsesAsACopy() {
        let store = SidecarStore(folder: folder)
        let flat = SidecarStore(directory: folder, naming: .flat)
        let names = ["IMG_0001.JPG", "a@copy2.jpg", "x@copy2.png", "@copy2.heic", "sub@copy3.CR3", "b.jpg@copy.png"]
        for name in names {
            let id = PhotoID.file(folder.appendingPathComponent(name))
            for s in [store, flat] {
                let file = s.relativeName(for: id) + ".json"
                XCTAssertNil(SidecarStore.parseCopy(file), file)
                let copyFile = s.relativeName(for: .copy(of: id, number: 2)) + ".json"
                let parsed = SidecarStore.parseCopy(copyFile)
                XCTAssertEqual(parsed?.base, s.relativeName(for: id), copyFile)
                XCTAssertEqual(parsed?.number, 2)
            }
        }
        XCTAssertNil(SidecarStore.parseCopy(flat.relativeName(for: .asset("A/L0/001")) + ".json"))
        for bad in ["a.jpg@copy1.json", "a.jpg@copy02.json", "a.jpg@copy.json", "a.jpg@copyx.json",
                    "@copy2.json", "a.jpg@copy2.json.unreadable-20261016-120000"] {
            XCTAssertNil(SidecarStore.parseCopy(bad), bad)
        }
    }

    // MARK: Create, edit, reopen

    func testCreateWritesTheSuffixedSidecarAndListsTheCopyAfterItsMaster() throws {
        let a = try makePhoto("a.png")
        try makePhoto("b.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.setRecipe(recipe(exposure: 1), for: .file(a))
        lib.setFlag(.pick, for: [.file(a)])

        let copy = try XCTUnwrap(lib.createVirtualCopy(of: .file(a)))
        XCTAssertEqual(copy, .copy(.file(a), 2))
        let file = sidecarDir.appendingPathComponent("a.png@copy2.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(lib.photos.map(\.id.cacheKey),
                       [PhotoID.file(a), copy, .file(folder.appendingPathComponent("b.png"))].map(\.cacheKey))
        XCTAssertEqual(lib.selection, copy)
        XCTAssertEqual(lib.recipe(for: copy), recipe(exposure: 1), "starts from the source's recipe")
        XCTAssertEqual(lib.marks(for: copy), .none, "without marks")
        XCTAssertEqual(lib.photos[1].name, "a.png")

        // A copy of the copy is the master's next copy, listed after copy 2.
        let third = try XCTUnwrap(lib.createVirtualCopy(of: copy))
        XCTAssertEqual(third, .copy(.file(a), 3))
        XCTAssertEqual(lib.photos.map(\.id).prefix(3), [.file(a), copy, third])
    }

    func testEditingTheCopyLeavesTheMastersSidecarByteIdenticalAndTheReverse() throws {
        let a = try makePhoto("a.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.setRecipe(recipe(exposure: 1), for: .file(a))
        let copy = try XCTUnwrap(lib.createVirtualCopy(of: .file(a)))
        let masterFile = SidecarStore(folder: folder).url(for: .file(a))
        let copyFile = SidecarStore(folder: folder).url(for: copy)

        let masterBefore = try bytes(masterFile)
        lib.setRecipe(recipe(exposure: -2), for: copy)
        lib.setRating(4, for: [copy])
        XCTAssertEqual(try bytes(masterFile), masterBefore)
        XCTAssertEqual(lib.recipe(for: .file(a)), recipe(exposure: 1))

        let copyBefore = try bytes(copyFile)
        lib.setRecipe(recipe(exposure: 0.5), for: .file(a))
        lib.setFlag(.reject, for: [.file(a)])
        XCTAssertEqual(try bytes(copyFile), copyBefore)
        XCTAssertEqual(lib.recipe(for: copy), recipe(exposure: -2))
    }

    func testReopenRestoresBothRecipesAndTheCopysMarks() throws {
        let a = try makePhoto("a.png")
        try makePhoto("b.png")
        let first = Library(rememberFolder: false)
        first.open(folder)
        first.setRecipe(recipe(exposure: 1), for: .file(a))
        let copy = try XCTUnwrap(first.createVirtualCopy(of: .file(a)))
        first.setRecipe(recipe(exposure: -1), for: copy)
        first.setRating(3, for: [copy])
        first.setFlag(.pick, for: [copy])

        let second = Library(rememberFolder: false)
        second.open(folder)
        XCTAssertEqual(second.photos.map(\.id).prefix(2), [.file(a), copy])
        XCTAssertEqual(second.photos.count, 3)
        XCTAssertEqual(second.recipe(for: .file(a)), recipe(exposure: 1))
        XCTAssertEqual(second.recipe(for: copy), recipe(exposure: -1))
        XCTAssertEqual(second.marks(for: copy), Marks(flag: .pick, rating: 3))
        XCTAssertEqual(second.marks(for: .file(a)), .none)
    }

    func testADefaultRecipeCopySurvivesReopen() throws {
        let a = try makePhoto("a.png")
        let first = Library(rememberFolder: false)
        first.open(folder)
        let copy = try XCTUnwrap(first.createVirtualCopy(of: .file(a)))
        let file = SidecarStore(folder: folder).url(for: copy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "written at once at the default recipe")
        first.setRecipe(recipe(exposure: 1), for: copy)
        first.resetRecipe(for: copy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a reset keeps a copy's file")

        let second = Library(rememberFolder: false)
        second.open(folder)
        XCTAssertEqual(second.photos.map(\.id), [.file(a), copy])
        XCTAssertFalse(second.isEdited(copy))
    }

    func testCopiesAreFoundInASubfolderAndSortFollowTheirMaster() throws {
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let a = try makePhoto("a.png", in: sub)
        let z = try makePhoto("z.png")
        let first = Library(rememberFolder: false)
        first.open(folder)
        let ca = try XCTUnwrap(first.createVirtualCopy(of: .file(a)))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sidecarDir.appendingPathComponent("sub/a.png@copy2.json").path))
        let cz = try XCTUnwrap(first.createVirtualCopy(of: .file(z)))
        first.setRating(5, for: [ca, cz])

        let second = Library(rememberFolder: false)
        second.open(folder)
        second.sort = PhotoSort(key: .name, ascending: false)
        XCTAssertEqual(second.photos.map(\.id), [.file(z), cz, .file(a), ca])
        second.sort = PhotoSort(key: .rating, ascending: false)
        XCTAssertEqual(second.photos.map(\.id), [.file(a), ca, .file(z), cz],
                       "a copy is never sorted on its own rating")
    }

    func testSortPutsCopiesAfterTheirMasterByNumber() {
        let a = Photo(url: URL(fileURLWithPath: "/p/a.png"))
        let b = Photo(url: URL(fileURLWithPath: "/p/b.png"))
        let photos = [a.virtualCopy(number: 3), b, a.virtualCopy(number: 2), a, b.virtualCopy(number: 2)]
        for ascending in [true, false] {
            let sorted = PhotoSort(key: .name, ascending: ascending)
                .sorted(photos, captureDate: { _ in nil }, rating: { _ in 0 }, edited: { _ in false })
            let first = ascending ? a : b, second = ascending ? b : a
            var want = [first.id, PhotoID.copy(of: first.id, number: 2)]
            if first.id == a.id { want.append(.copy(of: a.id, number: 3)) }
            want += [second.id, .copy(of: second.id, number: 2)]
            if second.id == a.id { want.append(.copy(of: a.id, number: 3)) }
            XCTAssertEqual(sorted.map(\.id), want)
        }
    }

    // MARK: Remove

    func testRemoveDeletesOnlyTheCopysFileAndDropsItEverywhere() throws {
        let a = try makePhoto("a.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.setRecipe(recipe(exposure: 1), for: .file(a))
        let c2 = try XCTUnwrap(lib.createVirtualCopy(of: .file(a)))
        let c3 = try XCTUnwrap(lib.createVirtualCopy(of: .file(a)))
        lib.setRecipe(recipe(exposure: 2), for: c2)
        lib.setRecipe(recipe(exposure: 3), for: c2)
        lib.setFlag(.pick, for: [c2])
        lib.addKeywords(["beach"], to: [c2])
        XCTAssertGreaterThan(lib.historyEntries(for: c2).count, 1)
        let store = SidecarStore(folder: folder)
        let masterBytes = try bytes(store.url(for: .file(a)))
        let c3Bytes = try bytes(store.url(for: c3))

        lib.selection = c2
        XCTAssertFalse(lib.removeVirtualCopy(.file(a)), "refused on a master")
        XCTAssertTrue(lib.removeVirtualCopy(c2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: c2).path))
        XCTAssertEqual(try bytes(store.url(for: .file(a))), masterBytes)
        XCTAssertEqual(try bytes(store.url(for: c3)), c3Bytes)
        XCTAssertEqual(lib.photos.map(\.id), [.file(a), c3])
        XCTAssertFalse(lib.isEdited(c2))
        XCTAssertEqual(lib.marks(for: c2), .none)
        XCTAssertEqual(lib.keywords(for: c2), [])
        XCTAssertTrue(lib.historyEntries(for: c2).isEmpty, "its undo history is gone")
        XCTAssertEqual(lib.selection, .file(a), "the selection goes to the master")
        XCTAssertFalse(lib.removeVirtualCopy(c2), "already gone")

        // The freed number is the next one taken.
        XCTAssertEqual(lib.createVirtualCopy(of: .file(a)), c2)
        XCTAssertEqual(lib.photos.map(\.id), [.file(a), c2, c3])
        XCTAssertEqual(lib.recipe(for: c2), recipe(exposure: 1))
    }

    // MARK: Move to Trash

    /// A rejected copy is never trashed (its file is the master's); a
    /// trashed master takes its copies out of the grid with it, their
    /// sidecars stay, and Undo lists them again with their recipes.
    func testTrashCarriesTheCopiesAndNeverTrashesARejectedCopy() throws {
        let trash = folder.appendingPathComponent("FakeTrash", isDirectory: true)
        let photosDir = folder.appendingPathComponent("photos", isDirectory: true)
        for d in [trash, photosDir] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let a = try makePhoto("a.png", in: photosDir)
        let b = try makePhoto("b.png", in: photosDir)
        let trasher = TrashTests.FakeTrasher(trash: trash)
        let lib = Library(rememberFolder: false, trasher: trasher)
        lib.open(photosDir)
        let ca = try XCTUnwrap(lib.createVirtualCopy(of: .file(a)))
        let cb = try XCTUnwrap(lib.createVirtualCopy(of: .file(b)))
        lib.setRecipe(recipe(exposure: 1.5), for: ca)
        lib.setFlag(.reject, for: [cb])
        XCTAssertEqual(lib.rejectedPhotos, [], "a rejected copy is not a file to trash")
        XCTAssertFalse(lib.canTrashRejects)
        XCTAssertEqual(lib.moveToTrash([cb]), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))

        lib.setFlag(.reject, for: [.file(a)])
        XCTAssertEqual(lib.rejectedPhotos, [.file(a)])
        XCTAssertEqual(lib.moveToTrash([.file(a)]), 1)
        XCTAssertEqual(lib.photos.map(\.id), [.file(b), cb], "the copy leaves with its master")
        let copyFile = SidecarStore(folder: photosDir).url(for: ca)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyFile.path), "its sidecar stays")
        XCTAssertFalse(lib.isEdited(ca))

        XCTAssertEqual(lib.undoMoveToTrash(), 1)
        XCTAssertEqual(lib.photos.map(\.id), [.file(a), ca, .file(b), cb])
        XCTAssertEqual(lib.recipe(for: ca), recipe(exposure: 1.5))
    }

    // MARK: Orphans and the flat naming

    func testAnOrphanCopyFileIsIgnoredAndKept() throws {
        let a = try makePhoto("a.png")
        try FileManager.default.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
        let orphan = SidecarStore(folder: folder).url(for: .copy(of: .file(folder.appendingPathComponent("gone.png")), number: 2))
        try SidecarStore(folder: folder).save(recipe(exposure: 1), marks: .none,
                                              for: .copy(of: .file(folder.appendingPathComponent("gone.png")), number: 2))
        let orphanBytes = try bytes(orphan)

        let lib = Library(rememberFolder: false)
        lib.open(folder)
        XCTAssertEqual(lib.photos.map(\.id), [.file(a)])
        let copy = try XCTUnwrap(lib.createVirtualCopy(of: .file(a)))
        lib.setRecipe(recipe(exposure: 2), for: copy)
        XCTAssertTrue(lib.removeVirtualCopy(copy))
        XCTAssertEqual(try bytes(orphan), orphanBytes, "never touched")
    }

    /// A source with the flat naming (an album's): assets in a flat
    /// directory, every original one file.
    private struct FlatSource: PhotoSource {
        var title = "Flat"
        var listed: [Photo]
        var directory: URL
        var original: URL
        func photos() throws -> [Photo] { listed }
        var sidecars: SidecarStore { SidecarStore(directory: directory, naming: .flat) }
        func thumbnail(for id: PhotoID, maxPixelSize: Int) -> NSImage? { nil }
        func originalFile(for id: PhotoID) async throws -> URL {
            guard listed.contains(where: { $0.id == id.master }) else { throw PhotoSourceError.notInThisSource(id) }
            return original
        }
    }

    func testTheFlatNamingDoesTheSame() async throws {
        let dir = folder.appendingPathComponent("flat", isDirectory: true)
        let original = try makePhoto("o.png")
        let source = FlatSource(listed: [Photo(id: .asset("B/L0/002"), name: "IMG_2.HEIC"),
                                         Photo(id: .asset("A/L0/001"), name: "IMG_1.HEIC")],
                                directory: dir, original: original)
        let flat = SidecarStore(directory: dir, naming: .flat)
        let a = PhotoID.asset("A/L0/001")
        // An orphan: the copy of an asset the listing does not hold.
        try flat.save(.neutral, marks: .none, for: .copy(of: .asset("Z/L0/009"), number: 2))
        let orphan = flat.url(for: .copy(of: .asset("Z/L0/009"), number: 2))

        let first = Library(rememberFolder: false)
        first.open(source)
        first.setRecipe(recipe(exposure: 1), for: a)
        let copy = try XCTUnwrap(first.createVirtualCopy(of: a))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("A_L0_001@copy2.json").path))
        let masterBytes = try bytes(flat.url(for: a))
        first.setRecipe(recipe(exposure: -1), for: copy)
        first.setRating(2, for: [copy])
        XCTAssertEqual(try bytes(flat.url(for: a)), masterBytes)
        let path = try await first.originalFile(for: copy)
        XCTAssertEqual(path, original, "a copy reads its master's original")

        let second = Library(rememberFolder: false)
        second.open(source)
        second.sort = PhotoSort(key: .name, ascending: true)
        XCTAssertEqual(second.photos.map(\.id), [a, copy, .asset("B/L0/002")])
        XCTAssertEqual(second.recipe(for: a), recipe(exposure: 1))
        XCTAssertEqual(second.recipe(for: copy), recipe(exposure: -1))
        XCTAssertEqual(second.marks(for: copy).rating, 2)
        XCTAssertEqual(second.name(for: copy), "IMG_1.HEIC")

        XCTAssertTrue(second.removeVirtualCopy(copy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flat.url(for: copy).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flat.url(for: a).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path), "the orphan is kept")
    }
}
