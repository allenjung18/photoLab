import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// The export name template (`RenameTemplate`, `ExportOptions.nameTemplate`):
/// each token, `{seq}` padding, the empty and unsafe cases, a stored
/// `exportOptions` from before the field, and a real three-photo export into
/// a temporary folder. Every file lives under a temporary directory.
@MainActor
final class RenameTemplateTests: XCTestCase {
    private var base: URL!
    private var folder: URL!
    private var outDir: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-rename-\(UUID().uuidString)", isDirectory: true)
        folder = base.appendingPathComponent("photos", isDirectory: true)
        outDir = base.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func writePNG(_ name: String) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let url = folder.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// 2026-03-14 12:00 local time.
    private var march14: Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: 2026, month: 3, day: 14, hour: 12))!
    }

    // MARK: Tokens

    func testEachTokenAndLiteralText() {
        let t = RenameTemplate(pattern: "{name}", start: 1)
        XCTAssertEqual(t.stem(name: "DSC06727", date: march14, index: 0, count: 1), "DSC06727")
        XCTAssertEqual(RenameTemplate(pattern: "{date}").stem(name: "a", date: march14, index: 0, count: 1), "2026-03-14")
        XCTAssertEqual(RenameTemplate(pattern: "{date}").stem(name: "a", date: nil, index: 0, count: 1), RenameTemplate.undated)
        XCTAssertEqual(RenameTemplate(pattern: "{seq}").stem(name: "a", date: nil, index: 2, count: 3), "3", "1-based")
        XCTAssertEqual(RenameTemplate(pattern: "trip {date} #{seq} ({name})").stem(name: "IMG_1", date: march14, index: 0, count: 5),
                       "trip 2026-03-14 #1 (IMG_1)", "literal text is kept")
        XCTAssertEqual(RenameTemplate(pattern: "{seq}-{seq}").stem(name: "a", date: nil, index: 1, count: 2), "2-2",
                       "a token may repeat")
        XCTAssertEqual(RenameTemplate(pattern: "{Name}").stem(name: "a", date: nil, index: 0, count: 1), "{Name}",
                       "an unknown token is literal text")
    }

    func testSeqPaddingFollowsTheBatchWidthAndTheStartNumber() {
        let t = RenameTemplate(pattern: "{seq}")
        func seqs(_ t: RenameTemplate, _ count: Int) -> [String] {
            t.stems(for: Array(repeating: (name: "x", date: nil as Date?), count: count))
        }
        let nine = seqs(t, 9)
        XCTAssertEqual(nine.first, "1"); XCTAssertEqual(nine.last, "9")
        let ten = seqs(t, 10)
        XCTAssertEqual(ten.first, "01"); XCTAssertEqual(ten[8], "09"); XCTAssertEqual(ten.last, "10")
        let hundred = seqs(t, 100)
        XCTAssertEqual(hundred.first, "001"); XCTAssertEqual(hundred[9], "010"); XCTAssertEqual(hundred.last, "100")
        XCTAssertEqual(Set(hundred.map(\.count)), [3])

        // The start number is the first photo's, and the width is the
        // largest number reached: 95…104 is three digits.
        let from95 = seqs(RenameTemplate(pattern: "{seq}", start: 95), 10)
        XCTAssertEqual(from95.first, "095"); XCTAssertEqual(from95.last, "104")
        XCTAssertEqual(seqs(RenameTemplate(pattern: "{seq}", start: 0), 3), ["0", "1", "2"])
        XCTAssertEqual(seqs(RenameTemplate(pattern: "{seq}", start: -5), 2), ["0", "1"], "a negative start is 0")
    }

    func testAnEmptyResultFallsBackToTheName() {
        XCTAssertEqual(RenameTemplate(pattern: "").stem(name: "DSC1", date: nil, index: 0, count: 1), "DSC1")
        XCTAssertEqual(RenameTemplate(pattern: "  ").stem(name: "DSC1", date: nil, index: 0, count: 1), "DSC1")
        XCTAssertEqual(RenameTemplate(pattern: "/:").stem(name: "DSC1", date: nil, index: 0, count: 1), "DSC1",
                       "nothing left once cleaned")
    }

    func testUnsafeCharactersAreRemovedByTheSuffixRule() {
        let t = RenameTemplate(pattern: "a/b:c\\d\u{0}e\nf {name}")
        XCTAssertEqual(t.stem(name: "x", date: nil, index: 0, count: 1), "abcdef x")
        var o = ExportOptions()
        o.suffix = "a/b:c\\d\u{0}e\nf"
        XCTAssertEqual(o.cleanSuffix, "abcdef", "the one rule for suffix and template")
        XCTAssertEqual(RenameTemplate.clean(o.suffix), o.cleanSuffix)
    }

    // MARK: Options

    func testStoredOptionsWithoutATemplateDecodeUnchanged() throws {
        // An exportOptions value as a build before the template stored it.
        let old = #"{"format":"heic","quality":0.8,"keepMetadata":true,"suffix":"-edit","collision":"skip"}"#
        let o = try JSONDecoder().decode(ExportOptions.self, from: Data(old.utf8))
        XCTAssertNil(o.nameTemplate)
        XCTAssertEqual(o.suffix, "-edit")
        XCTAssertEqual(o.format, .heic)
        XCTAssertEqual(o.fileName(for: URL(fileURLWithPath: "/p/DSC1.ARW")), "DSC1-edit.heic", "today's <stem><suffix>")

        // Through AppSettings' exportOptions key.
        let suite = "photolab-rename-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(old.utf8), forKey: "exportOptions")
        let read = try XCTUnwrap(AppSettings(defaults: defaults).exportOptions)
        XCTAssertEqual(read, o)

        // A template round-trips; a stored template missing a field takes its default.
        var t = o
        t.nameTemplate = RenameTemplate(pattern: "{date}-{seq}", start: 5)
        XCTAssertEqual(try JSONDecoder().decode(ExportOptions.self, from: JSONEncoder().encode(t)), t)
        let partial = #"{"format":"jpeg","quality":0.9,"keepMetadata":true,"suffix":"","collision":"number","nameTemplate":{"pattern":"{seq}"}}"#
        let p = try JSONDecoder().decode(ExportOptions.self, from: Data(partial.utf8))
        XCTAssertEqual(p.nameTemplate, RenameTemplate(pattern: "{seq}", start: 1))
    }

    func testTheFormResolvesTheNameChoiceAndPreviewsTwoNames() {
        let items = (1...3).map {
            ExportQueue.Item(source: URL(fileURLWithPath: "/p/IMG_\($0).png"), recipe: .neutral, captureDate: march14)
        }
        var form = ExportForm(options: ExportOptions())
        XCTAssertEqual(form.nameMode, .suffix)
        form.options.suffix = "-e"
        XCTAssertNil(form.resolved.nameTemplate)
        XCTAssertEqual(form.previewNames(for: items), ["IMG_1-e.jpg", "IMG_2-e.jpg"])

        form.nameMode = .template
        form.template = RenameTemplate(pattern: "{date}_{seq}", start: 9)
        XCTAssertEqual(form.resolved.nameTemplate, RenameTemplate(pattern: "{date}_{seq}", start: 9))
        XCTAssertEqual(form.previewNames(for: items), ["2026-03-14_09.jpg", "2026-03-14_10.jpg"],
                       "padded for the whole batch (9…11), suffix not used")

        // Back to the suffix: the template is dropped from the options, and
        // a form made from options with a template opens on Template.
        let withTemplate = form.resolved
        form.nameMode = .suffix
        XCTAssertNil(form.resolved.nameTemplate)
        XCTAssertEqual(ExportForm(options: withTemplate).nameMode, .template)
    }

    // MARK: A real run

    func testAThreePhotoExportWritesTheTemplatedNamesInOrder() async throws {
        for name in ["c.png", "a.png", "b.png"] { try writePNG(name) }
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.selectAll()
        let targets = lib.batchTargets
        XCTAssertEqual(targets.count, 3)
        let items = try await lib.exportItems(for: targets)
        XCTAssertTrue(items.allSatisfy { $0.captureDate != nil }, "a file's capture date comes from CaptureDates")

        var o = ExportOptions()
        o.suffix = "-ignored"
        o.nameTemplate = RenameTemplate(pattern: "trip-{seq}-{name}", start: 1)
        let queue = ExportQueue()
        queue.start(items, into: outDir, options: o)
        await queue.wait()
        XCTAssertEqual(queue.state, .finished)
        XCTAssertEqual(queue.done, 3)
        let stems = targets.map { $0.fileURL!.deletingPathExtension().lastPathComponent }
        let expected = stems.enumerated().map { "trip-\($0.offset + 1)-\($0.element).jpg" }
        XCTAssertEqual(queue.exported.map(\.lastPathComponent), expected, "numbered in batchTargets order")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: outDir.path)), Set(expected))

        // {date} from the photo's capture date; the templated name meets
        // the collision policy as a plain name does.
        o.nameTemplate = RenameTemplate(pattern: "{date}")
        queue.dismiss()
        queue.start(Array(items.prefix(2)), into: outDir, options: o)
        await queue.wait()
        let day = RenameTemplate.dateString(try XCTUnwrap(items[0].captureDate))
        XCTAssertEqual(queue.exported.map(\.lastPathComponent).first, "\(day).jpg")
        if RenameTemplate.dateString(try XCTUnwrap(items[1].captureDate)) == day {
            XCTAssertEqual(queue.exported.map(\.lastPathComponent), ["\(day).jpg", "\(day) 2.jpg"], "Add a number")
        }

        // The originals are untouched.
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }),
                       ["a.png", "b.png", "c.png"])
    }
}
