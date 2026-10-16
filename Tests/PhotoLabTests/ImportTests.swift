import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Import from Card (Import.swift): the dated layout, duplicates and
/// numbering, the card only ever read, cancel and the hidden `.partial`
/// file, the common folder Open shows, and the card listing over a fake
/// `VolumeLister`. Every card here is a temporary folder: no test lists or
/// reads a real volume.
@MainActor
final class ImportTests: XCTestCase {
    private var base: URL!
    private var card: URL!
    private var root: URL!
    private var suite: String!

    /// The fixture capture dates, by file name (local time).
    private var dates: [String: Date] = [:]

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-import-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        card = base.appendingPathComponent("CARD", isDirectory: true)
        root = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        suite = "photolab-import-\(UUID().uuidString)"
        dates = [:]
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Fixtures

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    /// A small JPEG at `path` under the card; `seed` changes its pixels (and
    /// so its size); `exif` writes an EXIF DateTimeOriginal.
    @discardableResult
    private func jpeg(_ path: String, seed: Int = 0, date: Date? = nil, exif: String? = nil, under dir: URL? = nil) throws -> URL {
        let url = (dir ?? card).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = syntheticImage(width: 40 + seed * 8, height: 30 + seed * 4)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let exif { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exif] }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        if let date { dates[url.lastPathComponent] = date }
        return url
    }

    private func bytes(_ path: String, _ data: Data, date: Date? = nil) throws {
        let url = card.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let date { dates[url.lastPathComponent] = date }
    }

    /// The fake card: DCIM/100MSDCF with three JPEGs on two days, a RAW+JPEG
    /// pair, a video, an XMP sidecar, a nested folder with one more JPEG,
    /// and a hidden AppleDouble file.
    private func makeCard() throws {
        try jpeg("DCIM/100MSDCF/DSC0001.JPG", seed: 0, date: day(2026, 10, 14))
        try jpeg("DCIM/100MSDCF/DSC0002.JPG", seed: 1, date: day(2026, 10, 14))
        try jpeg("DCIM/100MSDCF/DSC0003.JPG", seed: 2, date: day(2026, 10, 15))
        try bytes("DCIM/100MSDCF/DSC0004.ARW", Data(repeating: 7, count: 300), date: day(2026, 10, 15))
        try jpeg("DCIM/100MSDCF/DSC0004.JPG", seed: 3, date: day(2026, 10, 15))
        try bytes("DCIM/100MSDCF/C0001.MP4", Data(repeating: 1, count: 500), date: day(2026, 10, 15))
        try bytes("DCIM/100MSDCF/DSC0001.XMP", Data("<x/>".utf8))
        try jpeg("DCIM/100MSDCF/sub/DSC0100.JPG", seed: 4, date: day(2026, 10, 15))
        try bytes("DCIM/100MSDCF/._DSC0001.JPG", Data(repeating: 0, count: 20))
    }

    private var dateReader: @Sendable (URL) -> Date? {
        let dates = self.dates
        return { dates[$0.lastPathComponent] }
    }

    private func plan(_ source: URL? = nil) -> ImportPlan {
        ImportPlan.make(source: source ?? card, root: root, captureDate: dateReader)
    }

    private func relative(_ url: URL, to dir: URL) -> String {
        String(url.path.dropFirst(dir.path.count + 1))
    }

    /// Every file under `dir` (hidden ones included) with its bytes and
    /// modification date.
    private func tree(_ dir: URL) throws -> [String: (Data, Date)] {
        var out: [String: (Data, Date)] = [:]
        let e = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let mtime = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
            out[relative(url.resolvingSymlinksInPath(), to: dir)] = (try Data(contentsOf: url), mtime)
        }
        return out
    }

    private func partials(under dir: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { ($0 as? URL)?.lastPathComponent }.filter { $0.hasSuffix(".partial") }
    }

    private func importer(lister: FakeLister = FakeLister([]),
                          ejected: EjectLog = EjectLog(),
                          copier: Importer.Copier? = nil) -> Importer {
        let log = ejected
        if let copier {
            return Importer(settings: AppSettings(persistent: false), lister: lister, captureDate: dateReader,
                            ejector: { log.urls.append($0) }, copier: copier)
        }
        return Importer(settings: AppSettings(persistent: false), lister: lister, captureDate: dateReader,
                        ejector: { log.urls.append($0) })
    }

    // MARK: The plan

    func testEveryImageGoesToItsCaptureDayAndVideosAndOtherFilesAreSkippedAndCounted() throws {
        try makeCard()
        let p = plan(card.appendingPathComponent("DCIM"))
        XCTAssertEqual(p.copies.map { relative($0.destination, to: root) }, [
            "2026/2026-10-14/DSC0001.JPG",
            "2026/2026-10-14/DSC0002.JPG",
            "2026/2026-10-15/DSC0003.JPG",
            "2026/2026-10-15/DSC0004.ARW",
            "2026/2026-10-15/DSC0004.JPG",
            "2026/2026-10-15/DSC0100.JPG",
        ])
        XCTAssertEqual(p.otherFiles, 2, "the MP4 and the XMP; the hidden ._ file is not counted")
        XCTAssertTrue(p.already.isEmpty)
        XCTAssertEqual(ImportSheet.summaryLine(p), "6 new · 0 already imported · 2 other files skipped")
    }

    func testTheDefaultDateIsTheExifDateTimeOriginalInLocalTime() throws {
        try jpeg("DCIM/100CANON/IMG_0001.JPG", exif: "2024:03:05 23:30:00")
        let p = ImportPlan.make(source: card, root: root)
        XCTAssertEqual(p.copies.map { relative($0.destination, to: root) }, ["2024/2024-03-05/IMG_0001.JPG"])
    }

    func testAFileWithNoDateGoesToUndated() throws {
        try jpeg("DCIM/100MSDCF/DSC0001.JPG")
        let p = ImportPlan.make(source: card, root: root, captureDate: { _ in nil })
        XCTAssertEqual(p.copies.map { relative($0.destination, to: root) }, ["Undated/DSC0001.JPG"])
    }

    // MARK: Duplicates and numbering

    func testASecondImportSkipsEveryPhotoAsAlreadyImported() async throws {
        try makeCard()
        let imp = importer()
        imp.setRoot(root)
        imp.choose(.folder(card))
        await imp.waitForPlan()
        imp.start()
        await imp.wait()
        XCTAssertEqual(imp.done, 6)
        let again = plan()
        XCTAssertTrue(again.copies.isEmpty, "\(again.copies.map(\.destination.lastPathComponent))")
        XCTAssertEqual(again.already.count, 6)
        XCTAssertEqual(ImportSheet.summaryLine(again), "0 new · 6 already imported · 2 other files skipped")
    }

    /// The mutant's target: a file of the same name but another size is a
    /// different photo, numbered beside it; never skipped, never overwritten.
    func testSameNameAndAnotherSizeIsNumberedAndTheFileThereIsUntouched() throws {
        try jpeg("DCIM/100MSDCF/DSC0001.JPG", seed: 0, date: day(2026, 10, 14))
        let dayFolder = root.appendingPathComponent("2026/2026-10-14", isDirectory: true)
        let other = try jpeg("DSC0001.JPG", seed: 5, under: dayFolder)
        let before = try Data(contentsOf: other)
        let p = plan()
        XCTAssertEqual(p.copies.map { relative($0.destination, to: root) }, ["2026/2026-10-14/DSC0001 2.JPG"])
        XCTAssertTrue(p.already.isEmpty)
        let numbered = try XCTUnwrap(p.copies.first)
        try Importer.copy(numbered.source, to: numbered.destination)
        XCTAssertEqual(try Data(contentsOf: other), before)
        // Imported again: the numbered copy is that photo (same size), skipped.
        let again = plan()
        XCTAssertTrue(again.copies.isEmpty)
        XCTAssertEqual(again.already.map { relative($0.destination, to: root) }, ["2026/2026-10-14/DSC0001 2.JPG"])
    }

    func testTwoFilesOfOneNameOnOneDayAreNumbered() throws {
        try jpeg("DCIM/100MSDCF/DSC0001.JPG", seed: 0, date: day(2026, 10, 14))
        try jpeg("DCIM/101MSDCF/DSC0001.JPG", seed: 1, date: day(2026, 10, 14))
        XCTAssertEqual(plan().copies.map { relative($0.destination, to: root) },
                       ["2026/2026-10-14/DSC0001.JPG", "2026/2026-10-14/DSC0001 2.JPG"])
        XCTAssertEqual(ImportPlan.numbered("README", 3), "README 3")
    }

    // MARK: The run

    func testARunCopiesThePlanAndLeavesTheCardByteIdentical() async throws {
        try makeCard()
        let cardBefore = try tree(card)
        let imp = importer()
        imp.setRoot(root)
        imp.choose(.folder(card))
        await imp.waitForPlan()
        let p = try XCTUnwrap(imp.plan)
        imp.start()
        await imp.wait()
        XCTAssertEqual(imp.state, .finished)
        XCTAssertEqual(imp.done, 6)
        XCTAssertTrue(imp.failures.isEmpty)
        for item in p.copies {
            XCTAssertEqual(try Data(contentsOf: item.destination), try Data(contentsOf: item.source))
        }
        let cardAfter = try tree(card)
        XCTAssertEqual(Set(cardAfter.keys), Set(cardBefore.keys))
        for (path, (data, mtime)) in cardBefore {
            XCTAssertEqual(cardAfter[path]?.0, data, path)
            XCTAssertEqual(cardAfter[path]?.1, mtime, path)
        }
        XCTAssertEqual(partials(under: root), [])
        XCTAssertEqual(partials(under: card), [])
    }

    func testCancelStopsAfterTheFileInFlightAndLeavesNoPartialFile() async throws {
        try makeCard()
        let started = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let imp = importer(copier: { source, destination in
            started.signal()
            go.wait()
            try Importer.copy(source, to: destination)
        })
        imp.setRoot(root)
        imp.choose(.folder(card))
        await imp.waitForPlan()
        imp.start()
        await Task.detached { blockUntilSignalled(started) }.value
        imp.cancel()
        for _ in 0..<10 { go.signal() }
        await imp.wait()
        XCTAssertEqual(imp.state, .cancelled)
        XCTAssertEqual(imp.done, 1, "the file in flight finishes; no other starts")
        XCTAssertEqual(try tree(root).count, 1)
        XCTAssertEqual(partials(under: root), [])
        XCTAssertEqual(imp.openFolder, root.appendingPathComponent("2026/2026-10-14", isDirectory: true))
    }

    func testACopyThatFailsLeavesNoPartialFileAndNeverOverwrites() throws {
        let source = try jpeg("DCIM/100MSDCF/DSC0001.JPG", seed: 0)
        let dest = root.appendingPathComponent("2026/2026-10-14/DSC0001.JPG")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let there = Data("already here".utf8)
        try there.write(to: dest)
        XCTAssertThrowsError(try Importer.copy(source, to: dest))
        XCTAssertEqual(try Data(contentsOf: dest), there)
        XCTAssertEqual(partials(under: root), [])
        XCTAssertEqual(Importer.partialURL(for: dest).lastPathComponent, ".DSC0001.JPG.partial")
    }

    // MARK: Open

    func testTheCommonFolderIsTheDayThenTheYearThenTheRoot() {
        func item(_ day: String?) -> ImportPlan.Item {
            ImportPlan.Item(source: card, destination: root, size: 1, day: day)
        }
        let r = root!
        XCTAssertEqual(ImportPlan.commonFolder(of: [item("2026-10-14"), item("2026-10-14")], root: r),
                       r.appendingPathComponent("2026/2026-10-14", isDirectory: true))
        XCTAssertEqual(ImportPlan.commonFolder(of: [item("2026-10-14"), item("2026-01-02")], root: r),
                       r.appendingPathComponent("2026", isDirectory: true))
        XCTAssertEqual(ImportPlan.commonFolder(of: [item("2026-10-14"), item("2025-12-31")], root: r), r)
        XCTAssertEqual(ImportPlan.commonFolder(of: [item("2026-10-14"), item(nil)], root: r), r)
        XCTAssertEqual(ImportPlan.commonFolder(of: [item(nil)], root: r),
                       r.appendingPathComponent("Undated", isDirectory: true))
        XCTAssertEqual(ImportPlan.commonFolder(of: [], root: r), r)
    }

    func testOpenOpensTheImportsCommonFolderInTheLibrary() async throws {
        try jpeg("DCIM/100MSDCF/DSC0001.JPG", seed: 0, date: day(2026, 10, 14))
        try jpeg("DCIM/100MSDCF/DSC0002.JPG", seed: 1, date: day(2026, 10, 15))
        let imp = importer()
        imp.setRoot(root)
        imp.choose(.folder(card))
        await imp.waitForPlan()
        XCTAssertNil(imp.openFolder, "nothing to open before a run")
        imp.start()
        await imp.wait()
        let library = Library(rememberFolder: false)
        imp.sheetShown = true
        imp.open(in: library)
        let opened = try XCTUnwrap(library.source as? FolderSource)
        XCTAssertEqual(opened.folder, root.appendingPathComponent("2026", isDirectory: true))
        XCTAssertEqual(library.photos.count, 2)
        XCTAssertFalse(imp.sheetShown)
    }

    // MARK: After import (Auto / preset on Open)

    /// Photo A is imported first (so it is "already imported" in the second
    /// run); the card then holds A plus B, C, D (3 new + 1 already). Returns
    /// the second run's importer with `develop` set, its library after
    /// `open(in:presets:)`, and the day folder.
    private func secondRun(_ develop: ImportDevelop, presets: [Preset] = []) async throws
        -> (imp: Importer, library: Library, folder: URL) {
        let d = day(2026, 10, 14)
        try jpeg("DCIM/A.JPG", seed: 0, date: d)
        let first = importer()
        first.setRoot(root)
        first.choose(.folder(card))
        await first.waitForPlan()
        first.start()
        await first.wait()
        for (i, n) in ["B", "C", "D"].enumerated() { try jpeg("DCIM/\(n).JPG", seed: i + 1, date: d) }
        let imp = importer()
        imp.setRoot(root)
        imp.develop = develop
        imp.choose(.folder(card))
        await imp.waitForPlan()
        XCTAssertEqual(imp.plan?.copies.count, 3)
        XCTAssertEqual(imp.plan?.already.count, 1)
        imp.start()
        await imp.wait()
        let library = Library(rememberFolder: false)
        imp.sheetShown = true
        imp.open(in: library, presets: presets)
        await imp.waitDevelop()
        let folder = root.appendingPathComponent("2026/2026-10-14", isDirectory: true)
        return (imp, library, folder)
    }

    private func photoID(_ library: Library, _ name: String) throws -> Photo.ID {
        try XCTUnwrap(library.photos.first { $0.fileURL?.lastPathComponent == name }).id
    }

    func testAutoOnImportEditsTheThreeCopiesAndLeavesTheAlreadyImportedOne() async throws {
        let (_, library, _) = try await secondRun(.auto)
        XCTAssertEqual(library.photos.count, 4)
        for n in ["B.JPG", "C.JPG", "D.JPG"] {
            XCTAssertFalse(library.recipe(for: try photoID(library, n)).isNeutral, "\(n) got Auto values")
        }
        XCTAssertTrue(library.recipe(for: try photoID(library, "A.JPG")).isNeutral,
                      "the already imported photo is untouched")
        // One Cmd-Z takes the lot back.
        library.selection = try photoID(library, "B.JPG")
        library.undo()
        for n in ["B.JPG", "C.JPG", "D.JPG"] {
            XCTAssertTrue(library.recipe(for: try photoID(library, n)).isNeutral, "\(n) back after one undo")
        }
        XCTAssertFalse(library.canUndo)
    }

    func testAPresetOnImportGivesTheThreeCopiesItsLook() async throws {
        let punchy = try XCTUnwrap(Preset.starters.first { $0.name == "Punchy" })
        let (_, library, _) = try await secondRun(.preset("Punchy"), presets: Preset.starters)
        for n in ["B.JPG", "C.JPG", "D.JPG"] {
            XCTAssertTrue(punchy.matches(library.recipe(for: try photoID(library, n))), "\(n) shows Punchy")
        }
        XCTAssertTrue(library.recipe(for: try photoID(library, "A.JPG")).isNeutral)
    }

    func testNoneOnImportWritesNoSidecar() async throws {
        let (_, library, folder) = try await secondRun(.none)
        for photo in library.photos { XCTAssertTrue(library.recipe(for: photo.id).isNeutral) }
        let sidecars = folder.appendingPathComponent(".photolab")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecars.path), "no .photolab folder was written")
    }

    func testDismissingWithoutOpenAppliesNothing() async throws {
        try jpeg("DCIM/A.JPG", seed: 0, date: day(2026, 10, 14))
        let imp = importer()
        imp.setRoot(root)
        imp.develop = .auto
        imp.choose(.folder(card))
        await imp.waitForPlan()
        imp.start()
        await imp.wait()
        imp.dismiss()
        let library = Library(rememberFolder: false)
        library.open(root.appendingPathComponent("2026/2026-10-14", isDirectory: true))
        XCTAssertTrue(library.recipe(for: library.photos[0].id).isNeutral)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("2026/2026-10-14/.photolab").path))
    }

    func testTheChoiceRoundTripsThroughAppSettingsAndAMissingPresetFallsBackToNone() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.importDevelop, .none)
        for choice: ImportDevelop in [.auto, .preset("Punchy"), .none] {
            settings.importDevelop = choice
            XCTAssertEqual(AppSettings(defaults: defaults).importDevelop, choice)
        }
        settings.importDevelop = .preset("Gone")
        let resolved = AppSettings(defaults: defaults).importDevelop.resolved(in: Preset.starters)
        XCTAssertEqual(resolved.choice, .none)
        XCTAssertNotNil(resolved.note)
        XCTAssertEqual(ImportDevelop.preset("Punchy").resolved(in: Preset.starters).choice, .preset("Punchy"))
        XCTAssertEqual(ImportSheet.openTitle(.auto), "Open and Auto")
        XCTAssertEqual(ImportSheet.openTitle(.preset("Punchy")), "Open and Apply Punchy")
        XCTAssertEqual(ImportSheet.openTitle(.none), "Open")
        defaults.removePersistentDomain(forName: suite)
    }

    func testAMissingPresetAtOpenAppliesNothing() async throws {
        let (_, library, _) = try await secondRun(.preset("Gone"), presets: Preset.starters)
        for photo in library.photos { XCTAssertTrue(library.recipe(for: photo.id).isNeutral) }
    }

    // MARK: Cards

    func testOnlyRemovableOrEjectableVolumesWithADCIMFolderAreCards() throws {
        let sd = base.appendingPathComponent("vol/SD", isDirectory: true)
        let camera = base.appendingPathComponent("vol/CAMERA", isDirectory: true)
        let stick = base.appendingPathComponent("vol/STICK", isDirectory: true)
        let disk = base.appendingPathComponent("vol/Disk", isDirectory: true)
        try jpeg("DCIM/100MSDCF/A.JPG", under: sd)
        try jpeg("dcim/100CANON/B.JPG", under: camera)
        try jpeg("Photos/C.JPG", under: stick)
        try jpeg("DCIM/D.JPG", under: disk)
        let gone = base.appendingPathComponent("vol/GONE", isDirectory: true)
        let lister = FakeLister([
            MountedVolume(url: disk, name: "Disk", isRemovable: false, isEjectable: false),
            MountedVolume(url: sd, name: "SD", isRemovable: true, isEjectable: true),
            MountedVolume(url: stick, name: "STICK", isRemovable: true, isEjectable: true),
            MountedVolume(url: camera, name: "CAMERA", isRemovable: false, isEjectable: true),
            MountedVolume(url: gone, name: "GONE", isRemovable: true, isEjectable: true),
        ])
        let listing = CardVolumes.list(lister)
        XCTAssertEqual(listing.cards.map(\.name), ["SD", "CAMERA"], "the stick has no DCIM; the disk is fixed")
        XCTAssertEqual(listing.cards.map(\.dcim.lastPathComponent), ["DCIM", "dcim"])
        XCTAssertEqual(listing.unreadable.map(\.name), ["GONE"])
        XCTAssertFalse(listing.unreadable[0].isPermission)
        for card in listing.cards { XCTAssertTrue(card.volume.path.hasPrefix(base.path), "no real volume") }
        XCTAssertEqual(lister.calls.count, 1)
    }

    func testAPermissionRefusalIsRecognisedForOpenSystemSettings() {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        XCTAssertTrue(CardVolumes.isPermissionError(denied))
        XCTAssertTrue(CardVolumes.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertFalse(CardVolumes.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
    }

    func testTheSheetListsTheFakeCardsPicksTheFirstAndEjectIsOnlyAButton() async throws {
        try makeCard()
        let lister = FakeLister([MountedVolume(url: card, name: "CARD", isRemovable: true, isEjectable: true)])
        let log = EjectLog()
        let imp = importer(lister: lister, ejected: log)
        imp.setRoot(root)
        imp.request()
        XCTAssertTrue(imp.sheetShown)
        while !imp.listingDone { await Task.yield() }
        await imp.waitForPlan()
        XCTAssertEqual(imp.source?.card?.name, "CARD")
        XCTAssertEqual(imp.plan?.copies.count, 6)
        imp.start()
        await imp.wait()
        XCTAssertEqual(log.urls, [], "the run never ejects")
        imp.eject()
        XCTAssertEqual(log.urls, [card])
        XCTAssertTrue(imp.ejected)
        XCTAssertTrue(imp.listing.cards.isEmpty)
        imp.eject()
        XCTAssertEqual(log.urls.count, 1)
        // A chosen folder is not a card: no Eject.
        imp.dismiss()
        imp.choose(.folder(card))
        imp.eject()
        XCTAssertEqual(log.urls.count, 1)
    }

    // MARK: Settings and the command

    func testTheRootIsRememberedAndDefaultsToPicturesPhotoLab() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let first = Importer(settings: AppSettings(defaults: defaults), lister: FakeLister([]))
        XCTAssertEqual(first.root.lastPathComponent, "PhotoLab")
        XCTAssertEqual(first.root.deletingLastPathComponent().lastPathComponent, "Pictures")
        first.setRoot(root)
        let second = Importer(settings: AppSettings(defaults: defaults), lister: FakeLister([]))
        XCTAssertEqual(second.root.path, root.path)
        defaults.removePersistentDomain(forName: suite)
    }

    func testShiftCommandIOpensTheSheet() {
        let command = AppCommand.command(.importCard)
        XCTAssertEqual(command.key, "i")
        XCTAssertEqual(command.modifiers, [.command, .shift])
        XCTAssertEqual(command.placement, .importExport)
        let imp = importer()
        let context = CommandContext(library: Library(rememberFolder: false), imports: imp)
        XCTAssertTrue(command.isEnabled(context))
        command.perform(context)
        XCTAssertTrue(imp.sheetShown)
    }
}

/// A `VolumeLister` over fixed volumes (temporary folders), counting calls.
final class FakeLister: VolumeLister, @unchecked Sendable {
    let mounted: [MountedVolume]
    private(set) var calls: [Date] = []
    init(_ mounted: [MountedVolume]) { self.mounted = mounted }
    func volumes() -> [MountedVolume] {
        calls.append(Date())
        return mounted
    }
}

/// The volumes an `Importer`'s ejector was asked to eject.
@MainActor
final class EjectLog {
    var urls: [URL] = []
}

/// Waits on `semaphore` from a synchronous frame (a detached task's body
/// calls it, off the main actor).
private func blockUntilSignalled(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}
