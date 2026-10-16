import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Local adjustments, the data model (Masks.swift, `Recipe.masks`): masks
/// survive the sidecar and Photos adjustment data, the file is stamped with
/// the lowest version that holds it, presets and the look / grade syncs keep
/// the target's masks, and a mask edit is an ordinary recipe step (one undo
/// step, one sidecar write) with no undo path of its own.
@MainActor
final class MaskModelTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-masks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fixtures

    private let fixed = Date(timeIntervalSince1970: 1_800_000_000)

    private func linear(exposure: Double = 1) -> LocalMask {
        var m = LocalMask(shape: .linear(start: MaskPoint(x: 0.5, y: 0), end: MaskPoint(x: 0.5, y: 0.5)))
        m.set(.exposure, to: exposure)
        return m
    }

    private func radial() -> LocalMask {
        var m = LocalMask(shape: .radial(center: MaskPoint(x: 0.4, y: 0.6), radii: MaskRadii(x: 0.2, y: 0.1),
                                         angle: 30, feather: 0.5),
                          inverted: true)
        m.set(.temperature, to: -20)
        m.set(.saturation, to: 15)
        return m
    }

    private func brush() -> LocalMask {
        let paint = BrushStroke(points: [MaskPoint(x: 0.1, y: 0.1), MaskPoint(x: 0.3, y: 0.2)],
                                radius: 0.05, feather: 0.4, flow: 0.8)
        let erase = BrushStroke(points: [MaskPoint(x: 0.2, y: 0.15)], radius: 0.02, feather: 0, flow: 1, erase: true)
        var m = LocalMask(shape: .brush([paint, erase]), enabled: false)
        m.set(.shadows, to: 30)
        m.set(.contrast, to: -10)
        return m
    }

    /// The neutral recipe with one mask of each shape and no slider edit, so
    /// the masks are the only thing that makes it an edit at all.
    private lazy var masksOnly: Recipe = {
        var r = Recipe.neutral
        r.masks = [linear(), radial(), brush()]
        return r
    }()

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

    private func json(_ file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    // MARK: Sidecar

    func testASidecarRoundTripsOneMaskOfEachShape() throws {
        let store = SidecarStore(folder: folder)
        let photo = folder.appendingPathComponent("a.png")
        try store.save(masksOnly, for: photo, now: fixed)
        let read = try XCTUnwrap(try store.load(for: photo), "a masks-only recipe is an edit: its sidecar is kept")
        XCTAssertEqual(read, masksOnly, "equal after save and read")
        XCTAssertEqual(read.normalized, masksOnly.normalized)
        XCTAssertEqual(read.normalized.masks.map(\.id), masksOnly.masks.map(\.id), "masks kept, in order")
        XCTAssertFalse(read.isDefault)

        // The file reads plainly: each shape a `type` and its fields.
        let recipe = try XCTUnwrap(try json(store.url(for: photo))["recipe"] as? [String: Any])
        let masks = try XCTUnwrap(recipe["masks"] as? [[String: Any]])
        XCTAssertEqual(masks.compactMap { ($0["shape"] as? [String: Any])?["type"] as? String },
                       ["linear", "radial", "brush"])

        // Sliders and masks together round-trip too.
        var both = masksOnly
        both.set(.exposure, to: -0.7)
        try store.save(both, for: photo, now: fixed)
        XCTAssertEqual(try store.load(for: photo), both)
    }

    func testAVersion1SidecarDecodesWithNoMasks() throws {
        let v1 = """
        {
          "original" : "a.png",
          "recipe" : {
            "adjustments" : [
              { "enabled" : true, "kind" : "exposure", "value" : 0.5 }
            ]
          },
          "updated" : "2026-10-16T00:00:00Z",
          "version" : 1
        }
        """
        let doc = try SidecarStore.decode(Data(v1.utf8))
        XCTAssertEqual(doc.version, 1)
        XCTAssertEqual(doc.recipe.masks, [])
        XCTAssertEqual(doc.recipe.value(of: .exposure), 0.5)
    }

    /// The old (pre-mask) sidecar type, field for field, encoded the way
    /// `SidecarStore.encode` encodes: what a build before masks wrote.
    private struct OldRecipe: Codable { var adjustments: [Adjustment] }
    private struct OldSidecar: Codable {
        var version = 1
        var original: String
        var updated: Date
        var recipe: OldRecipe
        var flag: Marks.Flag?
        var rating: Int?
    }

    func testAnUnmaskedSaveWritesVersion1ByteIdenticalAndAMaskedOneVersion2() throws {
        let store = SidecarStore(folder: folder)
        let photo = folder.appendingPathComponent("a.png")
        var r = Recipe.neutral
        r.set(.exposure, to: 0.5)
        try store.save(r, marks: Marks(flag: .pick, rating: 3), for: .file(photo), name: "a.png", now: fixed)
        let file = store.url(for: photo)
        XCTAssertEqual(try json(file)["version"] as? Int, 1)
        XCTAssertNil((try json(file)["recipe"] as? [String: Any])?["masks"], "no masks key when there are none")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let old = OldSidecar(original: "a.png", updated: fixed, recipe: OldRecipe(adjustments: r.adjustments),
                             flag: .pick, rating: 3)
        XCTAssertEqual(try Data(contentsOf: file), try encoder.encode(old), "byte-identical to a pre-mask build's file")

        r.masks = [linear()]
        try store.save(r, for: photo, now: fixed)
        XCTAssertEqual(try json(file)["version"] as? Int, 2)
        XCTAssertEqual(try store.read(for: photo)?.version, 2)
        XCTAssertEqual(try store.read(for: photo)?.marks, Marks(flag: .pick, rating: 3), "marks kept")

        // Dropping the last mask writes version 1 again.
        r.masks = []
        try store.save(r, for: photo, now: fixed)
        XCTAssertEqual(try json(file)["version"] as? Int, 1)
        XCTAssertEqual(Sidecar.version(for: r), 1)
        XCTAssertEqual(Sidecar.version(for: masksOnly), 2)
        XCTAssertEqual(Sidecar.currentVersion, 3)
    }

    func testAVersion4FileIsUnreadable() throws {
        let store = SidecarStore(folder: folder)
        let photo = folder.appendingPathComponent("a.png")
        try store.save(masksOnly, for: photo, now: fixed)
        let file = store.url(for: photo)
        var obj = try json(file)
        obj["version"] = 4
        try JSONSerialization.data(withJSONObject: obj).write(to: file)
        XCTAssertThrowsError(try store.read(for: photo)) { error in
            XCTAssertEqual(error as? SidecarError, .unsupportedVersion(4))
        }
        XCTAssertEqual(store.loadAll(for: [.file(photo)]).unreadable, [.file(photo)])
    }

    // MARK: Photos adjustment data

    func testPhotosAdjustmentDataFollowsTheSameVersionRule() throws {
        var plain = Recipe.neutral
        plain.set(.contrast, to: 12)
        let unmasked = try PhotosAdjustment(recipe: plain, name: "IMG_0001.HEIC", now: fixed)
        XCTAssertEqual(unmasked.formatVersion, "1")
        XCTAssertEqual(try SidecarStore.decode(unmasked.data).version, 1)
        XCTAssertEqual(try unmasked.recipe(), plain)

        let masked = try PhotosAdjustment(recipe: masksOnly, name: "IMG_0001.HEIC", now: fixed)
        XCTAssertEqual(masked.formatVersion, "2")
        XCTAssertEqual(try SidecarStore.decode(masked.data).version, 2)
        XCTAssertEqual(try masked.recipe(), masksOnly)

        XCTAssertTrue(PhotosAdjustment.canHandle(identifier: PhotosAdjustment.formatIdentifier, version: "2"))
        XCTAssertFalse(PhotosAdjustment.canHandle(identifier: PhotosAdjustment.formatIdentifier, version: "4"))
    }

    // MARK: Recipe identity

    func testNormalizedIsDefaultAndIsNeutralAccountForMasks() {
        XCTAssertEqual(masksOnly.normalized.masks.count, 3, "normalized keeps the masks")
        XCTAssertFalse(masksOnly.isDefault, "a mask is an edit")
        XCTAssertFalse(masksOnly.isNeutral, "an enabled mask with a non-neutral slider renders")
        XCTAssertNotEqual(masksOnly, .neutral)

        // A disabled mask, or one whose every slider is neutral, renders as
        // identity but is still an edit.
        var off = Recipe.neutral
        var m = linear()
        m.enabled = false
        off.masks = [m]
        XCTAssertTrue(off.isNeutral)
        XCTAssertFalse(off.isDefault)
        var flat = Recipe.neutral
        flat.masks = [LocalMask(shape: .linear(start: MaskPoint(x: 0, y: 0), end: MaskPoint(x: 1, y: 1)))]
        XCTAssertTrue(flat.isNeutral)
        XCTAssertFalse(flat.isDefault)
        flat.masks[0].inverted = true
        XCTAssertTrue(flat.isNeutral, "inverting a no-op mask is still a no-op")

        // A mask's adjustments in any order normalize to the same mask.
        var a = linear()
        a.set(.tint, to: 5)
        var b = a
        b.adjustments.reverse()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.normalized, b.normalized)
        XCTAssertEqual(a.normalized.adjustments.map(\.kind), LocalMask.kinds)
    }

    func testAMaskCarriesOnlyItsSevenKinds() throws {
        XCTAssertEqual(Set(LocalMask.kinds),
                       [.exposure, .contrast, .highlights, .shadows, .temperature, .tint, .saturation])
        var m = LocalMask(shape: .brush([]), adjustments: [Adjustment(kind: .cropLeft, value: 20),
                                                           Adjustment(kind: .exposure, value: 1)])
        XCTAssertEqual(m.adjustments.map(\.kind), [.exposure], "init drops kinds outside the list")
        m.set(.hueRed, to: 50)
        XCTAssertEqual(m.adjustments.map(\.kind), [.exposure], "setting a foreign kind is ignored")
        let file = """
        {"id":"\(UUID().uuidString)","shape":{"type":"brush","strokes":[]},
         "adjustments":[{"kind":"vignette","value":-40,"enabled":true},{"kind":"tint","value":5,"enabled":true}]}
        """
        let decoded = try JSONDecoder().decode(LocalMask.self, from: Data(file.utf8))
        XCTAssertEqual(decoded.adjustments.map(\.kind), [.tint], "a file cannot smuggle a foreign kind in")
        XCTAssertTrue(decoded.enabled, "enabled defaults on")
        XCTAssertFalse(decoded.inverted, "inverted defaults off")
    }

    // MARK: Presets and sync

    func testPresetsNeverCarryMasksAndApplyingOneKeepsTheTargets() throws {
        var source = masksOnly
        source.set(.saturation, to: -30)
        let preset = Preset(name: "Muted", from: source, updated: fixed)
        XCTAssertEqual(preset.recipe.masks, [], "a preset drops the masks")

        var target = Recipe.neutral
        target.masks = [radial()]
        let applied = preset.apply(to: target)
        XCTAssertEqual(applied.value(of: .saturation), -30, "the look travels")
        XCTAssertEqual(applied.masks, target.normalized.masks, "the target keeps its own masks")
        XCTAssertTrue(preset.matches(applied))
        XCTAssertEqual(preset.apply(to: .neutral).masks, [], "a target with none gets none")

        // Through the file: the saved preset has no masks key and reads back equal.
        let dir = folder.appendingPathComponent("presets", isDirectory: true)
        let presets = PresetLibrary(store: PresetStore(directory: dir))
        let saved = try XCTUnwrap(presets.save(source, as: "Muted"))
        XCTAssertEqual(saved.recipe.masks, [])
        let raw = try json(PresetStore(directory: dir).url(for: "Muted"))
        XCTAssertNil((raw["recipe"] as? [String: Any])?["masks"])
        XCTAssertEqual(try PresetStore(directory: dir).load("Muted"), saved)
    }

    func testLookAndGradeSyncKeepTheTargetsMasksAndEverythingCopiesThem() {
        var source = Recipe.neutral
        source.set(.contrast, to: 25)
        source.masks = [linear(), brush()]
        var target = Recipe.neutral
        target.set(.exposure, to: 0.3)
        target.masks = [radial()]

        for mask in [SyncMask.look, .grade] {
            let out = target.syncing(mask, from: source)
            XCTAssertEqual(out.value(of: .contrast), 25)
            XCTAssertEqual(out.masks, target.normalized.masks, "the target keeps its masks")
        }
        let all = target.syncing(.everything, from: source)
        XCTAssertEqual(all.masks, source.normalized.masks, "All copies the masks")
        XCTAssertEqual(all, source.normalized)
        XCTAssertFalse(SyncMask.look.masks)
        XCTAssertFalse(SyncMask.grade.masks)
        XCTAssertFalse(SyncMask.nothing.masks)
        XCTAssertFalse(AutoTone.mask.masks, "Auto never touches masks")
        XCTAssertTrue(SyncMask.everything.masks)
    }

    func testLibraryPresetApplyAndSyncFollowTheSameRules() throws {
        try makePhoto("a.png"); try makePhoto("b.png")
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let a = lib.photos[0].id, b = lib.photos[1].id
        lib.setRecipe(masksOnly, for: a)
        var withRadial = Recipe.neutral
        withRadial.masks = [radial()]
        lib.setRecipe(withRadial, for: b)

        let preset = Preset(name: "Warm", from: { var r = Recipe.neutral; r.set(.temperature, to: 20); return r }())
        lib.apply(preset, to: b)
        XCTAssertEqual(lib.recipe(for: b).masks, withRadial.normalized.masks, "a preset keeps b's masks")
        XCTAssertEqual(lib.recipe(for: b).value(of: .temperature), 20)
        XCTAssertEqual(lib.apply(preset, mask: .everything, to: [b]), 0,
                       "a batch preset apply never carries masks, even under All")
        XCTAssertEqual(lib.recipe(for: b).masks, withRadial.normalized.masks)

        lib.sync(lib.recipe(for: a), mask: .look, to: [b])
        XCTAssertEqual(lib.recipe(for: b).masks, withRadial.normalized.masks, "look keeps b's masks")
        lib.sync(lib.recipe(for: a), mask: .everything, to: [b])
        XCTAssertEqual(lib.recipe(for: b).masks, masksOnly.normalized.masks, "All copies a's masks")
        XCTAssertEqual(try store.load(for: b)?.normalized.masks, masksOnly.normalized.masks, "and writes them")
    }

    // MARK: Undo: a mask edit is an ordinary recipe step

    func testAddingAMaskIsOneUndoStepAndOneSidecarWrite() throws {
        try makePhoto("a.png")
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let id = try XCTUnwrap(lib.photos.first).id
        lib.selection = id
        var before = Recipe.neutral
        before.set(.exposure, to: 0.4)
        lib.setRecipe(before, for: id)
        let file = store.url(for: id)
        XCTAssertEqual(try json(file)["version"] as? Int, 1)

        var added = before
        added.masks = [linear()]
        lib.setRecipe(added, for: id)
        XCTAssertEqual(try store.load(for: id), added, "written at once")
        XCTAssertEqual(try json(file)["version"] as? Int, 2)

        // A slider drag on the mask: nothing is written until mouse-up, and
        // the drag is one step.
        lib.beginEdit(id)
        var dragged = added
        for v in stride(from: 1.2, through: 2.0, by: 0.2) {
            dragged.masks[0].set(.exposure, to: v)
            lib.setRecipe(dragged, for: id)
            XCTAssertEqual(try store.load(for: id), added, "no write mid-drag")
        }
        lib.endEdit(id)
        XCTAssertEqual(try store.load(for: id), dragged, "one write at mouse-up")

        lib.undo()
        XCTAssertEqual(lib.recipe(for: id), added, "the drag was one step")
        lib.undo()
        XCTAssertEqual(lib.recipe(for: id), before, "adding the mask was one step")
        XCTAssertEqual(try store.load(for: id), before)
        XCTAssertEqual(try json(file)["version"] as? Int, 1, "back to a version-1 file")
        lib.redo()
        XCTAssertEqual(lib.recipe(for: id), added)
        XCTAssertEqual(try store.load(for: id), added)

        // Reopening reads the masks back.
        let again = Library(rememberFolder: false)
        again.open(folder)
        XCTAssertEqual(again.recipe(for: id), added)
        XCTAssertTrue(again.isEdited(id))
    }
}
