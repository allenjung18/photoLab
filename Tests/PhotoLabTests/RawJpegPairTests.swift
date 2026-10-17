import XCTest
@testable import PhotoLab

/// RAW+JPEG pairs (D-474 (a)): a folder shows a RAW and its same-named JPEG
/// or HEIC as one photo, the RAW, with the other as its `companion`; a JPEG
/// carrying its own edit, marks, keywords or virtual copy keeps its cell;
/// Trash and Rename move both files as one, and their undos bring both back.
/// The files' bytes are never images: the listing goes by extension.
@MainActor
final class RawJpegPairTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var trash: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-pairs-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        folder = root.appendingPathComponent("shoot", isDirectory: true)
        trash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        for dir in [folder!, trash!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ names: String...) throws {
        for n in names {
            let url = folder.appendingPathComponent(n)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(n.utf8).write(to: url)
        }
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    private func listing(_ lib: Library) -> [String] {
        lib.photos.map { p in p.companion.map { "\(p.name)+\($0.lastPathComponent)" } ?? p.name }
    }

    // MARK: Pairing

    func testTheRulesOfAPair() {
        let f = folder!
        func photo(_ n: String) -> Photo { Photo(url: f.appendingPathComponent(n)) }
        let input = ["a.ARW", "a.JPG", "b.ARW", "c.JPG", "d.ARW", "d.HEIC", "d.JPG", "e.arw", "E.jpg",
                     "g.ARW", "g.JPG", "h.DNG", "h.ARW", "h.JPG", "sub/i.JPG", "i.ARW", "j.HEIC", "j.CR3"].map(photo)
        let edited: Set<PhotoID> = [.file(f.appendingPathComponent("g.JPG"))]
        let out = Library.pairRawAndJPEG(input) { edited.contains($0) }
        let shown = out.map { p in p.companion.map { "\(p.name)+\($0.lastPathComponent)" } ?? p.name }
        XCTAssertEqual(shown, [
            "a.ARW+a.JPG",            // the pair
            "b.ARW", "c.JPG",         // a lone RAW, a lone JPEG
            "d.ARW+d.JPG", "d.HEIC",  // a JPEG before a HEIC; the HEIC stays its own
            "e.arw+E.jpg",            // any case
            "g.ARW", "g.JPG",         // a JPEG with its own edit keeps its cell
            "h.DNG+h.JPG", "h.ARW",   // one companion per shot: the first RAW takes it
            "i.JPG", "i.ARW",         // another folder (sub/i.JPG): no pair
            "j.CR3+j.HEIC",           // a HEIC pairs when there is no JPEG
        ])
        XCTAssertEqual(out.first { $0.name == "a.ARW" }?.pairLabel, "RAW+JPG")
        XCTAssertEqual(out.first { $0.name == "j.CR3" }?.pairLabel, "RAW+HEIC")
        XCTAssertNil(out.first { $0.name == "b.ARW" }?.pairLabel)
    }

    func testAFolderListsAPairAsOnePhotoUnlessTheJPEGHasItsOwnEdit() throws {
        try touch("a.ARW", "a.JPG", "b.ARW", "b.JPG", "c.JPG")
        try SidecarStore(folder: folder).save(.neutral, marks: Marks(flag: .pick), for: .file(folder.appendingPathComponent("b.JPG")))
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        XCTAssertEqual(listing(lib), ["a.ARW+a.JPG", "b.ARW", "b.JPG", "c.JPG"],
                       "b.JPG has a flag of its own, so it is not hidden behind b.ARW")
    }

    // MARK: Trash

    func testTrashMovesBothFilesAndUndoBringsBothBack() throws {
        try touch("a.ARW", "a.JPG", "b.png")
        let fake = TrashTests.FakeTrasher(trash: trash)
        let lib = Library(rememberFolder: false, trasher: fake)
        lib.open(folder)
        let a = try XCTUnwrap(lib.photos.first { $0.name == "a.ARW" }).id
        lib.setFlag(.reject, for: [a])
        XCTAssertEqual(lib.moveToTrash([a]), 1, "one photo")
        XCTAssertFalse(exists("a.ARW")); XCTAssertFalse(exists("a.JPG"), "the companion went with it")
        XCTAssertEqual(Set(fake.trashed.map(\.lastPathComponent)), ["a.ARW", "a.JPG"])
        XCTAssertEqual(listing(lib), ["b.png"])

        XCTAssertEqual(lib.undoMoveToTrash(), 1)
        XCTAssertTrue(exists("a.ARW")); XCTAssertTrue(exists("a.JPG"), "both back")
        XCTAssertEqual(listing(lib), ["a.ARW+a.JPG", "b.png"], "listed as the pair again")
    }

    func testAPairWhoseRAWWillNotGoLeavesTheCompanionToo() throws {
        try touch("a.ARW", "a.JPG")
        let fake = TrashTests.FakeTrasher(trash: trash)
        fake.failing = ["a.ARW"]
        let lib = Library(rememberFolder: false, trasher: fake)
        lib.open(folder)
        let a = try XCTUnwrap(lib.photos.first).id
        lib.setFlag(.reject, for: [a])
        XCTAssertEqual(lib.moveToTrash([a]), 0)
        XCTAssertTrue(exists("a.ARW")); XCTAssertTrue(exists("a.JPG"), "the companion was put back")
        XCTAssertEqual(listing(lib), ["a.ARW+a.JPG"])
        XCTAssertNotNil(lib.trashError)
    }

    // MARK: Rename

    func testRenameMovesBothFilesAndUndoMovesBothBack() throws {
        try touch("DSC1.ARW", "DSC1.JPG", "x.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let raw = try XCTUnwrap(lib.photos.first { $0.name == "DSC1.ARW" }).id
        lib.setFlag(.pick, for: [raw])
        let plan = lib.renamePlan(RenameTemplate(pattern: "trip"), for: [raw])
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(lib.rename(plan), 1, "one photo")
        XCTAssertTrue(exists("trip.ARW")); XCTAssertTrue(exists("trip.JPG"), "the companion took the new name")
        XCTAssertFalse(exists("DSC1.JPG"))
        XCTAssertEqual(listing(lib), ["trip.ARW+trip.JPG", "x.png"])
        let renamed = try XCTUnwrap(lib.photos.first { $0.name == "trip.ARW" }).id
        XCTAssertEqual(lib.flag(for: renamed), .pick, "its marks followed")
        XCTAssertFalse(exists(".photolab/trip.JPG.json"), "the companion never gets a sidecar")

        XCTAssertEqual(lib.undoRename(), 1)
        XCTAssertTrue(exists("DSC1.ARW")); XCTAssertTrue(exists("DSC1.JPG"))
        XCTAssertEqual(listing(lib), ["DSC1.ARW+DSC1.JPG", "x.png"])
    }

    func testRenameIsRefusedWhenTheCompanionsNewNameIsTaken() throws {
        try touch("DSC1.ARW", "DSC1.JPG", "trip.JPG")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let raw = try XCTUnwrap(lib.photos.first { $0.name == "DSC1.ARW" }).id
        let plan = lib.renamePlan(RenameTemplate(pattern: "trip"), for: [raw])
        XCTAssertEqual(plan.refusal, .fileExists("trip.JPG"))
        XCTAssertEqual(lib.rename(plan), 0)
        XCTAssertTrue(exists("DSC1.JPG")); XCTAssertTrue(exists("trip.JPG"))
    }

    // MARK: Review fixes

    func testAnOverwriteExportNeverReplacesTheCompanion() async throws {
        try touch("DSC1.ARW", "DSC1.JPG")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let raw = try XCTUnwrap(lib.photos.first).id
        XCTAssertNotNil(lib.photos.first?.companion)
        let items = try await lib.exportItems(for: [raw])
        let companion = folder.appendingPathComponent("DSC1.JPG")
        XCTAssertTrue(items[0].protected.map(\.standardizedFileURL.path).contains(companion.standardizedFileURL.path),
                      "the companion is an original too: \(items[0].protected.map(\.path))")

        // End to end: a decodable source whose export is named like the companion.
        let other = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let src = other.appendingPathComponent("DSC1.png")
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(src as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        var o = ExportOptions()
        o.collision = .overwrite
        o.format = .jpeg
        let before = try Data(contentsOf: companion)
        XCTAssertThrowsError(try Exporter.export(src, recipe: .neutral, into: folder, options: o, protected: items[0].protected))
        XCTAssertEqual(try Data(contentsOf: companion), before, "the camera JPEG untouched")
    }

    func testAJPEGWithAnEditInAParentFoldersStoreIsNotPaired() throws {
        try touch("sub/a.ARW", "sub/a.JPG")
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        // The parent opened once and flagged the JPEG: its sidecar lives in the parent's store.
        try SidecarStore(folder: folder).save(.neutral, marks: Marks(flag: .pick), for: .file(sub.appendingPathComponent("a.JPG")))
        let lib = Library(rememberFolder: false)
        lib.open(sub)
        XCTAssertEqual(listing(lib), ["a.ARW", "a.JPG"], "the flagged JPEG keeps its cell")
    }

    func testRenameIsRefusedWhenTheCompanionHasAnEditSavedElsewhere() throws {
        try touch("sub/a.ARW", "sub/a.JPG")
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        let lib = Library(rememberFolder: false)
        lib.open(sub)
        XCTAssertEqual(listing(lib), ["a.ARW+a.JPG"])
        // An edit for the JPEG appears in another store after the listing (another window, a collection root).
        try SidecarStore(folder: folder).save(.neutral, marks: Marks(flag: .pick), for: .file(sub.appendingPathComponent("a.JPG")))
        let raw = try XCTUnwrap(lib.photos.first).id
        let plan = lib.renamePlan(RenameTemplate(pattern: "trip"), for: [raw])
        XCTAssertEqual(plan.refusal, .companionHasEdit("a.JPG"))
        XCTAssertEqual(lib.rename(plan), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sub.appendingPathComponent("a.JPG").path))
    }

    func testTwoPairsCannotRenameOntoOneCompanionName() throws {
        try touch("A.CR2", "A.JPG", "B.NEF", "B.JPG")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let plan = lib.renamePlan(RenameTemplate(pattern: "X"), for: lib.photos.map(\.id))
        XCTAssertEqual(plan.refusal, .duplicate("X.JPG"), "X.CR2 and X.NEF differ, their JPEGs would not")
        XCTAssertEqual(lib.rename(plan), 0)
        for n in ["A.CR2", "A.JPG", "B.NEF", "B.JPG"] { XCTAssertTrue(exists(n), n) }
    }

    func testACollectionHoldingTheCompanionFollowsTheRename() throws {
        try touch("DSC1.JPG")
        let collections = CollectionStore(directory: root.appendingPathComponent("Collections", isDirectory: true))
        let lib = Library(rememberFolder: false, collections: collections)
        lib.open(folder)
        let c = try XCTUnwrap(lib.createCollection(named: "Picks", adding: [try XCTUnwrap(lib.photos.first).id]))
        try touch("DSC1.ARW")   // the RAW arrives later: the next open pairs them
        lib.open(folder)
        XCTAssertEqual(listing(lib), ["DSC1.ARW+DSC1.JPG"])
        let raw = try XCTUnwrap(lib.photos.first).id
        XCTAssertEqual(lib.rename(lib.renamePlan(RenameTemplate(pattern: "trip"), for: [raw])), 1)
        XCTAssertEqual(collections.load(c.id)?.members.map(\.file.lastPathComponent), ["trip.JPG"],
                       "the member follows its file")
    }
}
