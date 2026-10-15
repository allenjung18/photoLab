import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Library edit state and launch (code review of chunks 1–7, M1/M2/M3): a
/// disabled-only edit is still an edit, closing a drag never strands it on
/// another photo, and opening a path that does not exist opens nothing.
@MainActor
final class EditStateTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-editstate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
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

    // MARK: M1 — isNeutral (renders as identity) versus isDefault (no edit)

    func testDisabledOnlyRecipeIsNeutralButNotDefault() {
        var r = Recipe.neutral
        XCTAssertTrue(r.isNeutral)
        XCTAssertTrue(r.isDefault)
        r.set(.exposure, to: 2)
        XCTAssertFalse(r.isNeutral)
        XCTAssertFalse(r.isDefault)
        r.setEnabled(.exposure, false)
        XCTAssertTrue(r.isNeutral, "a disabled entry renders as identity")
        XCTAssertFalse(r.isDefault, "but the kept value is still an edit")
        // A sidecar that lists the kinds in another order is still the default.
        let shuffled = Recipe(adjustments: Recipe.neutral.adjustments.reversed())
        XCTAssertTrue(shuffled.isDefault)
    }

    func testDisabledOnlyEditSurvivesInMemoryAndOnDisk() throws {
        try makePhoto("a.png")
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let id = try XCTUnwrap(lib.photos.first).id
        var r = Recipe.neutral
        r.set(.exposure, to: 2)
        lib.setRecipe(r, for: id)
        XCTAssertTrue(store.exists(for: id))
        r.setEnabled(.exposure, false)
        lib.setRecipe(r, for: id)
        XCTAssertEqual(lib.recipe(for: id).value(of: .exposure), 2, "M1: the disabled value must stay in memory")
        XCTAssertTrue(store.exists(for: id), "M1: the sidecar must survive a disable-only edit")
        XCTAssertTrue(lib.isEdited(id), "M1: a disabled slider is still an edit")
        let again = Library(rememberFolder: false)
        again.open(folder)
        XCTAssertEqual(again.recipe(for: id).value(of: .exposure), 2, "M1: reopen must read the disabled value back")
        XCTAssertFalse(again.recipe(for: id).isEnabled(.exposure))
        // Enabling it again restores the look with no retyping.
        r.setEnabled(.exposure, true)
        again.setRecipe(r, for: id)
        XCTAssertEqual(try store.load(for: id)?.effective(.exposure), 2)
        // A real reset still removes the sidecar.
        again.resetRecipe(for: id)
        XCTAssertFalse(store.exists(for: id))
        XCTAssertFalse(again.isEdited(id))
    }

    // MARK: M2 — endEdit closes whatever edit is open

    func testEndEditOnAnotherPhotoStillClosesTheOpenEdit() throws {
        try makePhoto("a.png"); try makePhoto("b.png")
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let a = lib.photos[0].id, b = lib.photos[1].id
        lib.selection = a
        lib.beginEdit(a)
        var x = Recipe.neutral
        x.set(.exposure, to: 1)
        lib.setRecipe(x, for: a)
        lib.endEdit(b)                       // the panel's photo changed mid-drag
        XCTAssertTrue(store.exists(for: a), "M2: A's drag must be persisted when the edit closes")
        XCTAssertEqual(try store.load(for: a), x)
        XCTAssertTrue(lib.canUndo, "M2: A's drag must be an undo step")
        var y = x
        y.set(.contrast, to: 20)
        lib.setRecipe(y, for: a)             // a later plain edit on A
        XCTAssertEqual(try store.load(for: a), y, "M2: later edits on A must persist")
        lib.undo()
        XCTAssertEqual(lib.recipe(for: a), x)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: a), .neutral, "the drag was one step")
    }

    func testBeginEditOnAnotherPhotoEndsTheOpenEdit() throws {
        try makePhoto("a.png"); try makePhoto("b.png")
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let a = lib.photos[0].id, b = lib.photos[1].id
        lib.selection = a
        lib.beginEdit(a)
        var x = Recipe.neutral
        x.set(.exposure, to: 1)
        lib.setRecipe(x, for: a)
        XCTAssertFalse(store.exists(for: a), "mid-drag: nothing written yet")
        lib.beginEdit(b)                     // a drag starts on B before A's ended
        XCTAssertEqual(try store.load(for: a), x, "A's drag is closed and written")
        XCTAssertTrue(lib.canUndo)
        var z = Recipe.neutral
        z.set(.contrast, to: 10)
        lib.setRecipe(z, for: b)
        XCTAssertFalse(store.exists(for: b), "B is now the open edit: no write mid-drag")
        lib.endEdit(b)
        XCTAssertEqual(try store.load(for: b), z)
        // beginEdit twice on the same photo keeps the first `before`.
        lib.beginEdit(b)
        var w = z
        w.set(.contrast, to: 30)
        lib.setRecipe(w, for: b)
        lib.beginEdit(b)
        lib.endEdit(b)
        lib.selection = b
        lib.undo()
        XCTAssertEqual(lib.recipe(for: b), z, "the second beginEdit on B did not reset the undo point")
    }

    // MARK: M3 — open of a missing path

    func testOpenOfAMissingPathDoesNotOpenItsParent() throws {
        let lib = Library(rememberFolder: false)
        lib.open(folder.appendingPathComponent("does-not-exist"))
        XCTAssertNil(lib.folder, "M3: a missing path must not open its parent")
        XCTAssertNotNil(lib.openError)
        let arg = URL(fileURLWithPath: "-NSDocumentRevisionsDebugMode")
        let lib2 = Library(rememberFolder: false)
        lib2.open(arg)
        XCTAssertNil(lib2.folder, "M3: a flag-like argument must not open the cwd (\(lib2.folder?.path ?? "nil"))")
    }

    func testOpenOfAMissingPathKeepsTheCurrentFolder() throws {
        try makePhoto("a.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        XCTAssertEqual(lib.folder, folder)
        let id = try XCTUnwrap(lib.photos.first).id
        lib.selection = id
        lib.open(folder.appendingPathComponent("missing", isDirectory: true))
        XCTAssertEqual(lib.folder, folder, "the open folder stays")
        XCTAssertEqual(lib.selection, id, "and so does the selection")
        XCTAssertNotNil(lib.openError)
        lib.open(folder)
        XCTAssertNil(lib.openError, "a successful open clears the message")
    }
}
