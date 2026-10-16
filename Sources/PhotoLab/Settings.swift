import Foundation
import Observation

/// How the loupe's fit frame is rendered: at every screen pixel of the
/// canvas, or at a fraction of them (`scale`) and drawn scaled up, which
/// renders fewer pixels per slider step. The 1:1 window is never scaled (it
/// is one image pixel per screen pixel), and neither is an export.
enum PreviewQuality: String, CaseIterable, Identifiable, Sendable {
    case full, balanced, fast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "Full"
        case .balanced: return "Balanced"
        case .fast: return "Fast"
        }
    }

    /// The share of the canvas's pixels on each side the frame is rendered at.
    var scale: Double {
        switch self {
        case .full: return 1
        case .balanced: return 0.75
        case .fast: return 0.5
        }
    }

    /// The frame's longest side for a canvas whose longest side is
    /// `longestSide` pixels (never below 1).
    func pixelSize(_ longestSide: Int) -> Int {
        max(1, Int((Double(longestSide) * scale).rounded()))
    }
}

/// The last source, as the Library remembers it for the launch reopen.
enum LastSource: Equatable, Sendable {
    /// A folder by path (`lastFolder`, the key every earlier build wrote).
    case folder(path: String)
    /// A Photos album by its identifier (`lastPhotosAlbum`).
    case photos(albumID: String)
}

/// Every value PhotoLab keeps between launches, over one injected
/// `UserDefaults`: the Settings window's choices (grid thumbnail size,
/// preview quality, reopen the last source, the sort per source kind), the
/// view toggles (filmstrip, Info, History), the last source and Open Recent, and the
/// export sheet's last choices. The key strings are the ones earlier builds
/// wrote (`Key`), so a saved value is read back as it was.
///
/// `persistent: false` (tests, a `Library(rememberFolder: false)`) reads
/// nothing and writes nothing: the values live in memory at their defaults.
/// The app makes one instance (`PhotoLabApp`) and hands it to the `Library`
/// and the `ExportQueue`; the Settings window edits it through the library.
@MainActor
@Observable
final class AppSettings {
    /// The UserDefaults keys, one place. Earlier builds' keys are unchanged.
    enum Key {
        static let gridThumbnailSize = "gridThumbnailSize"
        static let previewQuality = "previewQuality"
        static let reopenLastSource = "reopenLastSource"
        static let showFilmstrip = "showFilmstrip"
        static let showInfo = "showInfo"
        static let showHistory = "showHistory"
        static func sort(_ kind: RecentSource.Kind) -> String { "sort." + kind.rawValue }
        static let lastFolder = "lastFolder"
        static let lastSourceKind = "lastSourceKind"
        static let lastPhotosAlbum = "lastPhotosAlbum"
        static let recentSources = "recentSources"
        static let exportFolder = "exportFolder"
        static let exportOptions = "exportOptions"
        static let exportPhotosAlbum = "exportPhotosAlbum"
        static let exportTarget = "exportTarget"
        /// The export sheet's last picked preset name (`ExportPresetStore`).
        static let exportPreset = "exportPreset"
        /// Developer only (`DeveloperInfo.showTimings`), never in the window.
        static let showTimings = "showTimings"
    }

    /// The grid slider's range and default, in points: the smallest a grid
    /// cell may be (`GridView.columns(for:)`).
    static let thumbnailSizes: ClosedRange<Double> = 120...300
    static let defaultThumbnailSize: Double = 180

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let persistent: Bool

    /// The grid cells' minimum width in points (the Settings window and the
    /// slider under the grid), clamped to `thumbnailSizes`.
    var gridThumbnailSize: Double {
        didSet {
            let clamped = Self.clampSize(gridThumbnailSize)
            if clamped != gridThumbnailSize { gridThumbnailSize = clamped }
            write(gridThumbnailSize, Key.gridThumbnailSize)
        }
    }
    /// How the loupe's fit frame is rendered (`PreviewQuality`).
    var previewQuality: PreviewQuality {
        didSet { write(previewQuality.rawValue, Key.previewQuality) }
    }
    /// Reopen the last folder or album at launch (`Library.restoreLastSource`).
    var reopenLastSource: Bool {
        didSet { write(reopenLastSource, Key.reopenLastSource) }
    }
    /// The loupe's filmstrip shown (View › Filmstrip, F).
    var showFilmstrip: Bool {
        didSet { write(showFilmstrip, Key.showFilmstrip) }
    }
    /// The loupe panel's Info section open (View › Info, ⌘I).
    var showInfo: Bool {
        didSet { write(showInfo, Key.showInfo) }
    }
    /// The loupe panel's History section open (`HistoryList`).
    var showHistory: Bool {
        didSet { write(showHistory, Key.showHistory) }
    }
    /// The remembered sort per source kind (`sort(for:)`, `setSort(_:for:)`).
    private(set) var sorts: [RecentSource.Kind: PhotoSort] = [:]

    init(defaults: UserDefaults = .standard, persistent: Bool = true) {
        self.defaults = defaults
        self.persistent = persistent
        let read: UserDefaults? = persistent ? defaults : nil
        gridThumbnailSize = Self.clampSize(read?.object(forKey: Key.gridThumbnailSize) == nil
            ? Self.defaultThumbnailSize : read!.double(forKey: Key.gridThumbnailSize))
        previewQuality = read?.string(forKey: Key.previewQuality).flatMap(PreviewQuality.init(rawValue:)) ?? .full
        reopenLastSource = read?.object(forKey: Key.reopenLastSource) == nil ? true : read!.bool(forKey: Key.reopenLastSource)
        showFilmstrip = read?.object(forKey: Key.showFilmstrip) == nil ? true : read!.bool(forKey: Key.showFilmstrip)
        showInfo = read?.bool(forKey: Key.showInfo) ?? false
        showHistory = read?.bool(forKey: Key.showHistory) ?? false
        for kind in [RecentSource.Kind.folder, .photos] {
            if let raw = read?.string(forKey: Key.sort(kind)), let sort = PhotoSort(storageKey: raw) {
                sorts[kind] = sort
            }
        }
    }

    // MARK: Sort per source kind

    /// The kind's default before the user picks one.
    static func defaultSort(for kind: RecentSource.Kind) -> PhotoSort {
        kind == .folder ? .folderDefault : .photosDefault
    }

    /// The sort a source of `kind` opens in: the remembered one, else the
    /// kind's default.
    func sort(for kind: RecentSource.Kind) -> PhotoSort {
        sorts[kind] ?? Self.defaultSort(for: kind)
    }

    func setSort(_ sort: PhotoSort, for kind: RecentSource.Kind) {
        guard persistent else { return }
        if sorts[kind] != sort { sorts[kind] = sort }
        defaults.set(sort.storageKey, forKey: Key.sort(kind))
    }

    // MARK: Last source and Open Recent

    /// The last source opened: `lastSourceKind` `photos` names the album in
    /// `lastPhotosAlbum` (nil when it is missing); anything else is the
    /// folder in `lastFolder`.
    var lastSource: LastSource? {
        get {
            guard persistent else { return nil }
            if defaults.string(forKey: Key.lastSourceKind) == "photos" {
                return defaults.string(forKey: Key.lastPhotosAlbum).map { .photos(albumID: $0) }
            }
            return defaults.string(forKey: Key.lastFolder).map { .folder(path: $0) }
        }
        set {
            guard persistent else { return }
            switch newValue {
            case .folder(let path)?:
                defaults.set(path, forKey: Key.lastFolder)
                defaults.set("folder", forKey: Key.lastSourceKind)
            case .photos(let id)?:
                defaults.set(id, forKey: Key.lastPhotosAlbum)
                defaults.set("photos", forKey: Key.lastSourceKind)
            case nil:
                defaults.removeObject(forKey: Key.lastSourceKind)
            }
        }
    }

    /// Open Recent's list as stored (most recent first); `Library` dedupes
    /// and caps it.
    var recents: [RecentSource] {
        get {
            guard persistent, let data = defaults.data(forKey: Key.recentSources),
                  let list = try? JSONDecoder().decode([RecentSource].self, from: data) else { return [] }
            return list
        }
        set {
            guard persistent else { return }
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.recentSources)
        }
    }

    // MARK: The export sheet's last choices (`ExportQueue`)

    /// The last export folder's path.
    var exportFolder: String? {
        get { persistent ? defaults.string(forKey: Key.exportFolder) : nil }
        set { if persistent { defaults.set(newValue, forKey: Key.exportFolder) } }
    }
    /// The last Photos export's album name as stored ("" = none); nil when no
    /// Photos export was ever run.
    var exportAlbum: String? {
        get { persistent && defaults.object(forKey: Key.exportPhotosAlbum) != nil
                ? (defaults.string(forKey: Key.exportPhotosAlbum) ?? "") : nil }
        set { if persistent { defaults.set(newValue, forKey: Key.exportPhotosAlbum) } }
    }
    /// `photos` when the last run went to Photos, `folder` otherwise.
    var exportTarget: String? {
        get { persistent ? defaults.string(forKey: Key.exportTarget) : nil }
        set { if persistent { defaults.set(newValue, forKey: Key.exportTarget) } }
    }
    /// The name of the export preset last picked or saved in the export
    /// sheet; nil when none (or after it was deleted).
    var exportPreset: String? {
        get { persistent ? defaults.string(forKey: Key.exportPreset) : nil }
        set { if persistent { defaults.set(newValue, forKey: Key.exportPreset) } }
    }
    var exportOptions: ExportOptions? {
        get {
            guard persistent, let data = defaults.data(forKey: Key.exportOptions) else { return nil }
            return try? JSONDecoder().decode(ExportOptions.self, from: data)
        }
        set {
            guard persistent, let newValue, let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.exportOptions)
        }
    }

    // MARK: -

    static func clampSize(_ size: Double) -> Double {
        guard size.isFinite else { return defaultThumbnailSize }
        return min(max(size, thumbnailSizes.lowerBound), thumbnailSizes.upperBound)
    }

    private func write(_ value: Any, _ key: String) {
        guard persistent else { return }
        defaults.set(value, forKey: key)
    }
}
