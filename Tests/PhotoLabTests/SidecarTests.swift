import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Sidecars: a recipe written for a photo comes back when the folder is
/// opened again, the original is never touched, a reset removes the file,
/// and edits undo and redo.
@MainActor
final class SidecarTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Writes a small PNG so `Library.scan` sees a real image.
    @discardableResult
    private func makePhoto(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
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

    private var sampleRecipe: Recipe {
        var r = Recipe.neutral
        r.set(.exposure, to: 1.25)
        r.set(.temperature, to: -30)
        r.set(.vibrance, to: 40)
        r.setEnabled(.vibrance, false)
        return r
    }

    // MARK: SidecarStore

    func testSaveThenLoadReturnsTheSameRecipe() throws {
        let photo = try makePhoto("a.png")
        let store = SidecarStore(folder: folder)
        try store.save(sampleRecipe, for: photo)

        let file = store.url(for: photo)
        XCTAssertEqual(file.path, folder.appendingPathComponent(".photolab/a.png.json").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try store.load(for: photo), sampleRecipe)
    }

    func testSidecarsOfSameStemDifferentExtensionDoNotCollide() throws {
        let jpg = try makePhoto("IMG_0001.jpg")
        let heic = try makePhoto("IMG_0001.heic")
        let store = SidecarStore(folder: folder)
        var other = sampleRecipe
        other.set(.contrast, to: 55)
        try store.save(sampleRecipe, for: jpg)
        try store.save(other, for: heic)
        XCTAssertNotEqual(store.url(for: jpg), store.url(for: heic))
        XCTAssertEqual(try store.load(for: jpg), sampleRecipe)
        XCTAssertEqual(try store.load(for: heic), other)
    }

    func testSavingLeavesTheOriginalUntouched() throws {
        let photo = try makePhoto("b.png")
        let before = try Data(contentsOf: photo)
        let dateBefore = try photo.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try SidecarStore(folder: folder).save(sampleRecipe, for: photo)
        XCTAssertEqual(try Data(contentsOf: photo), before)
        let dateAfter = try photo.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(dateBefore, dateAfter)
        // The folder itself gained only the hidden sidecar directory.
        let visible = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        XCTAssertEqual(visible.map(\.lastPathComponent), ["b.png"])
    }

    func testNeutralRecipeRemovesTheSidecar() throws {
        let photo = try makePhoto("c.png")
        let store = SidecarStore(folder: folder)
        try store.save(sampleRecipe, for: photo)
        XCTAssertTrue(store.exists(for: photo))
        try store.save(.neutral, for: photo)
        XCTAssertFalse(store.exists(for: photo))
        XCTAssertNil(try store.load(for: photo))
    }

    func testUnreadableSidecarThrowsAndIsNotOverwrittenByLoad() throws {
        let photo = try makePhoto("d.png")
        let store = SidecarStore(folder: folder)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let junk = Data("{\"version\": 1, \"recipe\": \"nope\"}".utf8)
        try junk.write(to: store.url(for: photo))
        XCTAssertThrowsError(try store.load(for: photo))
        XCTAssertEqual(try Data(contentsOf: store.url(for: photo)), junk)
        let all = store.loadAll(for: [photo])
        XCTAssertTrue(all.recipes.isEmpty)
        XCTAssertEqual(all.unreadable, [photo])
    }

    // MARK: Library: quit and reopen

    func testEditSurvivesReopeningTheFolderInANewLibrary() throws {
        let written = try makePhoto("e.png")
        try makePhoto("f.png")

        let first = Library(rememberFolder: false)
        first.open(folder)
        XCTAssertEqual(first.photos.count, 2, "the sidecar directory must not appear as a photo")
        // Ids are the library's own URLs (the scan resolves /var -> /private/var).
        let photo = try XCTUnwrap(first.photos.first { $0.name == "e.png" }).id
        first.setRecipe(sampleRecipe, for: photo)
        XCTAssertTrue(first.isEdited(photo))

        // "Quit and reopen": a fresh Library with nothing in memory, opened
        // on the file the way `PhotoLab <file>` does.
        let second = Library(rememberFolder: false)
        second.open(written)
        XCTAssertEqual(second.photos.count, 2)
        XCTAssertEqual(second.selection, photo)
        XCTAssertTrue(second.loupe)
        XCTAssertEqual(second.recipe(for: photo), sampleRecipe)
        let other = try XCTUnwrap(second.photos.first { $0.name == "f.png" }).id
        XCTAssertEqual(second.recipe(for: other), .neutral)
        XCTAssertNil(second.sidecarError)
    }

    func testResetRemovesTheSidecarAndReopensNeutral() throws {
        try makePhoto("g.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let photo = try XCTUnwrap(lib.photos.first).id
        lib.setRecipe(sampleRecipe, for: photo)
        XCTAssertTrue(SidecarStore(folder: folder).exists(for: photo))
        lib.resetRecipe(for: photo)
        XCTAssertFalse(SidecarStore(folder: folder).exists(for: photo))
        XCTAssertFalse(lib.isEdited(photo))

        let again = Library(rememberFolder: false)
        again.open(folder)
        XCTAssertEqual(again.recipe(for: photo), .neutral)
    }

    // MARK: Undo and redo

    func testUndoRedoWalkTheEditHistoryAndPersistEachStep() throws {
        try makePhoto("h.png")
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let photo = try XCTUnwrap(lib.photos.first).id
        lib.selection = photo
        XCTAssertFalse(lib.canUndo)
        XCTAssertFalse(lib.canRedo)

        var step1 = Recipe.neutral
        step1.set(.exposure, to: 0.5)
        var step2 = step1
        step2.set(.contrast, to: 20)
        lib.setRecipe(step1, for: photo)
        lib.setRecipe(step2, for: photo)
        XCTAssertTrue(lib.canUndo)

        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), step1)
        XCTAssertEqual(try store.load(for: photo), step1, "undo writes the sidecar")
        XCTAssertTrue(lib.canRedo)

        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), .neutral)
        XCTAssertFalse(store.exists(for: photo), "undo back to neutral removes the sidecar")
        XCTAssertFalse(lib.canUndo)

        lib.redo()
        lib.redo()
        XCTAssertEqual(lib.recipe(for: photo), step2)
        XCTAssertEqual(try store.load(for: photo), step2)
        XCTAssertFalse(lib.canRedo)

        // A new edit after an undo drops the redo branch.
        lib.undo()
        var branch = step1
        branch.set(.tint, to: -10)
        lib.setRecipe(branch, for: photo)
        XCTAssertFalse(lib.canRedo)
        XCTAssertEqual(lib.recipe(for: photo), branch)
    }

    func testSliderDragIsOneUndoStepAndWritesOnceAtTheEnd() throws {
        try makePhoto("i.png")
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let photo = try XCTUnwrap(lib.photos.first).id
        lib.selection = photo

        lib.beginEdit(photo)
        var r = Recipe.neutral
        for v in stride(from: 0.1, through: 2.0, by: 0.1) {
            r.set(.exposure, to: v)
            lib.setRecipe(r, for: photo)
            XCTAssertFalse(store.exists(for: photo), "no sidecar write mid-drag")
            XCTAssertFalse(lib.canUndo, "no undo step mid-drag")
        }
        lib.endEdit(photo)
        XCTAssertEqual(try store.load(for: photo), r)
        XCTAssertTrue(lib.canUndo)

        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), .neutral, "the whole drag is one step")
        XCTAssertFalse(lib.canUndo)

        // A drag that ends where it started is not an undo step.
        lib.redo()
        lib.beginEdit(photo)
        lib.setRecipe(.neutral, for: photo)
        lib.setRecipe(r, for: photo)
        lib.endEdit(photo)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), .neutral)
    }


    /// A crop handle drag in the loupe (`Library.dragCrop`): the crop moves
    /// live through the one recipe path, the whole drag is ONE undo step and
    /// ONE sidecar write, at mouse-up; edges the handle does not own keep
    /// their values.
    func testACropHandleDragIsOneUndoStepAndOneSidecarWrite() throws {
        try makePhoto("crop.png")
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let photo = try XCTUnwrap(lib.photos.first).id
        lib.selection = photo
        lib.loupe = true
        lib.cropMode = true
        var before = Recipe.neutral
        before.set(.cropLeft, to: 7)
        before.set(.exposure, to: 0.5)
        lib.setRecipe(before, for: photo)
        XCTAssertEqual(try store.load(for: photo), before)

        let fit = CGSize(width: 900, height: 600)
        for x in stride(from: -10.0, through: -90.0, by: -10.0) {
            lib.dragCrop(.bottomRight, by: CGSize(width: x, height: x), fit: fit, for: photo)
            XCTAssertEqual(try store.load(for: photo), before, "no sidecar write mid-drag")
            XCTAssertEqual(lib.recipe(for: photo).value(of: .cropRight), -x / 900 * 100, accuracy: 1e-9,
                           "the crop moves live")
        }
        let live = lib.recipe(for: photo)
        XCTAssertEqual(live.value(of: .cropBottom), 90.0 / 600 * 100, accuracy: 1e-9)
        XCTAssertEqual(live.value(of: .cropLeft), 7, "the corner owns right and bottom only")
        XCTAssertEqual(live.value(of: .cropTop), 0)
        XCTAssertEqual(live.value(of: .exposure), 0.5)

        lib.endCropDrag(photo)
        XCTAssertEqual(try store.load(for: photo), live, "one write, at mouse-up")

        // One undo takes the whole drag back; the one before it is the setRecipe.
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), before, "the whole drag is one undo step")
        XCTAssertEqual(try store.load(for: photo), before)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), .neutral)
        XCTAssertFalse(lib.canUndo)

        // The next drag starts from the crop as it is now, not the last one's start.
        lib.redo()
        lib.redo()
        lib.dragCrop(.left, by: CGSize(width: 90, height: 0), fit: fit, for: photo)
        lib.endCropDrag(photo)
        XCTAssertEqual(lib.recipe(for: photo).value(of: .cropLeft), 17, accuracy: 1e-9)
        XCTAssertEqual(lib.recipe(for: photo).value(of: .cropRight), 10, accuracy: 1e-9)
    }

    // MARK: Unreadable files are kept, never overwritten

    /// The file's bytes with `version` set to `v`: a sidecar a newer build wrote.
    private func bumpVersion(of file: URL, to v: Int) throws -> Data {
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        obj["version"] = v
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try data.write(to: file)
        return data
    }

    /// The `<file>.unreadable-<stamp>` copies beside `file`, by name.
    private func backups(of file: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(file.lastPathComponent + ".unreadable-") }
            .sorted { $0.path < $1.path }
    }

    func testSidecarFromANewerBuildIsRefusedAndKeptAsTheBackupOfTheNextSave() throws {
        let photo = try makePhoto("v.png")
        let store = SidecarStore(folder: folder)
        try store.save(sampleRecipe, for: photo)
        let file = store.url(for: photo)
        let newer = try bumpVersion(of: file, to: Sidecar.currentVersion + 1)

        // Refused on read: a version this build does not know is "unreadable", not "an edit".
        XCTAssertThrowsError(try store.load(for: photo)) { error in
            XCTAssertEqual(error as? SidecarError, .unsupportedVersion(Sidecar.currentVersion + 1))
        }
        let all = store.loadAll(for: [photo])
        XCTAssertTrue(all.recipes.isEmpty)
        XCTAssertEqual(all.unreadable, [photo])
        XCTAssertEqual(try Data(contentsOf: file), newer, "a read never rewrites")

        // The next save moves it aside, bytes intact, and writes the new sidecar beside it.
        var edit = Recipe.neutral
        edit.set(.contrast, to: 33)
        let when = Date()
        try store.save(edit, for: photo, now: when)
        let kept = try backups(of: file)
        XCTAssertEqual(kept.map(\.lastPathComponent), ["v.png.json.unreadable-\(UnreadableBackup.stamp(when))"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(kept.first)), newer)
        XCTAssertEqual(try store.load(for: photo), edit)

        // Later saves and a reset leave the backup alone: it is never deleted.
        edit.set(.contrast, to: 44)
        try store.save(edit, for: photo, now: when)
        try store.save(.neutral, for: photo, now: when)
        XCTAssertFalse(store.exists(for: photo))
        XCTAssertEqual(try backups(of: file), kept)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(kept.first)), newer)
    }

    func testJunkSidecarSurvivesAnEditThroughTheLibraryAsTheBackup() throws {
        let written = try makePhoto("j.png")
        let store = SidecarStore(folder: folder)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let junk = Data("{not json".utf8)
        try junk.write(to: store.url(for: written))

        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let photo = try XCTUnwrap(lib.photos.first).id
        XCTAssertEqual(lib.unreadableSidecars, [photo])
        XCTAssertNotNil(lib.sidecarError)
        XCTAssertEqual(lib.recipe(for: photo), .neutral)

        lib.setRecipe(sampleRecipe, for: photo)
        XCTAssertTrue(lib.unreadableSidecars.isEmpty)
        XCTAssertNil(lib.sidecarError)
        let file = store.url(for: photo)
        let kept = try backups(of: file)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept.first?.lastPathComponent.hasPrefix("j.png.json.unreadable-") ?? false, "\(kept)")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(kept.first)), junk, "the old bytes, byte for byte")
        XCTAssertEqual(try store.load(for: photo), sampleRecipe)

        // Reopen: the edit is read; the backup is neither a photo nor a sidecar.
        let again = Library(rememberFolder: false)
        again.open(folder)
        XCTAssertEqual(again.photos.count, 1)
        XCTAssertEqual(again.recipe(for: photo), sampleRecipe)
        XCTAssertNil(again.sidecarError)
    }
}
