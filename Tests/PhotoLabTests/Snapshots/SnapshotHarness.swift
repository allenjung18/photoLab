import XCTest
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// An in-process snapshot harness: a SwiftUI view hosted in an `NSWindow`
/// that is NEVER put on screen (no `orderFront`, no activation, no screen
/// capture), the run loop spun until the view's tasks have landed, the
/// window's frame view drawn into a bitmap (`cacheDisplay`) and written as a
/// PNG. Light and dark through the window's appearance and the color scheme.
///
/// The tests that use it skip unless `PHOTOLAB_SNAPSHOTS=<output dir>` is
/// set, so `swift test` writes nothing and stays as fast as before; the
/// output directory is the caller's, never defaulted, and is not in the repo.
@MainActor
final class SnapshotHarness {
    static let environmentKey = "PHOTOLAB_SNAPSHOTS"

    enum Mode: String, CaseIterable {
        case light, dark
        var appearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
        var scheme: ColorScheme { self == .light ? .light : .dark }
    }

    /// A `Shot.size` that means "the view's own fitting size" (a sheet).
    static let fitting = CGSize(width: -1, height: -1)

    struct Shot {
        let number: String
        let name: String
        let what: String
        let model: String
        let caveat: String
        let size: CGSize
        var file: String { "\(number)-\(name).png" }
    }

    /// What a state needs hosted: the view, its environment objects, and when
    /// it is ready to be drawn.
    @MainActor struct Scene {
        let library: Library
        var presets: PresetLibrary
        var exports: ExportQueue
        var view: AnyView?
        /// The state is complete: its model is ready and its tasks have landed.
        var ready: @MainActor () -> Bool = { true }
        /// The canvas (everything left of the 280 pt panel) must show a photo.
        var needsCanvas = false
        var panelStart: PanelStart?
        /// Overrides the process's `hasBundle` (nil: the real value).
        var hasBundle: Bool?
        var cleanup: () -> Void = {}

        init(presets: PresetLibrary, exports: ExportQueue) {
            self.library = Library(rememberFolder: false)
            self.presets = presets
            self.exports = exports
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let out: URL
    private(set) var written: [Shot] = []
    private(set) var failures: [String] = []
    private var lines: [String] = []

    /// The output directory, or an `XCTSkip` when it is not set.
    static func requireOutput() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else {
            throw XCTSkip("\(environmentKey)=<output dir> is not set: no snapshots are taken")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    init(out: URL) throws {
        self.out = out
        for mode in Mode.allCases {
            try FileManager.default.createDirectory(at: out.appendingPathComponent(mode.rawValue, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
    }

    // MARK: Hosting and capture

    /// Takes one state in both modes. `build` makes a fresh scene each time,
    /// so a mode never sees the other's edits. A failed state is recorded and
    /// does not stop the rest.
    func shoot(_ shot: Shot, deadline: TimeInterval = 45, build: () async throws -> Scene) async {
        for mode in Mode.allCases {
            do {
                let scene = try await build()
                defer { scene.cleanup() }
                let png = try await capture(shot, mode: mode, scene: scene, deadline: deadline)
                try png.write(to: out.appendingPathComponent(mode.rawValue).appendingPathComponent(shot.file))
            } catch {
                failures.append("\(mode.rawValue)/\(shot.file): \(error)")
            }
        }
        written.append(shot)
        lines.append("\(shot.file) | \(shot.what) | model: \(shot.model)" + (shot.caveat.isEmpty ? "" : " | offscreen: \(shot.caveat)"))
    }

    private func capture(_ shot: Shot, mode: Mode, scene: Scene, deadline: TimeInterval) async throws -> Data {
        let root = (scene.view ?? AnyView(ContentView()))
            .environment(scene.library)
            .environment(scene.presets)
            .environment(scene.exports)
            .environment(\.colorScheme, mode.scheme)
            .environment(\.panelStart, scene.panelStart)
            .environment(\.hasBundle, scene.hasBundle ?? PhotosAccess.hasBundle)
        let host = NSHostingController(rootView: root)
        host.sceneBridgingOptions = .all
        // The window keeps the size the shot asks for; a hosting controller
        // would otherwise shrink it to the content's ideal size (an empty
        // folder came out about 220 pt wide).
        if shot.size != Self.fitting { host.sizingOptions = [] }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: shot.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = mode.appearance
        window.contentViewController = host
        window.setContentSize(shot.size)
        if shot.size == Self.fitting {
            // A sheet shown as its own root: the size it asks for.
            window.setContentSize(CGSize(width: 800, height: 600))
            window.layoutIfNeeded()
            let fit = host.view.fittingSize
            window.setContentSize(CGSize(width: max(fit.width, 200), height: max(fit.height, 100)))
        }
        // Never ordered on screen: the window is drawn from its own view tree.
        defer { window.contentViewController = nil; window.close() }

        let start = Date()
        var previous: Data?
        var stable = 0
        while true {
            if Date().timeIntervalSince(start) > deadline {
                throw Failure(description: "timed out after \(Int(deadline)) s waiting for \(shot.name) to settle (ready=\(scene.ready()))")
            }
            await settle(0.25)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let png = try draw(window)
            let elapsed = Date().timeIntervalSince(start)
            if ProcessInfo.processInfo.environment["PHOTOLAB_SNAPSHOT_TRACE"] != nil { print("TRACE \(shot.name) \(mode.rawValue) t=\(String(format: "%.1f", elapsed)) ready=\(scene.ready()) stable=\(stable) same=\(previous == png) bytes=\(png.count)") }
            if scene.ready(), elapsed > 0.8 {
                stable = previous == png ? stable + 1 : 0
                if stable >= 3 {
                    let stats = try Self.stats(png, canvasOnly: scene.needsCanvas)
                    if stats.isFlat {
                        if elapsed > deadline - 1 { throw Failure(description: "\(shot.name) is flat (\(stats))") }
                        stable = 0
                    } else {
                        return png
                    }
                }
            }
            previous = png
        }
    }

    /// Lets the main actor and the main run loop work for `seconds`. The sleep
    /// is an `await`, which is what frees the main actor for the views' tasks
    /// (a blocking run-loop spin alone never resumes them); the short spin
    /// after it services display and layout.
    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        Self.spin()
    }

    private static func spin() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }

    /// The window's frame view (titlebar and toolbar included, when they
    /// draw) into a 2x bitmap, as PNG data.
    private func draw(_ window: NSWindow) throws -> Data {
        guard let frame = window.contentView?.superview else { throw Failure(description: "the window has no frame view") }
        let bounds = frame.bounds
        let scale = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width) * scale,
                                         pixelsHigh: Int(bounds.height) * scale, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw Failure(description: "no bitmap") }
        rep.size = bounds.size
        frame.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "no PNG") }
        return png
    }

    /// Decoded stats over the bitmap (or its canvas: the left part, minus the
    /// 280 pt panel and the title area).
    struct Stats: CustomStringConvertible {
        var deviation: Double
        var distinct: Int
        var width: Int
        var height: Int
        var isFlat: Bool { deviation < 3 || distinct < 16 }
        var description: String { String(format: "%dx%d luma deviation %.1f, %d distinct colors", width, height, deviation, distinct) }
    }

    static func stats(_ png: Data, canvasOnly: Bool = false) throws -> Stats {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Failure(description: "unreadable PNG") }
        var rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if canvasOnly {
            // 2x pixels: the canvas is left of the 280 pt panel; keep clear of
            // the title and toolbar (top 160 px) and a footer strip.
            rect = CGRect(x: 40, y: 200, width: image.width - 2 * 280 - 80, height: image.height - 400)
        }
        guard let crop = image.cropping(to: rect),
              let ctx = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure(description: "cannot decode") }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        guard let data = ctx.data else { throw Failure(description: "no pixels") }
        let p = data.bindMemory(to: UInt8.self, capacity: crop.width * crop.height * 4)
        var sum = 0.0, sumSq = 0.0, n = 0.0
        var colors = Set<UInt32>()
        let step = 3
        var y = 0
        while y < crop.height {
            var x = 0
            while x < crop.width {
                let i = (y * crop.width + x) * 4
                let l = 0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2])
                sum += l; sumSq += l * l; n += 1
                if colors.count < 64 { colors.insert(UInt32(p[i] >> 3) << 10 | UInt32(p[i + 1] >> 3) << 5 | UInt32(p[i + 2] >> 3)) }
                x += step
            }
            y += step
        }
        let mean = sum / n
        return Stats(deviation: (max(0, sumSq / n - mean * mean)).squareRoot(), distinct: colors.count, width: image.width, height: image.height)
    }

    // MARK: Index

    /// Writes `index.txt`: one line per state, then the harness-wide notes.
    func writeIndex(notes: [String], file: String = "index.txt") throws {
        var text = "# One line per state: file | what it shows | model state set | offscreen caveat\n"
        text += "# Each file exists in light/ and dark/. Taken by an in-process harness: no window was ever on screen.\n\n"
        text += lines.joined(separator: "\n") + "\n\n# Offscreen notes\n"
        text += notes.map { "- " + $0 }.joined(separator: "\n") + "\n"
        if !failures.isEmpty { text += "\n# FAILED\n" + failures.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        try text.write(to: out.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }
}

// MARK: - Fixtures

/// A temp folder of synthetic photos for one state.
struct SnapshotFixture {
    let base: URL
    let folder: URL
    let presetDirectory: URL
    let stagingDirectory: URL

    static let longName = "Family reunion at the lake house, July 2026 - final selects v3.jpg"
    /// Grid order (natural): the 12 JPEGs, the PNG, then the junk file when present.
    static let jpegs = ["IMG_0001.jpg", "IMG_0002.jpg", "IMG_0003.jpg", "IMG_0004.jpg", "IMG_0005.jpg", "IMG_0006.jpg",
                        "IMG_0007.jpg", "IMG_0008.jpg", "IMG_0009.jpg", "IMG_0010.jpg", longName, "sunset.jpg"]
    static let portraits: Set<String> = ["IMG_0003.jpg", "IMG_0008.jpg"]
    static let png = "scan-0012.png"
    static let junk = "broken.JPG"
    /// A photo big enough for the loupe's 1:1 zoom (the others are too small to zoom).
    static let big = "IMG_0000-big.jpg"

    /// `junk`: also a `.JPG` of junk bytes (a decode failure).
    init(junk: Bool = false, big: Bool = false) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-snap-\(UUID().uuidString)", isDirectory: true)
        folder = base.appendingPathComponent("Lake trip 2026", isDirectory: true)
        presetDirectory = base.appendingPathComponent("presets", isDirectory: true)
        stagingDirectory = base.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sizes = [(480, 320), (480, 360), (640, 360), (480, 320)]
        for (i, name) in Self.jpegs.enumerated() {
            let (w, h) = sizes[i % sizes.count]
            let portrait = Self.portraits.contains(name)
            try Self.write(folder.appendingPathComponent(name), width: portrait ? h : w, height: portrait ? w : h, type: UTType.jpeg)
        }
        try Self.write(folder.appendingPathComponent(Self.png), width: 400, height: 300, type: UTType.png)
        if big { try Self.write(folder.appendingPathComponent(Self.big), width: 3200, height: 2000, type: UTType.jpeg) }
        if junk { try Data("this is not an image".utf8).write(to: folder.appendingPathComponent(Self.junk)) }
    }

    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: base)
    }

    static func write(_ url: URL, width: Int, height: Int, type: UTType) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw SnapshotHarness.Failure(description: "cannot write \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, syntheticImage(width: width, height: height), nil)
        guard CGImageDestinationFinalize(dest) else { throw SnapshotHarness.Failure(description: "cannot finalize \(url.lastPathComponent)") }
    }
}
