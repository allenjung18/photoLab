import Foundation
import AppKit
import CoreImage
import ImageIO
import Observation
import UniformTypeIdentifiers

// MARK: - Sync mask

/// Which adjustments a batch operation carries from the source onto each
/// target photo. A kind outside the mask keeps the target's own value, so
/// "sync only the grade" leaves every photo its exposure and its crop.
struct SyncMask: Hashable {
    var kinds: Set<AdjustmentKind>

    /// Every kind except rotate and crop: the look travels, the framing does
    /// not (what applying a preset does).
    static let look = SyncMask(kinds: Set(AdjustmentKind.allCases).subtracting(AdjustmentKind.geometryKinds))
    /// The look without exposure: each photo keeps its own brightness.
    static let grade = SyncMask(kinds: look.kinds.subtracting([.exposure]))
    static let everything = SyncMask(kinds: Set(AdjustmentKind.allCases))
    static let nothing = SyncMask(kinds: [])

    func contains(_ kind: AdjustmentKind) -> Bool { kinds.contains(kind) }

    mutating func set(_ kind: AdjustmentKind, _ on: Bool) {
        if on { kinds.insert(kind) } else { kinds.remove(kind) }
    }

    mutating func set(_ list: [AdjustmentKind], _ on: Bool) {
        for kind in list { set(kind, on) }
    }

    /// True when every kind of `list` is in the mask, false when none is,
    /// nil when some are.
    func state(of list: [AdjustmentKind]) -> Bool? {
        let n = list.filter(contains).count
        return n == list.count ? true : (n == 0 ? false : nil)
    }
}

extension Recipe {
    /// `self` with every kind in `mask` taken from `source` (value and
    /// enabled flag alike); the other kinds are kept. The result is in
    /// canonical form (`normalized`).
    func syncing(_ mask: SyncMask, from source: Recipe) -> Recipe {
        var out = normalized
        for kind in AdjustmentKind.allCases where mask.contains(kind) { out[kind] = source[kind] }
        return out
    }
}

// MARK: - Export

/// One photo rendered at full size through the one `Renderer` and written as
/// a JPEG into an output folder. Default quality, no resize, no metadata:
/// chunk 7 adds those. The original is read, never written.
enum Exporter {
    enum Failure: LocalizedError {
        case cannotDecode(URL)
        case cannotRender(URL)
        case cannotWrite(URL)

        var errorDescription: String? {
            switch self {
            case .cannotDecode(let u): return "Could not decode \(u.lastPathComponent)."
            case .cannotRender(let u): return "Could not render \(u.lastPathComponent)."
            case .cannotWrite(let u): return "Could not write \(u.lastPathComponent)."
            }
        }
    }

    static let fileExtension = "jpg"

    /// `<folder>/<stem>.jpg`; when that name is taken (another export, or
    /// the original itself when exporting into its own folder) the next free
    /// `<stem> 2.jpg`, `<stem> 3.jpg`, … so nothing is ever overwritten.
    static func destination(for source: URL, in folder: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = n == 1 ? stem : "\(stem) \(n)"
            let url = folder.appendingPathComponent(name, isDirectory: false).appendingPathExtension(fileExtension)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    /// Renders `recipe` over the full-resolution decode of `source` and
    /// writes the JPEG. Synchronous; call off the main thread. Returns the
    /// file written.
    @discardableResult
    static func export(_ source: URL, recipe: Recipe, into folder: URL, renderer: Renderer = .shared) throws -> URL {
        guard let image = Renderer.fullResolution(source) else { throw Failure.cannotDecode(source) }
        guard let result = renderer.render(image, recipe: recipe) else { throw Failure.cannotRender(source) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = destination(for: source, in: folder)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.cannotWrite(out)
        }
        CGImageDestinationAddImage(dest, result.image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.cannotWrite(out) }
        return out
    }
}

/// The export queue: a list of (photo, recipe) pairs written one after the
/// other into one folder, with progress the window shows and a Cancel that
/// stops after the file in flight. One queue per app; a run cannot start
/// while another is going.
@MainActor
@Observable
final class ExportQueue {
    struct Item: Identifiable {
        let id = UUID()
        let source: URL
        let recipe: Recipe
    }

    struct Failure: Identifiable {
        let id = UUID()
        let source: URL
        let message: String
    }

    enum State: Equatable { case idle, running, finished, cancelled }

    /// Exports one item into the folder and returns the file written; the
    /// default is `Exporter.export`. Injected so a test can time or count
    /// jobs without rendering.
    typealias Worker = @Sendable (URL, Recipe, URL) throws -> URL

    private(set) var state: State = .idle
    private(set) var total = 0
    /// Files written so far in this run.
    private(set) var done = 0
    private(set) var failures: [Failure] = []
    private(set) var exported: [URL] = []
    /// The photo being written right now.
    private(set) var current: URL?
    private(set) var folder: URL?

    private var task: Task<Void, Never>?
    private let worker: Worker

    init(worker: @escaping Worker = { try Exporter.export($0, recipe: $1, into: $2) }) {
        self.worker = worker
    }

    var isRunning: Bool { state == .running }
    /// Items finished, written or failed.
    var completed: Int { done + failures.count }

    /// Starts writing `items` into `folder`. Ignored while a run is going.
    func start(_ items: [Item], into folder: URL) {
        guard !isRunning, !items.isEmpty else { return }
        state = .running
        total = items.count
        done = 0
        failures = []
        exported = []
        current = nil
        self.folder = folder
        let worker = self.worker
        task = Task { [weak self] in
            for item in items {
                if Task.isCancelled { break }
                self?.current = item.source
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                    Result { try worker(item.source, item.recipe, folder) }
                }.value
                guard let self else { return }
                switch outcome {
                case .success(let url):
                    self.done += 1
                    self.exported.append(url)
                case .failure(let error):
                    self.failures.append(Failure(source: item.source, message: error.localizedDescription))
                }
            }
            guard let self else { return }
            self.current = nil
            self.state = Task.isCancelled ? .cancelled : .finished
        }
    }

    /// Stops the run after the file in flight; what is written stays.
    func cancel() {
        guard isRunning else { return }
        task?.cancel()
    }

    /// Clears a finished or cancelled run from the window.
    func dismiss() {
        guard !isRunning else { return }
        state = .idle
    }

    /// Returns when the run has ended (tests).
    func wait() async {
        await task?.value
    }
}

/// The folder picker behind Export.
@MainActor
enum ExportPanel {
    static func chooseFolder(count: Int) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = count == 1 ? "Choose a folder for the JPEG" : "Choose a folder for \(count) JPEGs"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
