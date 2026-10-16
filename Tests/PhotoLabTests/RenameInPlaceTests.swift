import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Photo › Rename… (`RenamePlan`, `Library.rename`, Edit › Undo Rename):
/// the files are renamed where they are, each sidecar follows its photo,
/// every library map follows the id, a clash refuses the whole batch, a
/// failure part-way moves the done ones back, and Undo restores the names.
/// Every file lives in a temporary directory: no test touches ~/Downloads,
/// the Photos library or the app's own collections.
@MainActor
final class RenameInPlaceTests: XCTestCase {
    private var root: URL!
    private var folder: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-rename-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        folder = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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

    /// The folder's files and its `.photolab/` files, sorted.
    private func listing(_ dir: URL? = nil) -> [String] {
        let d = dir ?? folder!
        let files = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        let side = (try? FileManager.default.contentsOfDirectory(
            atPath: d.appendingPathComponent(SidecarStore.directoryName).path)) ?? []
        return files.filter { $0 != SidecarStore.directoryName }.sorted() + side.sorted().map { ".photolab/" + $0 }
    }

    private func exists(_ name: String, in dir: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (dir ?? folder).appendingPathComponent(name).path)
    }

    private var edit: Recipe {
        var r = Recipe.neutral
        r.set(.exposure, to: 0.5)
        return r
    }

    /// a b c: a edited, picked and rated 3; b with a keyword; c untouched.
    private func editedLibrary(collections: CollectionStore? = nil) throws -> Library {
        for n in ["a", "b", "c"] { try makePhoto("\(n).png") }
        let lib = Library(rememberFolder: false, collections: collections)
        lib.open(folder)
        XCTAssertEqual(names(lib), ["a.png", "b.png", "c.png"])
        let a = try id(lib, "a.png")
        lib.setRecipe(edit, for: a)
        lib.setFlag(.pick, for: [a])
        lib.setRating(3, for: [a])
        lib.addKeywords(["harbour"], to: [try id(lib, "b.png")])
        return lib
    }

    // MARK: The rename

    func testThreeFilesRenamedWithSeqKeepTheirEditsMarksAndKeywordsAcrossAReopen() throws {
        let lib = try editedLibrary()
        lib.selectAll()
        let plan = lib.renamePlan(RenameTemplate(pattern: "trip-{seq}"), for: lib.batchTargets)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.entries.map(\.new.lastPathComponent), ["trip-1.png", "trip-2.png", "trip-3.png"])
        XCTAssertEqual(lib.rename(plan), 3)

        XCTAssertEqual(listing(), ["trip-1.png", "trip-2.png", "trip-3.png",
                                   ".photolab/trip-1.png.json", ".photolab/trip-2.png.json"])
        let store = SidecarStore(folder: folder)
        XCTAssertEqual(try store.read(for: folder.appendingPathComponent("trip-1.png"))?.original, "trip-1.png",
                       "the sidecar names its new original")
        XCTAssertEqual(names(lib), ["trip-1.png", "trip-2.png", "trip-3.png"])
        let t1 = try id(lib, "trip-1.png")
        XCTAssertEqual(lib.recipe(for: t1), edit)
        XCTAssertEqual(lib.marks(for: t1), Marks(flag: .pick, rating: 3))
        XCTAssertEqual(lib.keywords(for: try id(lib, "trip-2.png")), ["harbour"])
        XCTAssertEqual(lib.renameUndo?.banner, "Renamed 3 photos")
        XCTAssertTrue(lib.renameBannerShown)

        let again = Library(rememberFolder: false)
        again.open(folder)
        XCTAssertEqual(names(again), ["trip-1.png", "trip-2.png", "trip-3.png"])
        let r1 = try id(again, "trip-1.png")
        XCTAssertEqual(again.recipe(for: r1), edit, "the edit is read back from the moved sidecar")
        XCTAssertEqual(again.marks(for: r1), Marks(flag: .pick, rating: 3))
        XCTAssertEqual(again.keywords(for: try id(again, "trip-2.png")), ["harbour"])
        XCTAssertTrue(again.unreadableSidecars.isEmpty)
    }

    func testTheSelectionTheAnchorAndTheEditHistoryFollowTheId() throws {
        let lib = try editedLibrary()
        let a = try id(lib, "a.png"), b = try id(lib, "b.png")
        lib.click(a)
        lib.click(b, toggling: true)
        XCTAssertEqual(lib.selection, b)
        lib.loupe = true
        XCTAssertEqual(lib.rename(lib.renamePlan(RenameTemplate(pattern: "{name}-x"), for: lib.batchTargets)), 2)
        let ax = try id(lib, "a-x.png"), bx = try id(lib, "b-x.png")
        XCTAssertEqual(lib.selection, bx)
        XCTAssertEqual(lib.selectedIDs, [ax, bx])
        XCTAssertEqual(lib.batchTargets, [ax, bx])
        XCTAssertTrue(lib.loupe)
        // a's undo stack moved with it: ⌘Z on it takes the edit back.
        lib.selection = ax
        XCTAssertTrue(lib.canUndo)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: ax), .neutral)
        XCTAssertFalse(lib.isEdited(a), "nothing is left under the old id")
        XCTAssertEqual(lib.marks(for: a), .none)
    }

    func testTheExtensionIsKeptAsSpelledWhateverTheTemplateSays() throws {
        try makePhoto("IMG_1.PNG")
        try makePhoto("shot.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.selectAll()
        let plan = lib.renamePlan(RenameTemplate(pattern: "{name}.jpg"), for: lib.batchTargets)
        XCTAssertEqual(plan.entries.map(\.new.lastPathComponent), ["IMG_1.jpg.PNG", "shot.jpg.png"])
        XCTAssertEqual(lib.rename(plan), 2)
        XCTAssertTrue(exists("IMG_1.jpg.PNG"))
        XCTAssertTrue(exists("shot.jpg.png"))
    }

    func testAClashRefusesTheWholeBatchAndTouchesNoFile() throws {
        let lib = try editedLibrary()
        try makePhoto("x-2.png")
        lib.open(folder)
        let ab = [try id(lib, "a.png"), try id(lib, "b.png")]
        let before = listing()
        let sidecarBefore = try Data(contentsOf: SidecarStore(folder: folder).url(for: folder.appendingPathComponent("a.png")))

        let taken = lib.renamePlan(RenameTemplate(pattern: "x-{seq}"), for: ab)
        XCTAssertEqual(taken.refusal, .fileExists("x-2.png"), "x-1 is free, x-2 is not: nothing moves")
        XCTAssertEqual(lib.rename(taken), 0)
        XCTAssertEqual(lib.renamePlan(RenameTemplate(pattern: "same"), for: ab).refusal, .duplicate("same.png"))
        XCTAssertEqual(lib.renamePlan(RenameTemplate(pattern: "{name}"), for: ab).refusal, .nothingChanges)
        XCTAssertEqual(lib.renamePlan(RenameTemplate(pattern: ".{name}"), for: ab).refusal, .hidden(".a.png"))
        // An edit left for a file of that name once would be overwritten.
        let orphan = SidecarStore(folder: folder)
        try orphan.save(edit, for: folder.appendingPathComponent("gone.png"))
        let orphanBefore = listing()
        XCTAssertEqual(lib.renamePlan(RenameTemplate(pattern: "gone"), for: [ab[0]]).refusal, .sidecarExists("gone.png"))
        XCTAssertEqual(lib.rename(lib.renamePlan(RenameTemplate(pattern: "gone"), for: [ab[0]])), 0)

        XCTAssertEqual(listing(), orphanBefore)
        XCTAssertEqual(before + [], listing().filter { $0 != ".photolab/gone.png.json" })
        XCTAssertEqual(try Data(contentsOf: SidecarStore(folder: folder).url(for: folder.appendingPathComponent("a.png"))),
                       sidecarBefore)
        XCTAssertEqual(names(lib), ["a.png", "b.png", "c.png", "x-2.png"])
        XCTAssertNil(lib.renameUndo)
    }

    func testAFailureOnFileTwoMovesFileOneBack() throws {
        let lib = try editedLibrary()
        lib.selectAll()
        let plan = lib.renamePlan(RenameTemplate(pattern: "n{seq}"), for: lib.batchTargets)
        XCTAssertNil(plan.refusal)
        // The name is taken after the preview: the move of b fails
        // (moveItem never replaces a file), and a goes back.
        try Data("not a photo".utf8).write(to: folder.appendingPathComponent("n2.png"))
        let before = listing()
        XCTAssertEqual(lib.rename(plan), 0)

        XCTAssertEqual(listing(), before)
        XCTAssertTrue(exists("a.png"))
        XCTAssertFalse(exists("n1.png"))
        XCTAssertEqual(try SidecarStore(folder: folder).read(for: folder.appendingPathComponent("a.png"))?.original, "a.png",
                       "file one's sidecar is back with its own name")
        XCTAssertEqual(names(lib), ["a.png", "b.png", "c.png"])
        XCTAssertEqual(lib.recipe(for: try id(lib, "a.png")), edit)
        XCTAssertTrue(lib.renameError?.contains("b.png") == true, lib.renameError ?? "no error")
        XCTAssertTrue(lib.renameBannerShown)
        XCTAssertNil(lib.renameUndo)
    }

    func testUndoRestoresTheNamesAndTheSidecars() throws {
        let lib = try editedLibrary()
        lib.selectAll()
        let before = listing()
        let sidecarBefore = try SidecarStore(folder: folder).read(for: folder.appendingPathComponent("a.png"))
        XCTAssertFalse(AppCommand.command(.undoRename).isEnabled(CommandContext(library: lib)))
        XCTAssertEqual(lib.rename(lib.renamePlan(RenameTemplate(pattern: "{seq}"), for: lib.batchTargets)), 3)
        XCTAssertTrue(AppCommand.command(.undoRename).isEnabled(CommandContext(library: lib)))

        AppCommand.command(.undoRename).perform(CommandContext(library: lib))
        XCTAssertEqual(listing(), before)
        XCTAssertEqual(try SidecarStore(folder: folder).read(for: folder.appendingPathComponent("a.png")), sidecarBefore,
                       "the sidecar is back, its original the old name")
        XCTAssertEqual(names(lib), ["a.png", "b.png", "c.png"])
        let a = try id(lib, "a.png")
        XCTAssertEqual(lib.recipe(for: a), edit)
        XCTAssertEqual(lib.marks(for: a), Marks(flag: .pick, rating: 3))
        XCTAssertNil(lib.renameUndo)
        XCTAssertFalse(lib.renameBannerShown)
        XCTAssertEqual(lib.undoRename(), 0, "once")
    }

    func testUndoIsGoneAfterTheNextOpen() throws {
        let lib = try editedLibrary()
        lib.selectAll()
        XCTAssertEqual(lib.rename(lib.renamePlan(RenameTemplate(pattern: "z{seq}"), for: lib.batchTargets)), 3)
        lib.open(folder)
        XCTAssertNil(lib.renameUndo)
        XCTAssertEqual(lib.undoRename(), 0)
        XCTAssertTrue(exists("z1.png"))
    }

    func testOnlyTheChangingPhotosMoveAndAStalePlanMovesNothing() throws {
        try makePhoto("1.png")
        try makePhoto("b.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.selectAll()
        let plan = lib.renamePlan(RenameTemplate(pattern: "{seq}"), for: lib.batchTargets)
        XCTAssertEqual(plan.entries.map(\.new.lastPathComponent), ["1.png", "2.png"])
        XCTAssertEqual(plan.changing.map(\.old.lastPathComponent), ["b.png"])
        XCTAssertEqual(lib.rename(plan), 1)
        XCTAssertEqual(listing(), ["1.png", "2.png"])
        XCTAssertEqual(lib.renameUndo?.banner, "Renamed 1 photo")

        let stale = lib.renamePlan(RenameTemplate(pattern: "s{seq}"), for: lib.batchTargets)
        XCTAssertNil(stale.refusal)
        let elsewhere = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        lib.open(elsewhere)  // another source: the plan's photos are not listed
        XCTAssertEqual(lib.rename(stale), 0)
        XCTAssertEqual(listing(), ["1.png", "2.png"])
    }

    // MARK: Virtual copies

    func testAMastersVirtualCopyFollowsItWithItsOwnRecipe() throws {
        let lib = try editedLibrary()
        let a = try id(lib, "a.png")
        let copy = try XCTUnwrap(lib.createVirtualCopy(of: a))
        var other = Recipe.neutral
        other.set(.contrast, to: 30)
        lib.setRecipe(other, for: copy)
        lib.setFlag(.reject, for: [copy])
        XCTAssertTrue(exists(".photolab/a.png@copy2.json"))

        // Only the copy is selected: it stands for its master, one file.
        lib.selection = copy
        XCTAssertTrue(lib.canRename(lib.batchTargets))
        let plan = lib.renamePlan(RenameTemplate(pattern: "kept"), for: lib.batchTargets)
        XCTAssertEqual(plan.entries.map(\.id), [a])
        XCTAssertEqual(lib.rename(plan), 1)

        XCTAssertEqual(listing(), ["b.png", "c.png", "kept.png",
                                   ".photolab/b.png.json", ".photolab/kept.png.json", ".photolab/kept.png@copy2.json"])
        let store = SidecarStore(folder: folder)
        let kept = try XCTUnwrap(lib.photos.first { $0.name == "kept.png" && !$0.id.isCopy }).id
        let keptCopy = PhotoID.copy(of: kept, number: 2)
        XCTAssertEqual(try store.read(for: keptCopy)?.original, "kept.png")
        XCTAssertEqual(lib.selection, keptCopy, "the anchor was the copy and stays on it")
        XCTAssertEqual(lib.recipe(for: keptCopy), other)
        XCTAssertEqual(lib.flag(for: keptCopy), .reject)
        XCTAssertEqual(lib.recipe(for: kept), edit)
        XCTAssertEqual(lib.photos.filter { $0.id.master == kept }.map(\.name), ["kept.png", "kept.png"])

        let again = Library(rememberFolder: false)
        again.open(folder)
        let ids = again.photos.filter { $0.name == "kept.png" }.map(\.id)
        XCTAssertEqual(ids, [kept, keptCopy])
        XCTAssertEqual(again.recipe(for: keptCopy), other, "the copy reopens with its recipe")
        XCTAssertEqual(again.flag(for: keptCopy), .reject)
        XCTAssertEqual(again.recipe(for: kept), edit)

        // Undo carries the copy back too.
        XCTAssertEqual(lib.undoRename(), 1)
        XCTAssertTrue(exists(".photolab/a.png@copy2.json"))
        XCTAssertEqual(lib.recipe(for: .copy(of: a, number: 2)), other)
    }

    func testAnEditLeftForACopyOfTheNewNameRefuses() throws {
        let lib = try editedLibrary()
        try SidecarStore(folder: folder).save(edit, marks: .none, for: .copy(of: .file(folder.appendingPathComponent("z.png")), number: 2))
        XCTAssertEqual(lib.renamePlan(RenameTemplate(pattern: "z"), for: [try id(lib, "c.png")]).refusal,
                       .sidecarExists("z.png"))
    }

    // MARK: Collections

    func testACollectionMembersIdFollowsTheRename() throws {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try makePhoto("x.png", in: other)
        try makePhoto("y.png")
        let collections = CollectionStore(directory: root.appendingPathComponent("Collections", isDirectory: true))
        let lib = Library(rememberFolder: false, collections: collections)
        lib.open(other)
        let c = try XCTUnwrap(lib.createCollection(named: "Mixed", adding: [try id(lib, "x.png")]))
        lib.open(folder)
        XCTAssertEqual(lib.addToCollection(c.id, ids: [try id(lib, "y.png")]), 1)

        // Renamed inside the open collection: the edit lands in x's own folder.
        lib.openCollection(c.id)
        let x = try id(lib, "x.png")
        lib.setFlag(.reject, for: [x])
        XCTAssertEqual(lib.rename(lib.renamePlan(RenameTemplate(pattern: "{name}-kept"), for: [x])), 1)
        let xk = try id(lib, "x-kept.png")
        XCTAssertEqual(lib.flag(for: xk), .reject)
        XCTAssertEqual(listing(other), ["x-kept.png", ".photolab/x-kept.png.json"])
        XCTAssertEqual(lib.openCollection?.member(for: xk)?.root, other)
        XCTAssertEqual(collections.load(c.id)?.members.map(\.file.lastPathComponent), ["x-kept.png", "y.png"])
        XCTAssertEqual(lib.missingMembers, 0)

        // Renamed in its folder: the saved collection follows too.
        lib.open(folder)
        XCTAssertEqual(lib.rename(lib.renamePlan(RenameTemplate(pattern: "why"), for: [try id(lib, "y.png")])), 1)
        XCTAssertEqual(collections.load(c.id)?.members.map(\.file.lastPathComponent), ["x-kept.png", "why.png"])

        let again = Library(rememberFolder: false, collections: collections)
        again.openCollection(c.id)
        XCTAssertEqual(names(again).sorted(), ["why.png", "x-kept.png"])
        XCTAssertEqual(again.missingMembers, 0)
        XCTAssertEqual(again.flag(for: try id(again, "x-kept.png")), .reject, "read from the member's own folder")
    }

    func testAnEditKeptUnderAnotherRootFollowsTheRenameEitherWay() throws {
        // sub/a.png has two edits: the collection's (rooted at sub, added
        // while sub was open) and the parent folder's (sub/a.png.json there).
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try makePhoto("a.png", in: sub)
        let collections = CollectionStore(directory: root.appendingPathComponent("Collections", isDirectory: true))
        let lib = Library(rememberFolder: false, collections: collections)
        lib.open(sub)
        let c = try XCTUnwrap(lib.createCollection(named: "C", adding: [try id(lib, "a.png")]))
        lib.openCollection(c.id)
        lib.setFlag(.pick, for: [try id(lib, "a.png")])
        _ = lib.createVirtualCopy(of: try id(lib, "a.png"))
        lib.open(folder)
        lib.setRecipe(edit, for: try id(lib, "a.png"))
        XCTAssertEqual(listing(sub), ["a.png", ".photolab/a.png.json", ".photolab/a.png@copy2.json"])
        XCTAssertTrue(exists(".photolab/sub/a.png.json"))

        // Renamed from the parent folder: the collection's edit follows too.
        XCTAssertEqual(lib.rename(lib.renamePlan(RenameTemplate(pattern: "b"), for: [try id(lib, "a.png")])), 1)
        XCTAssertEqual(listing(sub), ["b.png", ".photolab/b.png.json", ".photolab/b.png@copy2.json"])
        XCTAssertTrue(exists(".photolab/sub/b.png.json"))
        XCTAssertFalse(exists(".photolab/sub/a.png.json"))
        lib.openCollection(c.id)
        XCTAssertEqual(lib.flag(for: try id(lib, "b.png")), .pick, "the collection's own edit, under the new name")
        XCTAssertEqual(lib.photos.count, 2, "and its copy")

        // Renamed inside the collection: the parent folder's edit follows.
        let b = try XCTUnwrap(lib.photos.first { !$0.id.isCopy }).id
        XCTAssertEqual(lib.rename(lib.renamePlan(RenameTemplate(pattern: "c"), for: [b])), 1)
        XCTAssertTrue(exists(".photolab/sub/c.png.json"))
        XCTAssertFalse(exists(".photolab/sub/b.png.json"))
        lib.open(folder)
        XCTAssertEqual(lib.recipe(for: try id(lib, "c.png")), edit)

        // Undo moves every root's edit back.
        lib.openCollection(c.id)
        XCTAssertEqual(lib.rename(lib.renamePlan(RenameTemplate(pattern: "d"), for: [try XCTUnwrap(lib.photos.first { !$0.id.isCopy }).id])), 1)
        XCTAssertEqual(lib.undoRename(), 1)
        XCTAssertEqual(listing(sub), ["c.png", ".photolab/c.png.json", ".photolab/c.png@copy2.json"])
        XCTAssertTrue(exists(".photolab/sub/c.png.json"))
    }

    func testAnEditUnderTheNewNameInAnotherRootRefuses() throws {
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try makePhoto("a.png", in: sub)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.setRecipe(edit, for: try id(lib, "a.png"))  // the parent's store holds a's edit
        lib.open(sub)
        try SidecarStore(folder: folder).save(edit, for: sub.appendingPathComponent("z.png"))  // and one for z
        XCTAssertEqual(lib.renamePlan(RenameTemplate(pattern: "z"), for: [try id(lib, "a.png")]).refusal,
                       .sidecarExists("z.png"))
    }

    // MARK: What is offered

    func testOnlyListedFilePhotosOfAFolderOrACollectionAreOffered() throws {
        let lib = try editedLibrary()
        XCTAssertTrue(lib.canRename([try id(lib, "a.png")]))
        XCTAssertFalse(lib.canRename([]))
        XCTAssertFalse(lib.canRename([.file(folder.appendingPathComponent("nope.png"))]))
        XCTAssertFalse(lib.canRename([.asset("A/L0/001")]))
        XCTAssertEqual(lib.renamePlan(RenameTemplate(pattern: "q"), for: [.asset("A/L0/001")]).refusal, .notFiles)
        XCTAssertFalse(Library(rememberFolder: false).canRename([try id(lib, "a.png")]), "nothing open")
    }

    func testTheCommandIsInThePhotoMenuAndOpensTheSheet() throws {
        let lib = try editedLibrary()
        let command = AppCommand.command(.renameInPlace)
        XCTAssertEqual(command.placement, .photo)
        XCTAssertNil(command.key)
        XCTAssertFalse(command.isEnabled(CommandContext(library: lib)), "nothing selected")
        lib.selectAll()
        let ctx = CommandContext(library: lib)
        XCTAssertTrue(command.isEnabled(ctx))
        XCTAssertEqual(command.menuTitle(ctx), "Rename 3 Photos…")
        command.perform(ctx)
        XCTAssertEqual(lib.renameRequest?.targets, lib.batchTargets)
        XCTAssertEqual(listing().count, 5, "the sheet renames, the command does not")
    }

    func testAMoveToTheTrashDropsTheRenameUndo() throws {
        final class Mover: FileTrasher, @unchecked Sendable {
            let trash: URL
            init(_ trash: URL) { self.trash = trash }
            func trash(_ url: URL) throws -> URL {
                let dest = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            }
        }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for n in ["a", "b"] { try makePhoto("\(n).png") }
        let lib = Library(rememberFolder: false, trasher: Mover(bin))
        lib.open(folder)
        lib.selectAll()
        XCTAssertEqual(lib.rename(lib.renamePlan(RenameTemplate(pattern: "r{seq}"), for: lib.batchTargets)), 2)
        lib.setFlag(.reject, for: [try id(lib, "r1.png")])
        XCTAssertEqual(lib.moveToTrash(lib.rejectedPhotos), 1)
        XCTAssertNil(lib.renameUndo)
        XCTAssertNotNil(lib.trashUndo)
    }

    // MARK: The caches

    func testTheThumbnailCacheMovesToTheNewId() async throws {
        let thumbs = Thumbnails(decode: { _, _ in NSImage(size: NSSize(width: 4, height: 4)) })
        let old = PhotoID.file(folder.appendingPathComponent("a.png"))
        let new = PhotoID.file(folder.appendingPathComponent("b.png"))
        let image = await thumbs.thumbnail(for: old)
        XCTAssertNotNil(image)
        thumbs.rename(old, to: new)
        XCTAssertNil(thumbs.cached(old))
        XCTAssertTrue(thumbs.cached(new) === image)
    }

    func testCaptureDatesAndInfoMoveToTheNewId() async throws {
        let url = try makePhoto("a.png")
        let when = Date(timeIntervalSince1970: 1_000_000)
        let dates = CaptureDates(reader: { _ in when })
        let old = Photo(url: url), new = Photo(url: folder.appendingPathComponent("b.png"))
        XCTAssertEqual(dates.date(for: old), when)
        dates.rename(old.id, to: new.id)
        let unread = CaptureDates(reader: { _ in nil })
        unread.remember(when, for: old.id)
        unread.rename(old.id, to: new.id)
        XCTAssertEqual(unread.date(for: new), when, "the date read for a.png is b.png's")

        let info = PhotoInfoStore(captureDates: dates)
        _ = await info.info(for: old, file: url)
        info.rename(old.id, to: new.id, name: "b.png")
        XCTAssertNil(info.cached(old.id))
        XCTAssertEqual(info.cached(new.id)?.fileName, "b.png")
    }
}
