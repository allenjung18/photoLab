import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Move Rejected Photos to Trash… (`Library.moveToTrash`, `TrashRequest`,
/// Edit › Undo Move to Trash): only rejects move, the sidecars stay, the
/// library drops the photos and Undo brings them back with their edits.
/// Every move goes through `FakeTrasher` into a temporary directory: no test
/// reaches the real Trash, ~/Downloads or the Photos library.
@MainActor
final class TrashTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var trash: URL!

    /// Moves a file into `trash` (numbered on a clash, as the Trash does);
    /// fails for a file named in `failing`.
    final class FakeTrasher: FileTrasher, @unchecked Sendable {
        let trash: URL
        var failing: Set<String> = []
        private(set) var trashed: [URL] = []

        init(trash: URL) { self.trash = trash }

        struct Refused: LocalizedError { var errorDescription: String? { "the disk said no" } }

        func trash(_ url: URL) throws -> URL {
            if failing.contains(url.lastPathComponent) { throw Refused() }
            var dest = trash.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = trash.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
                n += 1
            }
            try FileManager.default.moveItem(at: url, to: dest)
            trashed.append(url)
            return dest
        }
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-trash-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        folder = root.appendingPathComponent("photos", isDirectory: true)
        trash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        for dir in [folder!, trash!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makePhoto(_ name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? folder).appendingPathComponent(name)
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

    private func id(_ lib: Library, _ name: String) throws -> Photo.ID {
        try XCTUnwrap(lib.photos.first { $0.name == name }, "no photo \(name)").id
    }

    private func names(_ lib: Library) -> [String] { lib.photos.map(\.name) }

    private var edit: Recipe {
        var r = Recipe.neutral
        r.set(.exposure, to: 0.5)
        return r
    }

    /// a b c d e: b and d rejected (b edited), c picked, a and e unflagged.
    private func culledLibrary(_ trasher: FakeTrasher) throws -> Library {
        for n in ["a", "b", "c", "d", "e"] { try makePhoto("\(n).png") }
        let lib = Library(rememberFolder: false, trasher: trasher)
        lib.open(folder)
        XCTAssertEqual(names(lib), ["a.png", "b.png", "c.png", "d.png", "e.png"])
        lib.setFlag(.reject, for: [try id(lib, "b.png"), try id(lib, "d.png")])
        lib.setFlag(.pick, for: [try id(lib, "c.png")])
        lib.setRecipe(edit, for: try id(lib, "b.png"))
        lib.addKeywords(["blurry"], to: [try id(lib, "b.png")])
        return lib
    }

    private func exists(_ name: String, in dir: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (dir ?? folder).appendingPathComponent(name).path)
    }

    // MARK: The move

    func testOnlyRejectsMoveAndPicksAndUnflaggedStayWhateverIsSelected() throws {
        let fake = FakeTrasher(trash: trash)
        let lib = try culledLibrary(fake)
        lib.selectAll()
        XCTAssertEqual(lib.batchTargets.count, 5)
        XCTAssertTrue(lib.canTrashRejects)
        XCTAssertEqual(lib.rejectedPhotos, [try id(lib, "b.png"), try id(lib, "d.png")])

        XCTAssertEqual(lib.moveToTrash(lib.photos.map(\.id)), 2, "only the rejects of what was asked")
        XCTAssertEqual(names(lib), ["a.png", "c.png", "e.png"])
        XCTAssertEqual(fake.trashed.map(\.lastPathComponent), ["b.png", "d.png"])
        for n in ["a.png", "c.png", "e.png"] { XCTAssertTrue(exists(n), n) }
        for n in ["b.png", "d.png"] {
            XCTAssertFalse(exists(n), n)
            XCTAssertTrue(exists(n, in: trash), n)
        }
        XCTAssertFalse(lib.canTrashRejects, "no reject left")
        XCTAssertEqual(lib.trashUndo?.banner, "Moved 2 photos to the Trash")
        XCTAssertTrue(lib.trashBannerShown)
        XCTAssertNil(lib.trashError)
    }

    func testHiddenRejectsMoveTooAndTheRequestNamesCountAndFirstNames() throws {
        let fake = FakeTrasher(trash: trash)
        let lib = try culledLibrary(fake)
        for n in ["a", "e"] { lib.setFlag(.reject, for: [try id(lib, "\(n).png")]) }
        lib.filter = .picks
        XCTAssertEqual(lib.visiblePhotos.map(\.name), ["c.png"])
        lib.requestTrashRejects()
        let request = try XCTUnwrap(lib.trashRequest)
        XCTAssertEqual(request.names, ["a.png", "b.png", "d.png", "e.png"])
        XCTAssertEqual(request.title, "Move 4 rejected photos to the Trash?")
        XCTAssertTrue(request.message.hasPrefix("a.png, b.png, d.png and 1 more go to the Trash."), request.message)
        XCTAssertTrue(request.message.contains("Put Back"))
        XCTAssertEqual(lib.moveToTrash(request.targets), 4)
        XCTAssertEqual(names(lib), ["c.png"])
        XCTAssertEqual(TrashRequest(targets: [request.targets[0]], names: ["a.png"]).title,
                       "Move 1 rejected photo to the Trash?")
    }

    func testSidecarsStayInPhotolabAndTheLibraryDropsEveryMap() throws {
        let fake = FakeTrasher(trash: trash)
        let lib = try culledLibrary(fake)
        let b = try id(lib, "b.png")
        let store = SidecarStore(folder: folder)
        XCTAssertTrue(store.exists(for: b))
        let sidecar = try Data(contentsOf: store.url(for: b))
        lib.moveToTrash(lib.rejectedPhotos)
        XCTAssertTrue(store.exists(for: b), "the sidecar stays for Put Back")
        XCTAssertEqual(try Data(contentsOf: store.url(for: b)), sidecar, "and is not rewritten")
        XCTAssertTrue(store.exists(for: try id(lib, "c.png")), "the pick's sidecar is untouched")
        XCTAssertFalse(lib.isEdited(b))
        XCTAssertNil(lib.flag(for: b))
        XCTAssertEqual(lib.keywords(for: b), [])
        XCTAssertFalse(lib.photos.contains { $0.id == b })
    }

    func testAMovedAnchorGoesToTheNextKeptPhotoAndTheSelectionLosesTheMoved() throws {
        let fake = FakeTrasher(trash: trash)
        let lib = try culledLibrary(fake)
        let b = try id(lib, "b.png"), c = try id(lib, "c.png"), a = try id(lib, "a.png")
        lib.click(a)
        lib.click(b, toggling: true)  // anchor b, selection {a, b}
        XCTAssertEqual(lib.selection, b)
        lib.loupe = true
        lib.moveToTrash(lib.rejectedPhotos)
        XCTAssertEqual(lib.selection, c, "the next kept photo after b")
        XCTAssertEqual(lib.selectedIDs, [a, c])
        XCTAssertTrue(lib.loupe)

        // The last photo moved as anchor: the nearest before it.
        let lib2 = Library(rememberFolder: false, trasher: fake)
        lib2.open(folder)
        let e = try id(lib2, "e.png")
        lib2.setFlag(.reject, for: [e])
        lib2.selection = e
        lib2.moveToTrash([e])
        XCTAssertEqual(lib2.selection, c)
    }

    func testAFailingFileStaysIsReportedAndTheRestProceed() throws {
        let fake = FakeTrasher(trash: trash)
        fake.failing = ["b.png"]
        let lib = try culledLibrary(fake)
        XCTAssertEqual(lib.moveToTrash(lib.rejectedPhotos), 1)
        XCTAssertEqual(names(lib), ["a.png", "b.png", "c.png", "e.png"])
        XCTAssertTrue(exists("b.png"))
        XCTAssertFalse(exists("d.png"))
        let error = try XCTUnwrap(lib.trashError)
        XCTAssertTrue(error.contains("b.png") && error.contains("the disk said no"), error)
        XCTAssertTrue(lib.isEdited(try id(lib, "b.png")), "the failed photo keeps its edit")
        XCTAssertEqual(lib.trashUndo?.photos.map(\.photo.name), ["d.png"])
    }

    // MARK: Undo

    func testUndoRestoresFilesAndPhotosWithTheirEdits() throws {
        let fake = FakeTrasher(trash: trash)
        let lib = try culledLibrary(fake)
        let b = try id(lib, "b.png")
        lib.moveToTrash(lib.rejectedPhotos)
        XCTAssertTrue(AppCommand.command(.undoTrash).isEnabled(CommandContext(library: lib)))
        AppCommand.command(.undoTrash).perform(CommandContext(library: lib))
        XCTAssertEqual(names(lib), ["a.png", "b.png", "c.png", "d.png", "e.png"])
        XCTAssertTrue(exists("b.png") && exists("d.png"))
        XCTAssertFalse(exists("b.png", in: trash))
        XCTAssertEqual(lib.recipe(for: b), edit)
        XCTAssertEqual(lib.flag(for: b), .reject)
        XCTAssertEqual(lib.keywords(for: b), ["blurry"])
        XCTAssertNil(lib.trashUndo)
        XCTAssertFalse(lib.trashBannerShown)
        XCTAssertFalse(AppCommand.command(.undoTrash).isEnabled(CommandContext(library: lib)))
        // A fresh library reads the same edit from disk.
        let again = Library(rememberFolder: false)
        again.open(folder)
        XCTAssertEqual(again.recipe(for: b), edit)
    }

    func testUndoRefusesAPathTakenSinceAndLeavesThatFileInTheTrash() throws {
        let fake = FakeTrasher(trash: trash)
        let lib = try culledLibrary(fake)
        lib.moveToTrash(lib.rejectedPhotos)
        try Data("someone else".utf8).write(to: folder.appendingPathComponent("b.png"))
        XCTAssertEqual(lib.undoMoveToTrash(), 1)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("b.png"), encoding: .utf8),
                       "someone else", "the new file is never replaced")
        XCTAssertTrue(exists("b.png", in: trash))
        XCTAssertTrue(exists("d.png"))
        XCTAssertEqual(names(lib), ["a.png", "c.png", "d.png", "e.png"])
        let error = try XCTUnwrap(lib.trashError)
        XCTAssertTrue(error.contains("b.png"), error)
        XCTAssertTrue(lib.trashBannerShown, "the refusal is shown")
    }

    func testUndoIsValidOnlyUntilTheNextOpen() throws {
        let fake = FakeTrasher(trash: trash)
        let lib = try culledLibrary(fake)
        lib.moveToTrash(lib.rejectedPhotos)
        XCTAssertNotNil(lib.trashUndo)
        lib.open(folder)
        XCTAssertNil(lib.trashUndo)
        XCTAssertFalse(lib.trashBannerShown)
        XCTAssertEqual(lib.undoMoveToTrash(), 0)
        XCTAssertFalse(exists("b.png"))
    }

    // MARK: Sources and the command

    func testAPhotosAlbumAndALibraryWithoutATrasherOfferNothing() throws {
        try makePhoto("a.png")
        let none = Library(rememberFolder: false)
        none.open(folder)
        none.setFlag(.reject, for: none.photos.map(\.id))
        XCTAssertFalse(none.canTrashRejects, "no trasher, no command")
        XCTAssertEqual(none.moveToTrash(none.photos.map(\.id)), 0)
        XCTAssertTrue(exists("a.png"))

        // An album's photos are assets: never offered.
        let assets = Library(rememberFolder: false, trasher: FakeTrasher(trash: trash))
        assets.open(StubAssetSource(sidecars: SidecarStore(folder: root.appendingPathComponent("album", isDirectory: true))))
        assets.setFlag(.reject, for: assets.photos.map(\.id))
        XCTAssertEqual(assets.rejectedPhotos, [])
        XCTAssertFalse(assets.canTrashRejects)
    }

    func testACollectionMemberMovesAndComesBackCountedMissingMeanwhile() throws {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let x = try makePhoto("x.png", in: other)
        let y = try makePhoto("y.png")
        let store = CollectionStore(directory: root.appendingPathComponent("Collections", isDirectory: true))
        let lib = Library(rememberFolder: false, collections: store, trasher: FakeTrasher(trash: trash))
        lib.open(other)
        let c = try XCTUnwrap(lib.createCollection(named: "Mixed", adding: [try id(lib, "x.png")]))
        lib.open(folder)
        XCTAssertEqual(lib.addToCollection(c.id, ids: [try id(lib, "y.png")]), 1)
        lib.openCollection(c.id)
        XCTAssertEqual(names(lib).sorted(), ["x.png", "y.png"])
        let xid = try id(lib, "x.png")
        lib.setFlag(.reject, for: [xid])
        XCTAssertTrue(SidecarStore(folder: other).exists(for: xid), "the member's own folder")
        XCTAssertEqual(lib.moveToTrash(lib.rejectedPhotos), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: x.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: y.path))
        XCTAssertEqual(lib.missingMembers, 1)
        XCTAssertTrue(SidecarStore(folder: other).exists(for: xid))
        XCTAssertEqual(lib.undoMoveToTrash(), 1)
        XCTAssertEqual(lib.missingMembers, 0)
        XCTAssertEqual(lib.flag(for: xid), .reject)
        XCTAssertTrue(FileManager.default.fileExists(atPath: x.path))
    }

    func testTheCommandIsCommandDeleteInThePhotoMenuAndAsksFirst() throws {
        let fake = FakeTrasher(trash: trash)
        let lib = try culledLibrary(fake)
        let command = AppCommand.command(.trashRejects)
        XCTAssertEqual(command.key, .delete)
        XCTAssertEqual(command.modifiers, .command)
        XCTAssertEqual(command.placement, .photo)
        let ctx = CommandContext(library: lib)
        XCTAssertTrue(command.isEnabled(ctx))
        command.perform(ctx)
        XCTAssertEqual(lib.trashRequest?.targets.count, 2, "a confirm, nothing moved yet")
        XCTAssertTrue(exists("b.png") && exists("d.png"))
        XCTAssertEqual(fake.trashed, [])
        lib.setFlag(nil, for: lib.photos.map(\.id))
        XCTAssertFalse(command.isEnabled(ctx), "off with no reject")
        // A request made before the marks changed moves nothing it no longer names.
        XCTAssertEqual(lib.moveToTrash(lib.trashRequest!.targets), 0)
        XCTAssertTrue(exists("b.png"))
    }
}

/// Two assets that are not files: a Photos album as far as the library sees.
private struct StubAssetSource: PhotoSource {
    var title: String { "Album" }
    func photos() throws -> [Photo] {
        [Photo(id: .asset("A/L0/001"), name: "a.heic"), Photo(id: .asset("B/L0/001"), name: "b.heic")]
    }
    let sidecars: SidecarStore
    func thumbnail(for id: PhotoID, maxPixelSize: Int) -> NSImage? { nil }
    func originalFile(for id: PhotoID) async throws -> URL { throw PhotoSourceError.notInThisSource(id) }
}
