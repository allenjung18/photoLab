import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import PhotoLab

/// The behaviour behind the UI review's polish items: the filter-empty
/// state's way back, the export result's details, the View › Show menu, and
/// the everyday wording that hides developer timings.
@MainActor
final class UIPolishTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-polish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "photolab-polish-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, type: UTType = .png) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let url = folder.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// UI-09: the filter-empty state's Show All button sets the filter back
    /// to All, which brings every photo back.
    func testShowAllBringsEveryPhotoBackFromAnEmptyFilter() throws {
        _ = try write("a.png"); _ = try write("b.png")
        let lib = Library(rememberFolder: false, defaults: defaults)
        lib.open(folder)
        lib.filter = .rejected
        XCTAssertTrue(lib.visiblePhotos.isEmpty)
        ShowFilterChoices.choose(.all, in: lib)   // the button's action
        XCTAssertEqual(lib.filter, .all)
        XCTAssertEqual(lib.visiblePhotos.count, 2)
    }

    /// UI-18: View › Show offers every filter of the bar, in its order, and
    /// choosing one filters the grid.
    func testTheShowMenuListsEveryFilterAndChoosingOneFiltersTheGrid() throws {
        _ = try write("a.png"); _ = try write("b.png")
        let lib = Library(rememberFolder: false, defaults: defaults)
        lib.open(folder)
        XCTAssertEqual(ShowFilterChoices.all.map(\.label),
                       ["All", "Picks", "Unflagged", "Rejected", "≥ 1★", "≥ 2★", "≥ 3★", "≥ 4★", "≥ 5★"])
        let a = try XCTUnwrap(lib.photos.first { $0.name == "a.png" }).id
        lib.setFlag(.pick, for: [a])
        ShowFilterChoices.choose(.picks, in: lib)
        XCTAssertEqual(lib.visiblePhotos.map(\.id), [a])
        ShowFilterChoices.choose(.stars(3), in: lib)
        XCTAssertTrue(lib.visiblePhotos.isEmpty)
    }

    /// UI-14: the result's Details… lists every failure with its reason and
    /// every skipped file, not only the first failure.
    func testExportDetailsListEveryFailureAndSkip() async throws {
        let png = try write("x.png")
        _ = try write("x.jpg", type: .jpeg)
        let lib = Library(rememberFolder: false, defaults: defaults)
        lib.open(folder)
        let id = try XCTUnwrap(lib.photos.first { $0.fileURL?.lastPathComponent == "x.png" }?.id)
        var overwrite = ExportOptions()
        overwrite.collision = .overwrite
        overwrite.format = .jpeg
        overwrite.suffix = ""
        let items = try await lib.exportItems(for: [id])
        let queue = ExportQueue()
        XCTAssertTrue(queue.detailLines.isEmpty)
        queue.start(items, into: folder, options: overwrite)
        await queue.wait()
        XCTAssertEqual(queue.detailLines,
                       ["x.png — x.jpg is an original in the library; it is never overwritten."])

        // A skipped file: exporting twice into another folder with Skip.
        let out = folder.appendingPathComponent("out", isDirectory: true)
        var skip = ExportOptions()
        skip.collision = .skip
        let first = ExportQueue()
        first.start(items, into: out, options: skip)
        await first.wait()
        XCTAssertTrue(first.detailLines.isEmpty, "a clean run has nothing to detail")
        let second = ExportQueue()
        second.start(items, into: out, options: skip)
        await second.wait()
        XCTAssertEqual(second.detailLines.count, 1)
        XCTAssertTrue(second.detailLines[0].hasSuffix("already exists, skipped"))
        _ = png
    }

    /// UI-11: timings stay out of the everyday UI unless `showTimings` is on.
    func testTimingsAreHiddenUnlessTheDefaultIsOn() {
        let key = "showTimings"
        let before = UserDefaults.standard.object(forKey: key)
        defer { if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(DeveloperInfo.showTimings)
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(DeveloperInfo.showTimings)
    }

    /// UI-11: the Photos reasons speak of "this photo", never a raw local id.
    func testPhotosReasonsNameNoIdentifier() {
        for error in [PhotosError.noOriginal("C/L0/001"), .assetMissing("C/L0/001"), .cannotEdit("C/L0/001")] {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("C/L0/001"), text)
            XCTAssertTrue(text.contains("this photo") || text.contains("This photo"), text)
        }
    }

    /// UI-17: the curve's five regions no longer reuse Basic's slider names.
    func testCurveLabelsAreDistinctFromBasicsSliders() {
        let curve = (AdjustmentKind.Section.basic.kinds + AdjustmentKind.Section.curve.kinds)
        let labels = curve.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "no two sliders of Basic and Tone Curve share a name")
    }

    /// UI-20: the preset strip fades its edge only when the cells overflow.
    func testPresetStripOverflowsOnlyWhenTheCellsAreWiderThanTheStrip() {
        XCTAssertFalse(PresetStrip.overflows(count: 3, width: 248))   // 232 pt of cells
        XCTAssertTrue(PresetStrip.overflows(count: 4, width: 248))    // 312 pt
        XCTAssertFalse(PresetStrip.overflows(count: 0, width: 248))
        XCTAssertFalse(PresetStrip.overflows(count: 9, width: 0), "unmeasured: no fade")
    }
}
