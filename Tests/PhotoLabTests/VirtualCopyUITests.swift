import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Virtual copies, the UI: Photo › Create Virtual Copy (⌘') and Remove
/// Virtual Copy… (a copy only, after a confirm, no undo step), the caption
/// and Info row that name a copy, and the `-copy<n>` export name that keeps
/// a master's and its copy's outputs apart.
@MainActor
final class VirtualCopyUITests: XCTestCase {
    private var base: URL!
    private var folder: URL!
    private var outDir: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-vcopy-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // The scan lists resolved paths (/private/var, not /var).
        let real = realpath(base.path, nil)!
        defer { free(real) }
        base = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        folder = base.appendingPathComponent("photos", isDirectory: true)
        outDir = base.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makePhoto(_ name: String) throws {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func openTwo() throws -> (Library, Photo.ID, Photo.ID) {
        try makePhoto("a.png")
        try makePhoto("b.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        XCTAssertEqual(lib.photos.count, 2)
        return (lib, lib.photos[0].id, lib.photos[1].id)
    }

    // MARK: Commands

    func testCreateAndRemoveAreTableCommandsWithTheirKeysAndEnablement() throws {
        let create = AppCommand.command(.createVirtualCopy)
        XCTAssertEqual(create.title, "Create Virtual Copy")
        XCTAssertEqual(create.key, "'")
        XCTAssertEqual(create.modifiers, .command)
        XCTAssertEqual(create.placement, .photo)
        let remove = AppCommand.command(.removeVirtualCopy)
        XCTAssertEqual(remove.title, "Remove Virtual Copy…")
        XCTAssertNil(remove.key)
        XCTAssertEqual(remove.placement, .photo)

        let (lib, a, _) = try openTwo()
        let ctx = CommandContext(library: lib)
        XCTAssertFalse(create.isEnabled(ctx), "no anchor, nothing to copy")
        lib.selection = a
        XCTAssertTrue(create.isEnabled(ctx))
        XCTAssertFalse(remove.isEnabled(ctx), "a master has nothing to remove")

        var r = Recipe.neutral
        r.set(.exposure, to: 0.5)
        lib.setRecipe(r, for: a)
        lib.loupe = true
        create.perform(ctx)
        let copy = try XCTUnwrap(lib.selection)
        XCTAssertEqual(copy, .copy(of: a, number: 2), "the loupe moves to the new copy")
        XCTAssertTrue(lib.loupe)
        XCTAssertEqual(lib.recipe(for: copy), r)
        XCTAssertTrue(create.isEnabled(ctx), "a copy of a copy is the master's next")
        XCTAssertTrue(remove.isEnabled(ctx))

        // Remove asks first: nothing is removed until the confirm's button.
        remove.perform(ctx)
        let request = try XCTUnwrap(lib.removeCopyRequest)
        XCTAssertEqual(request.id, copy)
        XCTAssertEqual(request.title, "Remove a.png Copy 2?")
        XCTAssertTrue(lib.photos.contains { $0.id == copy })
        XCTAssertTrue(lib.removeVirtualCopy(request.id))
        XCTAssertFalse(lib.photos.contains { $0.id == copy })
        XCTAssertEqual(lib.selection, a, "back to the master")
        // ⌘Z takes back the master's own last edit, never the removal.
        lib.undo()
        XCTAssertEqual(lib.recipe(for: a), .neutral, "the undo step is the master's exposure")
        XCTAssertFalse(lib.photos.contains { $0.id == copy }, "a removal is not an undo step")
        XCTAssertFalse(lib.canUndo)
    }

    func testTheCellMenuActsOnTheRightClickedPhoto() throws {
        let (lib, a, b) = try openTwo()
        lib.selection = b
        let onA = CommandContext(library: lib, targetIDs: lib.contextTargets(for: a), subjectID: a)
        AppCommand.command(.createVirtualCopy).perform(onA)
        let copy = PhotoID.copy(of: a, number: 2)
        XCTAssertEqual(lib.photos.map(\.id), [a, copy, b], "the copy is listed after its master")
        let onCopy = CommandContext(library: lib, targetIDs: lib.contextTargets(for: copy), subjectID: copy)
        let onB = CommandContext(library: lib, targetIDs: lib.contextTargets(for: b), subjectID: b)
        XCTAssertTrue(AppCommand.command(.removeVirtualCopy).isEnabled(onCopy))
        XCTAssertFalse(AppCommand.command(.removeVirtualCopy).isEnabled(onB))
        AppCommand.command(.removeVirtualCopy).perform(onCopy)
        XCTAssertEqual(lib.removeCopyRequest?.id, copy)
    }

    // MARK: Names

    func testTheCaptionAndTheInfoRowNameTheCopy() throws {
        let (lib, a, _) = try openTwo()
        let copyID = try XCTUnwrap(lib.createVirtualCopy(of: a))
        let master = try XCTUnwrap(lib.photos.first { $0.id == a })
        let copy = try XCTUnwrap(lib.photos.first { $0.id == copyID })
        XCTAssertEqual(master.caption, "a.png")
        XCTAssertNil(master.copyLabel)
        XCTAssertEqual(copy.caption, "a.png Copy 2")
        XCTAssertEqual(copy.copyLabel, "Copy 2")
        XCTAssertEqual(InfoSection.virtualCopy(copy), "Virtual copy 2 of a.png")
        XCTAssertNil(InfoSection.virtualCopy(master))
        let rows = PhotoInfoStore.listing(copy).rows(edited: false, virtualCopy: InfoSection.virtualCopy(copy))
        XCTAssertEqual(rows.first, PhotoInfo.Row(label: "Virtual Copy", value: "Virtual copy 2 of a.png"))
        XCTAssertEqual(rows.first { $0.label == "File" }?.value, "a.png", "one file: the master's")
        // An unnamed Photos copy never shows the asset identifier.
        let unnamed = Photo(id: .asset("X/L0/001"), name: nil).virtualCopy(number: 3)
        XCTAssertEqual(unnamed.caption, "Copy 3")
        XCTAssertEqual(InfoSection.virtualCopy(unnamed), "Virtual copy 3")
    }

    // MARK: Export

    func testACopysFileNameCarriesItsNumberBeforeTheExtension() {
        var o = ExportOptions()
        let src = URL(fileURLWithPath: "/p/DSC06727.ARW")
        XCTAssertEqual(o.fileName(for: src, copy: 2), "DSC06727-copy2.jpg")
        o.suffix = "-edit"
        XCTAssertEqual(o.fileName(for: src), "DSC06727-edit.jpg")
        XCTAssertEqual(o.fileName(for: src, copy: 2), "DSC06727-edit-copy2.jpg")
        XCTAssertEqual(o.fileName(for: src, copy: 2, number: 2), "DSC06727-edit-copy2 2.jpg",
                       "the numbering still applies past the copy's name")
        XCTAssertEqual(o.fileName(for: src, name: "IMG_1.HEIC", copy: 3), "IMG_1-edit-copy3.jpg")
        XCTAssertEqual(o.fileName(stem: "001", copy: 2), "001-copy2.jpg", "a templated stem too")
    }

    /// The collision case: a master and its copy exported together under
    /// Overwrite. Without the copy's suffix both would write `a.jpg`, the
    /// copy replacing the master's output.
    func testAMasterAndItsCopyExportedTogetherNeverCollide() async throws {
        let (lib, a, _) = try openTwo()
        let copy = try XCTUnwrap(lib.createVirtualCopy(of: a))
        var bright = Recipe.neutral
        bright.set(.exposure, to: 1.5)
        lib.setRecipe(bright, for: copy)
        let items = try await lib.exportItems(for: [a, copy])
        XCTAssertEqual(items.map(\.copyNumber), [nil, 2])
        XCTAssertEqual(ExportForm(options: .default).previewNames(for: items), ["a.jpg", "a-copy2.jpg"])

        for collision in [ExportOptions.Collision.overwrite, .number] {
            let out = outDir.appendingPathComponent(collision.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var options = ExportOptions()
            options.collision = collision
            let queue = ExportQueue()
            queue.start(items, into: out, options: options)
            await queue.wait()
            XCTAssertEqual(queue.failures.map(\.message), [], "\(collision)")
            XCTAssertEqual(queue.done, 2, "\(collision)")
            XCTAssertEqual(queue.exported.map(\.lastPathComponent), ["a.jpg", "a-copy2.jpg"], "\(collision)")
            let files = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { !$0.hasPrefix(".") }
            XCTAssertEqual(files.sorted(), ["a-copy2.jpg", "a.jpg"], "\(collision): two outputs, neither replaced")
            let m = try Data(contentsOf: out.appendingPathComponent("a.jpg"))
            let c = try Data(contentsOf: out.appendingPathComponent("a-copy2.jpg"))
            XCTAssertNotEqual(m, c, "\(collision): each carries its own edit")
        }
    }
}
