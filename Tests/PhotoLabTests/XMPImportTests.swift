import XCTest
@testable import PhotoLab

/// The Import Lightroom Preset sheet's model and `RecipeDiff`, over a
/// `PresetStore` in a temp folder (never ~/Library) and hand-written XMP.
@MainActor
final class XMPImportTests: XCTestCase {
    private var dir: URL!
    private var library: PresetLibrary!

    private static let packet = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:PresetName="Warm Fade" crs:Exposure2012="+0.50" crs:Contrast2012="-20" crs:Vibrance="+10" crs:Dehaze="+20"/>
        </rdf:RDF></x:xmpmeta>
        """

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-xmpimport-\(UUID().uuidString)", isDirectory: true)
        library = PresetLibrary(store: PresetStore(directory: dir.appendingPathComponent("presets")))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func model(_ text: String = packet, file: String = "Warm Fade.xmp") -> XMPImportModel {
        XMPImportModel(fileName: file, library: library) { Data(text.utf8) }
    }

    private func presetFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: library.store.directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
    }

    func testSaveWritesExactlyOnePresetWhoseRecipeEqualsTheParse() throws {
        let before = presetFiles()
        let m = model()
        let parsed = try XMPPreset.parse(Data(Self.packet.utf8), fileName: "Warm Fade.xmp")
        m.save()
        XCTAssertTrue(m.finished)
        let after = presetFiles()
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(Set(after).subtracting(before), ["Warm Fade.json"])
        let saved = try XCTUnwrap(library.preset(named: "Warm Fade"))
        XCTAssertEqual(saved.apply(to: .neutral), parsed.recipe.normalized)
        XCTAssertEqual(library.presets.map(\.name).contains("Warm Fade"), true, "the strip shows it")
    }

    func testMovedListMatchesRecipeDiffAndTheCountTitle() throws {
        let m = model()
        let parsed = try XMPPreset.parse(Data(Self.packet.utf8), fileName: "x.xmp")
        let diff = RecipeDiff.moved(from: .neutral, to: parsed.recipe)
        XCTAssertEqual(m.moved.map(\.0), diff.map(\.0))
        XCTAssertEqual(m.moved.map(\.1), diff.map(\.1))
        XCTAssertEqual(m.moved.map(\.0), [.exposure, .contrast, .vibrance])
        XCTAssertEqual(m.moved.map(\.1), [0.5, -20, 10])
        XCTAssertEqual(m.movesTitle, "Moves 3 sliders")
    }

    func testRecipeDiffIsAgainstTheGivenRecipeAndTreatsDisabledAsNeutral() {
        var a = Recipe.neutral; a.set(.exposure, to: 1)
        var b = a; b.set(.contrast, to: 5)
        XCTAssertEqual(RecipeDiff.moved(from: a, to: b).map(\.0), [.contrast])
        XCTAssertTrue(RecipeDiff.moved(from: .neutral, to: .neutral).isEmpty)
        var off = a; off[.exposure].enabled = false
        XCTAssertTrue(RecipeDiff.moved(from: .neutral, to: off).isEmpty)
    }

    func testTheUnsupportedSettingsAreListedByLabel() {
        XCTAssertEqual(model().unsupportedLabels, ["Dehaze"])
    }

    func testATakenNameAsksAndWritesNothingUntilAnswered() throws {
        library.save(.neutral, as: "Warm Fade")
        let before = presetFiles()
        let m = model()
        m.save()
        XCTAssertTrue(m.askingReplace)
        XCTAssertFalse(m.finished)
        XCTAssertEqual(presetFiles(), before)
        XCTAssertEqual(library.preset(named: "Warm Fade")?.apply(to: .neutral), Recipe.neutral.normalized)
        m.replace()
        XCTAssertTrue(m.finished)
        XCTAssertEqual(presetFiles(), before)
        XCTAssertNotEqual(library.preset(named: "Warm Fade")?.apply(to: .neutral), Recipe.neutral.normalized)
    }

    func testKeepBothPicksNameTwoThenThree() {
        library.save(.neutral, as: "Warm Fade")
        let m = model()
        m.save()
        m.keepBoth()
        XCTAssertNotNil(library.preset(named: "Warm Fade 2"))
        XCTAssertEqual(library.preset(named: "Warm Fade")?.apply(to: .neutral), Recipe.neutral.normalized)
        let again = model()
        again.save()
        again.keepBoth()
        XCTAssertNotNil(library.preset(named: "Warm Fade 3"))
    }

    func testCancelWritesNothing() {
        let before = presetFiles()
        var done = 0
        let m = model()
        m.onFinish = { done += 1 }
        m.cancel()
        m.cancel()
        XCTAssertEqual(presetFiles(), before)
        XCTAssertEqual(done, 1)
        XCTAssertNil(library.preset(named: "Warm Fade"))
    }

    func testAParseErrorIsShownNotThrown() {
        let m = model("this is not xml <", file: "bad.xmp")
        XCTAssertNil(m.parsed)
        XCTAssertEqual(m.error, XMPImportError.notXML.errorDescription)
        XCTAssertFalse(m.canSave)
        let before = presetFiles()
        m.save()
        XCTAssertEqual(presetFiles(), before)
        let unreadable = XMPImportModel(fileName: "gone.xmp", library: library) { throw CocoaError(.fileReadNoSuchFile) }
        XCTAssertNotNil(unreadable.error)
    }

    func testAnInvalidNameCannotBeSaved() {
        let m = model()
        m.name = "  "
        XCTAssertFalse(m.canSave)
        m.save()
        XCTAssertFalse(m.finished)
        XCTAssertNotNil(m.nameProblem)
    }

    func testQueuedFilesShowOneSheetAtATime() throws {
        let a = dir.appendingPathComponent("a.xmp"), b = dir.appendingPathComponent("b.xmp")
        try Data(Self.packet.utf8).write(to: a)
        try Data(Self.packet.replacingOccurrences(of: "Warm Fade", with: "Cool").utf8).write(to: b)
        library.queueXMPImports([a, b])
        XCTAssertEqual(library.xmpImports.count, 2)
        library.xmpImports[0].cancel()
        XCTAssertEqual(library.xmpImports.count, 1)
        XCTAssertEqual(library.xmpImports.first?.name, "Cool")
        library.xmpImports[0].save()
        XCTAssertTrue(library.xmpImports.isEmpty)
        XCTAssertNotNil(library.preset(named: "Cool"))
    }
}
