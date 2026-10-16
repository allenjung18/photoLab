import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// The loupe panel's History section: labels derived from the recipe diff
/// (`HistoryLabel`), the rows `Library.historyEntries(for:)` lists, and
/// `Library.jumpToHistory(_:for:)`, which steps through undo and redo so a
/// jump is recipe for recipe the same as pressing ⌘Z / ⇧⌘Z that many times.
/// Every folder is a temp directory and every settings store an own suite.
@MainActor
final class HistoryTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// A folder of small gray PNGs, so `Library.scan` sees real images.
    private func makeFolder(_ name: String, files: [String] = ["a.png"]) throws -> URL {
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(file) as CFURL,
                                                       UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        return dir
    }

    private func openLibrary(_ folder: URL) -> Library {
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.selection = lib.photos.first?.id
        return lib
    }

    private func with(_ r: Recipe, _ kind: AdjustmentKind, _ value: Double) -> Recipe {
        var r = r
        r.set(kind, to: value)
        return r
    }

    /// Five single edits on the selected photo: exposure, contrast, grain,
    /// a crop edge, vibrance.
    private func fiveEdits(_ lib: Library) {
        let id = lib.selection!
        for (kind, value) in [(AdjustmentKind.exposure, 0.5), (.contrast, 20), (.grain, 30),
                              (.cropLeft, 10), (.vibrance, -15)] {
            lib.setRecipe(with(lib.recipe(for: id), kind, value), for: id)
        }
    }

    // MARK: Labels

    func testOneKindIsItsNameAndNewValue() {
        let base = with(.neutral, .contrast, 10)
        XCTAssertEqual(HistoryLabel.describe(from: base, to: with(base, .exposure, 0.5), batch: nil), "Exposure +0.50")
        XCTAssertEqual(HistoryLabel.describe(from: base, to: with(base, .contrast, -25), batch: nil), "Contrast -25")
        XCTAssertEqual(HistoryLabel.describe(from: base, to: with(base, .grain, 40), batch: nil), "Grain 40")
        XCTAssertEqual(HistoryLabel.describe(from: base, to: with(base, .hueRed, 12), batch: nil), "Hue Red +12",
                       "an HSL kind names its channel and band")
        var off = base
        off.setEnabled(.contrast, false)
        XCTAssertEqual(HistoryLabel.describe(from: base, to: off, batch: nil), "Contrast off")
        XCTAssertEqual(HistoryLabel.describe(from: off, to: base, batch: nil), "Contrast on")
    }

    func testAnyCropOrRotateKindIsCrop() {
        let base = with(.neutral, .exposure, 1)
        XCTAssertEqual(HistoryLabel.describe(from: base, to: with(base, .cropLeft, 10), batch: nil), "Crop")
        XCTAssertEqual(HistoryLabel.describe(from: base, to: with(base, .rotate, 3), batch: nil), "Crop")
        let both = with(with(with(base, .cropTop, 5), .cropBottom, 5), .rotate, -2)
        XCTAssertEqual(HistoryLabel.describe(from: base, to: both, batch: nil), "Crop", "every geometry kind is one name")
        XCTAssertEqual(HistoryLabel.describe(from: base, to: with(both, .exposure, 2), batch: nil), "Crop, Exposure")
    }

    func testSeveralKindsNameTheFirstTwoAndCountTheRest() {
        let base = Recipe.neutral
        let two = with(with(base, .contrast, 10), .exposure, 0.3)
        XCTAssertEqual(HistoryLabel.describe(from: base, to: two, batch: nil), "Exposure, Contrast", "chain order")
        let four = with(with(two, .highlights, -20), .shadows, 15)
        XCTAssertEqual(HistoryLabel.describe(from: base, to: four, batch: nil), "Exposure, Contrast +2 more")
    }

    func testToTheDefaultIsReset() {
        let edited = with(with(.neutral, .exposure, 0.5), .grain, 20)
        XCTAssertEqual(HistoryLabel.describe(from: edited, to: .neutral, batch: nil), "Reset")
        XCTAssertEqual(HistoryLabel.describe(from: edited, to: .neutral, batch: UUID()), "Sync: Reset")
    }

    func testABatchTagPrefixesSync() {
        let base = Recipe.neutral
        XCTAssertEqual(HistoryLabel.describe(from: base, to: with(base, .contrast, 30), batch: UUID()), "Sync: Contrast +30")
        let look = with(with(with(base, .exposure, 0.2), .contrast, 5), .vibrance, 10)
        XCTAssertEqual(HistoryLabel.describe(from: base, to: look, batch: UUID()), "Sync: Exposure, Contrast +1 more")
    }

    /// Two recipes that differ outside the adjustments' values (here only the
    /// order a sidecar listed them in, standing in for a future field) read
    /// "Edit".
    func testNothingChangedInTheAdjustmentsIsEdit() {
        let a = with(.neutral, .exposure, 0.5)
        let b = Recipe(adjustments: a.adjustments.reversed())
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(HistoryLabel.describe(from: a, to: b, batch: nil), "Edit")
    }

    // MARK: Entries and jump

    func testEntriesListTheOriginalThenEachStepWithTheCurrentRowMarked() throws {
        let lib = openLibrary(try makeFolder("p"))
        let id = lib.selection!
        XCTAssertEqual(lib.historyEntries(for: id), [], "no step yet")
        fiveEdits(lib)
        lib.undo()
        lib.undo()
        let entries = lib.historyEntries(for: id)
        XCTAssertEqual(entries.map(\.label),
                       ["Original", "Exposure +0.50", "Contrast +20", "Grain 30", "Crop", "Vibrance -15"])
        XCTAssertEqual(entries.map(\.position), Array(0...5))
        XCTAssertEqual(entries.filter(\.isCurrent).map(\.position), [3])
        XCTAssertEqual(entries.filter(\.isUndone).map(\.position), [4, 5], "the undone steps sit above the current one")
    }

    /// A jump back 3 then forward 2 leaves, recipe for recipe, what ⌘Z three
    /// times and ⇧⌘Z twice leave on an identical library, sidecar included.
    func testAJumpIsTheSameAsUndoAndRedoThatManyTimes() throws {
        let folderA = try makeFolder("a")
        let jumped = openLibrary(folderA)
        let stepped = openLibrary(try makeFolder("b"))
        fiveEdits(jumped)
        fiveEdits(stepped)
        let j = jumped.selection!, s = stepped.selection!
        XCTAssertEqual(jumped.recipe(for: j), stepped.recipe(for: s))

        jumped.jumpToHistory(2, for: j)
        for _ in 0..<3 { stepped.undo() }
        XCTAssertEqual(jumped.recipe(for: j), stepped.recipe(for: s))
        XCTAssertEqual(jumped.recipe(for: j).value(of: .contrast), 20)
        XCTAssertEqual(jumped.recipe(for: j).value(of: .grain), 0)
        XCTAssertEqual(jumped.historyEntries(for: j).filter(\.isCurrent).map(\.position), [2])

        jumped.jumpToHistory(4, for: j)
        for _ in 0..<2 { stepped.redo() }
        XCTAssertEqual(jumped.recipe(for: j), stepped.recipe(for: s))
        XCTAssertEqual(jumped.recipe(for: j).value(of: .cropLeft), 10)
        XCTAssertEqual(jumped.historyEntries(for: j).map(\.label), stepped.historyEntries(for: s).map(\.label))

        // What the jump left on disk is what the steps left: reopen and read it.
        let reopened = openLibrary(folderA)
        XCTAssertEqual(reopened.recipe(for: reopened.selection!), stepped.recipe(for: s))

        jumped.jumpToHistory(0, for: j)
        XCTAssertTrue(jumped.recipe(for: j).isDefault, "the Original row is the recipe the photo opened with")
        XCTAssertFalse(jumped.canUndo)
    }

    func testAnEditAfterAJumpClearsTheRedoRows() throws {
        let lib = openLibrary(try makeFolder("p"))
        let id = lib.selection!
        fiveEdits(lib)
        lib.jumpToHistory(2, for: id)
        XCTAssertEqual(lib.historyEntries(for: id).filter(\.isUndone).count, 3)
        lib.setRecipe(with(lib.recipe(for: id), .clarity, 25), for: id)
        let entries = lib.historyEntries(for: id)
        XCTAssertEqual(entries.map(\.label), ["Original", "Exposure +0.50", "Contrast +20", "Clarity +25"])
        XCTAssertTrue(entries.allSatisfy { !$0.isUndone })
        XCTAssertEqual(entries.last?.isCurrent, true)
        XCTAssertFalse(lib.canRedo)
    }

    /// A jump back past a sync takes the sync off every photo of it, as ⌘Z
    /// does; a jump forward over it puts it back on every one.
    func testAJumpPastASyncMovesEveryMember() throws {
        let lib = openLibrary(try makeFolder("p", files: ["a.png", "b.png", "c.png"]))
        let ids = lib.photos.map(\.id)
        lib.selection = ids[0]
        // A crop first: the look mask never carries geometry, so it survives the sync.
        lib.setRecipe(with(.neutral, .cropLeft, 10), for: ids[0])
        _ = lib.sync(with(.neutral, .contrast, 30), mask: .look, to: ids)
        lib.setRecipe(with(lib.recipe(for: ids[0]), .grain, 40), for: ids[0])
        XCTAssertEqual(lib.historyEntries(for: ids[0]).map(\.label),
                       ["Original", "Crop", "Sync: Contrast +30", "Grain 40"])
        XCTAssertEqual(lib.historyEntries(for: ids[1]).map(\.label), ["Original", "Sync: Contrast +30"])

        lib.jumpToHistory(1, for: ids[0])
        XCTAssertEqual(lib.recipe(for: ids[0]).value(of: .contrast), 0)
        XCTAssertEqual(lib.recipe(for: ids[0]).value(of: .cropLeft), 10)
        XCTAssertTrue(lib.recipe(for: ids[1]).isDefault, "the sync came off photo b")
        XCTAssertTrue(lib.recipe(for: ids[2]).isDefault, "and off photo c")

        lib.jumpToHistory(3, for: ids[0])
        XCTAssertEqual(ids.filter { lib.recipe(for: $0).value(of: .contrast) == 30 }.count, 3)
        XCTAssertEqual(lib.recipe(for: ids[0]).value(of: .grain), 40)
    }

    func testEntriesAreEmptyAfterOpen() throws {
        let folder = try makeFolder("p")
        let lib = openLibrary(folder)
        let id = lib.selection!
        fiveEdits(lib)
        XCTAssertEqual(lib.historyEntries(for: id).count, 6)
        lib.open(folder)
        XCTAssertEqual(lib.historyEntries(for: id), [], "open resets the history; it is never persisted")
        XCTAssertEqual(lib.recipe(for: id).value(of: .vibrance), -15, "the edit itself is kept in the sidecar")
    }

    /// A slider drag shows as the newest row while it runs, and becomes
    /// that same row when it ends.
    func testADragShowsLiveAsTheNewestRow() throws {
        let lib = openLibrary(try makeFolder("p"))
        let id = lib.selection!
        lib.setRecipe(with(.neutral, .exposure, 0.5), for: id)
        lib.beginEdit(id)
        lib.setRecipe(with(lib.recipe(for: id), .contrast, 12), for: id)
        let live = lib.historyEntries(for: id)
        XCTAssertEqual(live.map(\.label), ["Original", "Exposure +0.50", "Contrast +12"])
        XCTAssertEqual(live.last?.isCurrent, true)
        lib.endEdit(id)
        XCTAssertEqual(lib.historyEntries(for: id), live)
    }

    // MARK: Setting

    func testTheSectionsOpenStateIsRemembered() {
        let suite = "photolab-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        XCTAssertFalse(s.showHistory)
        let lib = Library(settings: s)
        lib.showHistory = true
        XCTAssertEqual(defaults.object(forKey: AppSettings.Key.showHistory) as? Bool, true)
        XCTAssertTrue(AppSettings(defaults: defaults).showHistory)
        XCTAssertFalse(AppSettings(defaults: defaults, persistent: false).showHistory, "a test store reads nothing")
    }
}
