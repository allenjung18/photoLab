import XCTest
@testable import PhotoLab

/// Export presets: a named `ExportOptions` (the watermark included, the
/// destination never) saved to its own user-level folder comes back in a
/// fresh store; names are cleaned on `PresetStore`'s rules; an unreadable
/// file is backed up, never overwritten, and listed; a pick fills every
/// field of the sheet's `ExportForm` and the label says "(edited)" once one
/// changes; delete removes only that file; the last pick is remembered in
/// `AppSettings`; and the store never touches the develop presets' folder.
/// Every store points at a temp directory, never Application Support.
@MainActor
final class ExportPresetTests: XCTestCase {
    private var base: URL!
    private var dir: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-export-presets-\(UUID().uuidString)", isDirectory: true)
        dir = base.appendingPathComponent("export-presets", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private var web: ExportOptions {
        var o = ExportOptions.default
        o.format = .heic
        o.quality = 0.7
        o.resize = .longSide(1600)
        o.keepMetadata = false
        o.suffix = "-web"
        o.collision = .skip
        o.watermark = Watermark(text: "© Test", position: .topLeft, size: 0.05, opacity: 0.8)
        return o
    }

    private var archive: ExportOptions {
        var o = ExportOptions.default
        o.format = .tiff
        o.resize = .percent(50)
        o.suffix = "-archive"
        o.collision = .overwrite
        o.watermark = nil
        return o
    }

    private func files(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    // MARK: Built-in

    func testTheWebPresetIsAJPEGAt2048WithDatesButNoLocation() {
        let o = ExportPreset.web.options
        XCTAssertEqual(ExportPreset.web.name, "For Google Photos / web")
        XCTAssertEqual(o.format, .jpeg)
        XCTAssertEqual(o.quality, 0.85)
        XCTAssertEqual(o.resize, .longSide(2048))
        XCTAssertTrue(o.keepMetadata, "dates travel: Google Photos files by capture date")
        XCTAssertTrue(o.removesLocation)
        XCTAssertEqual(o.colorSpace, .sRGB, "D-475 (a)")
        XCTAssertEqual(o.sharpening, .standard, "D-475 (a)")
        XCTAssertEqual(o.suffix, "-web")
        XCTAssertNil(o.watermark)
    }

    func testABuiltInIsListedWithNoFileAndCannotBeDeleted() throws {
        let lib = ExportPresetLibrary(store: ExportPresetStore(directory: dir))
        XCTAssertEqual(lib.presets, [], "no saved presets")
        XCTAssertEqual(lib.builtIns, [ExportPreset.web], "the built-in is listed anyway")
        XCTAssertEqual(lib.preset(named: ExportPreset.web.name), ExportPreset.web, "a remembered pick finds it")
        XCTAssertFalse(lib.isSaved(ExportPreset.web.name), "Delete Preset is off for it")
        XCTAssertFalse(lib.delete(ExportPreset.web.name), "and a delete finds no file")
        XCTAssertEqual(files(dir), [], "nothing was written for it")

        var form = ExportForm(options: .default)
        form.pick(ExportPreset.web)
        XCTAssertEqual(form.resolved, ExportPreset.web.options, "a pick fills the sheet with its options")
        XCTAssertEqual(form.presetLabel, ExportPreset.web.name)
    }

    func testASavedPresetOfTheSameNameReplacesTheBuiltInInTheMenu() throws {
        let lib = ExportPresetLibrary(store: ExportPresetStore(directory: dir))
        let mine = try XCTUnwrap(lib.save(archive, as: ExportPreset.web.name))
        XCTAssertEqual(lib.builtIns, [], "the built-in steps aside")
        XCTAssertEqual(lib.preset(named: ExportPreset.web.name), mine, "the saved one wins")
        XCTAssertTrue(lib.delete(ExportPreset.web.name))
        XCTAssertEqual(lib.builtIns, [ExportPreset.web], "and comes back once it is deleted")
    }

    // MARK: Store

    func testRoundTripIncludingAWatermark() throws {
        let store = ExportPresetStore(directory: dir)
        try store.save(ExportPreset(name: "Web", options: web))
        try store.save(ExportPreset(name: "Archive", options: archive))

        let fresh = ExportPresetStore(directory: dir)
        let loaded = fresh.loadAll()
        XCTAssertEqual(loaded.unreadable, [])
        XCTAssertEqual(loaded.presets.map(\.name), ["Archive", "Web"], "sorted by name")
        XCTAssertEqual(try fresh.load("Web")?.options, web, "every field, the watermark included")
        XCTAssertEqual(try fresh.load("Web")?.options.watermark,
                       Watermark(text: "© Test", position: .topLeft, size: 0.05, opacity: 0.8))
        XCTAssertNil(try fresh.load("Archive")?.options.watermark)
        XCTAssertEqual(try fresh.load("Archive")?.options, archive)
        XCTAssertEqual(files(dir), ["Archive.json", "Web.json"])

        // The file carries the options and no destination.
        let json = try String(contentsOf: store.url(for: "Web"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"options\""))
        XCTAssertTrue(json.contains("\"version\" : 1"))
        XCTAssertFalse(json.contains("folder"), "the destination is never part of a preset")
        XCTAssertFalse(json.contains("album"))
    }

    func testNamesAreCleanedOnThePresetStoreRules() throws {
        let store = ExportPresetStore(directory: dir)
        let saved = try store.save(ExportPreset(name: "  Web / Insta: 2  ", options: web))
        XCTAssertEqual(saved.name, "Web / Insta: 2", "trimmed, otherwise kept as typed")
        XCTAssertEqual(files(dir), ["Web - Insta- 2.json"], "/ and : replaced in the file name only")
        XCTAssertEqual(try store.load("Web / Insta: 2")?.name, "Web / Insta: 2")
        XCTAssertTrue(store.exists("Web / Insta: 2"))
        XCTAssertTrue(store.exists("  Web / Insta: 2 "), "exists() validates like save()")

        XCTAssertThrowsError(try store.save(ExportPreset(name: "   ", options: web))) {
            XCTAssertEqual($0 as? PresetError, .emptyName)
        }
        XCTAssertThrowsError(try store.save(ExportPreset(name: ".hidden", options: web))) {
            XCTAssertEqual($0 as? PresetError, .invalidName(".hidden"))
        }
        XCTAssertThrowsError(try store.save(ExportPreset(name: "Web - Insta- 2", options: archive))) {
            XCTAssertEqual($0 as? ExportPresetError, .fileNameCollision("Web - Insta- 2", "Web / Insta: 2"),
                           "a different name on the same file is refused, never replaced")
        }
        XCTAssertEqual(try store.load("Web / Insta: 2")?.options, web, "the first preset is intact")
    }

    func testAnUnreadableFileIsBackedUpNeverOverwrittenAndListed() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let broken = Data("{ not json".utf8)
        try broken.write(to: dir.appendingPathComponent("Broken.json"))
        var newer = ExportPreset(name: "Future", options: web)
        newer.version = ExportPreset.currentVersion + 98
        let future = try JSONEncoder().encode(newer)
        try future.write(to: dir.appendingPathComponent("Future.json"))
        let store = ExportPresetStore(directory: dir)
        try store.save(ExportPreset(name: "Good", options: web))

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.presets.map(\.name), ["Good"])
        XCTAssertEqual(loaded.unreadable.map(\.lastPathComponent), ["Broken.json", "Future.json"])
        XCTAssertThrowsError(try store.load("Future")) {
            XCTAssertEqual($0 as? ExportPresetError, .unsupportedVersion("Future", 99))
        }
        let library = ExportPresetLibrary(store: store)
        XCTAssertEqual(library.unreadable.count, 2)
        XCTAssertEqual(library.error, "Could not read the export preset file Broken.json")

        // Saving over the broken name moves the file aside first.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(ExportPreset(name: "Broken", options: archive), now: now)
        let backup = dir.appendingPathComponent("Broken.json.\(UnreadableBackup.marker)-\(UnreadableBackup.stamp(now))")
        XCTAssertEqual(try Data(contentsOf: backup), broken, "the original bytes, kept")
        XCTAssertEqual(try store.load("Broken")?.options, archive)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Future.json")), future, "untouched")
        XCTAssertEqual(store.loadAll().unreadable.map(\.lastPathComponent), ["Future.json"],
                       "a backup is not listed (not .json)")
    }

    func testDeleteRemovesOnlyThatFile() throws {
        let store = ExportPresetStore(directory: dir)
        try store.save(ExportPreset(name: "Web", options: web))
        try store.save(ExportPreset(name: "Archive", options: archive))
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("{".utf8).write(to: dir.appendingPathComponent("Broken.json"))

        let library = ExportPresetLibrary(store: store)
        XCTAssertTrue(library.delete("Web"))
        XCTAssertEqual(files(dir), ["Archive.json", "Broken.json", "notes.txt"])
        XCTAssertEqual(library.presets.map(\.name), ["Archive"])
        XCTAssertFalse(library.delete("Web"), "already gone")
        XCTAssertEqual(library.error, ExportPresetError.notFound("Web").localizedDescription)
        XCTAssertEqual(files(dir), ["Archive.json", "Broken.json", "notes.txt"])
    }

    func testTheStoreNeverTouchesTheDevelopPresetDirectory() throws {
        XCTAssertNotEqual(ExportPresetStore.defaultDirectory.standardizedFileURL,
                          PresetStore.defaultDirectory.standardizedFileURL)
        XCTAssertEqual(ExportPresetStore.defaultDirectory.lastPathComponent, "export-presets")
        XCTAssertEqual(ExportPresetStore.defaultDirectory.deletingLastPathComponent().standardizedFileURL,
                       PresetStore.defaultDirectory.deletingLastPathComponent().standardizedFileURL,
                       "beside the develop presets, not inside them")

        // Side by side in one temp base: the develop store seeded, then every
        // export-preset operation; the develop folder is byte-for-byte as it was.
        let developDir = base.appendingPathComponent("presets", isDirectory: true)
        try PresetStore(directory: developDir).seedStartersIfMissing()
        let before = files(developDir)
        let snapshot = try before.map { try Data(contentsOf: developDir.appendingPathComponent($0)) }

        let library = ExportPresetLibrary(store: ExportPresetStore(directory: dir))
        XCTAssertEqual(library.presets, [], "no built-in export presets")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "nothing is seeded")
        XCTAssertNotNil(library.save(web, as: "Neutral"), "a develop preset's name is no conflict")
        XCTAssertNotNil(library.save(archive, as: "Neutral"))
        XCTAssertTrue(library.delete("Neutral"))

        XCTAssertEqual(files(developDir), before)
        XCTAssertEqual(try before.map { try Data(contentsOf: developDir.appendingPathComponent($0)) }, snapshot)
        XCTAssertEqual(PresetStore(directory: developDir).loadAll().unreadable, [])
    }

    // MARK: The sheet's form

    func testAPickSetsTheSheetsOptionsEqualToThePresets() {
        let webPreset = ExportPreset(name: "Web", options: web)
        let archivePreset = ExportPreset(name: "Archive", options: archive)

        var form = ExportForm(options: .default)
        XCTAssertEqual(form.presetLabel, "None")
        form.pick(webPreset)
        XCTAssertEqual(form.resolved, web, "every field, the watermark included")
        XCTAssertTrue(form.watermarkOn)
        XCTAssertEqual(form.presetLabel, "Web")

        // From a form with a watermark on, a preset without one switches it off.
        form.pick(archivePreset)
        XCTAssertEqual(form.resolved, archive)
        XCTAssertNil(form.resolved.watermark)
        XCTAssertFalse(form.watermarkOn)
        XCTAssertEqual(form.sizeMode, .percent)
        XCTAssertEqual(form.presetLabel, "Archive")

        // And back: the preset's mark, not the one the form had.
        var marked = ExportForm(options: .default)
        marked.watermarkOn = true
        marked.watermark = Watermark(text: "Other", position: .center, size: 0.1, opacity: 0.3)
        marked.pick(webPreset)
        XCTAssertEqual(marked.resolved, web)
        XCTAssertEqual(marked.watermark, web.watermark)
    }

    func testAChangedFieldShowsTheNameAsEdited() {
        var form = ExportForm(options: .default)
        form.pick(ExportPreset(name: "Web", options: web))
        form.options.suffix = "-other"
        XCTAssertTrue(form.isEdited)
        XCTAssertEqual(form.presetLabel, "Web (edited)")
        form.options.suffix = "-web"
        XCTAssertEqual(form.presetLabel, "Web", "changed back = the preset again")

        form.watermark.opacity = 0.4
        XCTAssertEqual(form.presetLabel, "Web (edited)", "a watermark field counts")
        form.watermark.opacity = 0.8
        form.sizeMode = .original
        XCTAssertEqual(form.presetLabel, "Web (edited)", "a size control counts")
        form.sizeMode = .longSide
        XCTAssertEqual(form.presetLabel, "Web")

        // The last run's options under a remembered pick: edited when they differ.
        var reopened = ExportForm(options: archive)
        reopened.picked = ExportPreset(name: "Web", options: web)
        XCTAssertEqual(reopened.presetLabel, "Web (edited)")
        XCTAssertEqual(reopened.resolved, archive, "a remembered pick does not change the fields")
    }

    func testSavingTheCurrentFieldsRoundTripsThroughThePick() throws {
        var form = ExportForm(options: .default)
        form.options.format = .jpeg
        form.sizeMode = .longSide
        form.longSide = 2400
        form.watermarkOn = true
        form.watermark = Watermark(text: "Saved", position: .bottomLeft)
        let library = ExportPresetLibrary(store: ExportPresetStore(directory: dir))
        let saved = try XCTUnwrap(library.save(form.resolved, as: "Mine"))
        XCTAssertTrue(library.exists("Mine"), "a second save of the name asks first")

        var other = ExportForm(options: archive)
        other.pick(try XCTUnwrap(ExportPresetLibrary(store: ExportPresetStore(directory: dir)).preset(named: "Mine")))
        XCTAssertEqual(other.resolved, form.resolved)
        XCTAssertEqual(saved.options, form.resolved)

        XCTAssertNil(library.save(web, as: ""), "an empty name is refused")
        XCTAssertEqual(library.error, PresetError.emptyName.localizedDescription)
    }

    // MARK: Settings

    func testTheLastPickedNameIsRemembered() {
        let suite = "photolab-export-presets-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.exportPreset)
        settings.exportPreset = "Web"
        XCTAssertEqual(defaults.string(forKey: AppSettings.Key.exportPreset), "Web")
        XCTAssertEqual(AppSettings(defaults: defaults).exportPreset, "Web")
        settings.exportPreset = nil
        XCTAssertNil(AppSettings(defaults: defaults).exportPreset, "a deleted pick is forgotten")

        let quiet = AppSettings(defaults: defaults, persistent: false)
        quiet.exportPreset = "Quiet"
        XCTAssertNil(defaults.object(forKey: AppSettings.Key.exportPreset), "a quiet store writes nothing")
    }
}
