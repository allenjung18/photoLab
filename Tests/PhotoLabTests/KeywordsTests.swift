import XCTest
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
@testable import PhotoLab

/// Keywords: metadata beside the marks in the sidecar (an optional key,
/// absent when empty, so an older file decodes unchanged and the version is
/// not raised), never an undo step or part of a recipe, kept by a reset,
/// edited over the batch targets, and written as IPTC Keywords on export.
/// Every file lives under a temporary directory.
@MainActor
final class KeywordsTests: XCTestCase {
    private var folder: URL!
    private var outDir: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-keywords-\(UUID().uuidString)", isDirectory: true)
        folder = base.appendingPathComponent("photos", isDirectory: true)
        outDir = base.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    @discardableResult
    private func makePhoto(_ name: String, type: UTType = .png, properties: [CFString: Any]? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, properties as CFDictionary?)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func openLibrary(_ names: [String]) throws -> (Library, [Photo.ID]) {
        for n in names { try makePhoto(n) }
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        XCTAssertEqual(lib.photos.count, names.count)
        return (lib, lib.photos.map(\.id))
    }

    private func sidecarJSON(_ store: SidecarStore, _ id: Photo.ID) throws -> [String: Any] {
        let data = try Data(contentsOf: store.url(for: id))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func iptcKeywords(_ url: URL) throws -> [String]? {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let p = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        return iptc?[kCGImagePropertyIPTCKeywords] as? [String]
    }

    // MARK: The normal form

    func testKeywordsAreTrimmedDedupedCaseInsensitivelyAndSorted() {
        XCTAssertEqual(Keywords.normalized([" sunset ", "Beach", "beach", "", "  ", "alps\n", "SUNSET"]),
                       ["alps", "Beach", "sunset"], "first spelling kept, sorted ignoring case")
        XCTAssertEqual(Keywords.parse("dog, Cat ,, dog,bird"), ["bird", "Cat", "dog"])
        XCTAssertEqual(Keywords.parse(" , "), [])
        let tally = Keywords.tally([["beach", "dog"], ["Beach"], []])
        XCTAssertEqual(tally, [Keywords.Tally(keyword: "beach", count: 2), Keywords.Tally(keyword: "dog", count: 1)])
        XCTAssertEqual(KeywordsSheet.share(tally[0], of: 2), "all")
        XCTAssertEqual(KeywordsSheet.share(tally[1], of: 3), "1 of 3")
    }

    // MARK: The sidecar

    func testKeywordsRoundTripThroughTheSidecarAndAFreshLibrary() throws {
        let (lib, ids) = try openLibrary(["a.png"])
        let a = ids[0]
        lib.addKeywords([" Sunset", "beach", "BEACH", ""], to: [a])
        XCTAssertEqual(lib.keywords(for: a), ["beach", "Sunset"])
        XCTAssertFalse(lib.isEdited(a), "keywords are not an edit")
        XCTAssertFalse(lib.canUndo, "nor an undo step")

        let store = SidecarStore(folder: folder)
        let json = try sidecarJSON(store, a)
        XCTAssertEqual(json["keywords"] as? [String], ["beach", "Sunset"])
        XCTAssertEqual(json["version"] as? Int, 1, "keywords do not raise the format version")
        XCTAssertNil(json["flag"])
        XCTAssertEqual(try store.read(for: a)?.keywords, ["beach", "Sunset"])
        XCTAssertEqual(store.loadAll(for: [a]).keywords[a], ["beach", "Sunset"])

        let fresh = Library(rememberFolder: false)
        fresh.open(folder)
        XCTAssertEqual(fresh.keywords(for: a), ["beach", "Sunset"])
        XCTAssertNil(fresh.sidecarError)

        // Adding one it already has in another case changes nothing.
        let before = try Data(contentsOf: store.url(for: a))
        fresh.addKeywords(["SUNSET"], to: [a])
        XCTAssertEqual(fresh.keywords(for: a), ["beach", "Sunset"])
        XCTAssertEqual(try Data(contentsOf: store.url(for: a)), before, "no write")
    }

    func testAPreKeywordsSidecarDecodesUnchangedAndAPhotoWithoutKeywordsWritesNoKey() throws {
        let photo = try makePhoto("IMG_0001.JPG", type: .jpeg)
        let store = SidecarStore(folder: folder)
        let verbatim = """
        {
          "flag" : "pick",
          "original" : "IMG_0001.JPG",
          "recipe" : {
            "adjustments" : [
              { "enabled" : true, "kind" : "exposure", "value" : 0.3 }
            ]
          },
          "updated" : "2026-10-01T10:00:00Z",
          "version" : 1
        }
        """
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(verbatim.utf8).write(to: store.url(for: photo))

        let doc = try XCTUnwrap(try store.read(for: photo))
        XCTAssertNil(doc.keywords)
        XCTAssertEqual(doc.marks.flag, .pick)
        XCTAssertEqual(doc.recipe.value(of: .exposure), 0.3)
        let all = store.loadAll(for: [photo])
        XCTAssertTrue(all.keywords.isEmpty)
        XCTAssertTrue(all.unreadable.isEmpty)

        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let id = try XCTUnwrap(lib.photos.first).id
        XCTAssertEqual(lib.keywords(for: id), [])
        XCTAssertEqual(lib.flag(for: id), .pick)

        // A write of a photo without keywords has no keywords key at all.
        lib.setRating(3, for: [id])
        let json = try sidecarJSON(store, id)
        XCTAssertNil(json["keywords"], "absent, not null or []")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertFalse(try String(contentsOf: store.url(for: id), encoding: .utf8).contains("keywords"))
    }

    /// The nothing-to-keep rule counts keywords: a keyword on a default
    /// recipe keeps its file, a reset keeps the keywords, and a recipe-only
    /// save keeps them too. Removing the last keyword of an unmarked,
    /// unedited photo removes the file.
    func testAKeywordOnlySidecarSurvivesAReset() throws {
        let (lib, ids) = try openLibrary(["a.png"])
        let a = ids[0]
        let store = SidecarStore(folder: folder)
        var r = Recipe.neutral
        r.set(.exposure, to: 0.5)
        lib.setRecipe(r, for: a)
        lib.addKeywords(["harbour"], to: [a])
        lib.resetRecipe(for: a)
        XCTAssertFalse(lib.isEdited(a))
        XCTAssertTrue(store.exists(for: a), "a keyword keeps a default recipe's file")
        XCTAssertEqual(lib.keywords(for: a), ["harbour"], "Reset leaves keywords")
        XCTAssertEqual(try store.read(for: a)?.keywords, ["harbour"])

        lib.selection = a
        lib.undo()
        XCTAssertEqual(lib.recipe(for: a), r, "undo brings the recipe back")
        XCTAssertEqual(lib.keywords(for: a), ["harbour"], "and does not touch keywords")

        // The recipe-only save keeps them.
        try store.save(.neutral, for: a)
        XCTAssertEqual(try store.read(for: a)?.keywords, ["harbour"])

        lib.resetRecipe(for: a)
        lib.removeKeyword("HARBOUR", from: [a])
        XCTAssertEqual(lib.keywords(for: a), [])
        XCTAssertFalse(store.exists(for: a), "nothing left to keep")
    }

    // MARK: Editing over the targets

    func testThreeTargetsWriteThreeSidecarsAndTheSheetCountsThem() throws {
        let (lib, ids) = try openLibrary(["a.png", "b.png", "c.png"])
        let store = SidecarStore(folder: folder)
        lib.selectAll()
        XCTAssertEqual(Set(lib.batchTargets), Set(ids))

        let command = AppCommand.command(.keywords)
        XCTAssertEqual(command.key, "k")
        XCTAssertEqual(command.modifiers, .command)
        XCTAssertFalse(command.isBareKey, "a menu key: ⌘K")
        let ctx = CommandContext(library: lib)
        XCTAssertTrue(command.isEnabled(ctx))
        XCTAssertEqual(command.menuTitle(ctx), "Keywords for 3 Photos…")
        command.perform(ctx)
        let request = try XCTUnwrap(lib.keywordsRequest)
        XCTAssertEqual(Set(request.targets), Set(ids))

        lib.addKeywords(Keywords.parse("travel, Night"), to: request.targets)
        for id in ids {
            XCTAssertTrue(store.exists(for: id))
            XCTAssertEqual(try store.read(for: id)?.keywords, ["Night", "travel"])
        }
        lib.removeKeyword("night", from: [ids[1]])
        let tally = Keywords.tally(request.targets.map { lib.keywords(for: $0) })
        XCTAssertEqual(tally.map(\.keyword), ["Night", "travel"])
        XCTAssertEqual(tally.map { KeywordsSheet.share($0, of: request.targets.count) }, ["2 of 3", "all"])
        XCTAssertEqual(try store.read(for: ids[1])?.keywords, ["travel"])

        // A context menu pins its own targets.
        lib.keywordsRequest = nil
        command.perform(CommandContext(library: lib, targetIDs: [ids[2]], subjectID: ids[2]))
        XCTAssertEqual(lib.keywordsRequest?.targets, [ids[2]])

        // Nothing to act on: disabled, and no sheet.
        let empty = CommandContext(library: Library(rememberFolder: false))
        XCTAssertFalse(command.isEnabled(empty))
        lib.open(folder)
        XCTAssertNil(lib.keywordsRequest, "a pending sheet is dropped on open")
    }

    // MARK: Export

    func testAnExportCarriesThePhotosKeywordsAsIPTC() async throws {
        try makePhoto("a.jpg", type: .jpeg, properties: [
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["from-camera"],
                                             kCGImagePropertyIPTCCity: "Seattle"],
        ])
        try makePhoto("b.jpg", type: .jpeg, properties: [
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["from-camera"]],
        ])
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let ids = lib.photos.map(\.id)
        XCTAssertEqual(ids.count, 2)
        lib.addKeywords(["Sunset", "beach"], to: [ids[0]])

        let items = try await lib.exportItems(for: ids)
        XCTAssertEqual(items.map(\.keywords), [["beach", "Sunset"], []])

        var o = ExportOptions()
        o.format = .jpeg
        let queue = ExportQueue()
        queue.start(items, into: outDir, options: o)
        await queue.wait()
        XCTAssertEqual(queue.state, .finished)
        XCTAssertEqual(queue.done, 2)
        let a = outDir.appendingPathComponent("a.jpg"), b = outDir.appendingPathComponent("b.jpg")
        XCTAssertEqual(try iptcKeywords(a), ["beach", "Sunset"], "the photo's keywords replace the source's")
        let iptc = try XCTUnwrap(try CGImageSourceCopyPropertiesAtIndex(
            XCTUnwrap(CGImageSourceCreateWithURL(a as CFURL, nil)), 0, nil) as? [CFString: Any])[kCGImagePropertyIPTCDictionary]
            as? [CFString: Any]
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCCity] as? String, "Seattle", "the rest of the IPTC block travels")
        XCTAssertEqual(try iptcKeywords(b), ["from-camera"], "no keywords: the source's own travel")

        // Keep camera info off: no metadata, keywords included.
        queue.dismiss()
        o.keepMetadata = false
        o.suffix = "-plain"
        queue.start(items, into: outDir, options: o)
        await queue.wait()
        XCTAssertNil(try iptcKeywords(outDir.appendingPathComponent("a-plain.jpg")))
    }
}
