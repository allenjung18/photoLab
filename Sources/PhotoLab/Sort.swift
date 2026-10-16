import Foundation
import ImageIO

/// What the grid is ordered by: Lightroom's Capture Time, File Name and
/// Rating, plus Edited (photos with an edit, `Library.isEdited`, apart from
/// the rest).
enum SortKey: String, CaseIterable, Sendable {
    case captureDate, name, rating, edited

    var label: String {
        switch self {
        case .captureDate: return "Capture Date"
        case .name: return "Name"
        case .rating: return "Rating"
        case .edited: return "Edited"
        }
    }
}

/// The one order rule of the grid, the filmstrip and the arrow keys, for a
/// folder and a Photos album alike (`sorted(_:captureDate:rating:edited:)`).
/// A key and a direction; ties are broken by name (ascending, whatever the
/// direction), then by the id, so the order is total and a re-sort never
/// shuffles equal photos. A photo with no capture date sorts after every
/// dated one in either direction.
struct PhotoSort: Equatable, Hashable, Sendable {
    var key: SortKey
    var ascending: Bool

    /// What a folder opens in until the user picks another order: by name
    /// (before sorting existed, a folder listed in path order).
    static let folderDefault = PhotoSort(key: .name, ascending: true)
    /// What a Photos album opens in: oldest capture first, the order Photos
    /// itself fetches in (`PhotoKitLive.assetFetchOptions`).
    static let photosDefault = PhotoSort(key: .captureDate, ascending: true)

    /// How the choice is stored: `captureDate.ascending`.
    var storageKey: String { key.rawValue + "." + (ascending ? "ascending" : "descending") }

    init(key: SortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ".").map(String.init)
        guard parts.count == 2, let key = SortKey(rawValue: parts[0]),
              parts[1] == "ascending" || parts[1] == "descending" else { return nil }
        self.init(key: key, ascending: parts[1] == "ascending")
    }

    /// The photos in this order. Every value is read once per photo (the
    /// capture date may be a file read), then the list is sorted on them.
    func sorted(_ photos: [Photo],
                captureDate: (Photo) -> Date?,
                rating: (Photo.ID) -> Int,
                edited: (Photo.ID) -> Bool) -> [Photo] {
        struct Row {
            let photo: Photo
            let date: Date?
            let number: Int
        }
        let rows: [Row] = photos.map { p in
            switch key {
            case .captureDate: return Row(photo: p, date: captureDate(p), number: 0)
            case .name: return Row(photo: p, date: nil, number: 0)
            case .rating: return Row(photo: p, date: nil, number: rating(p.id))
            case .edited: return Row(photo: p, date: nil, number: edited(p.id) ? 1 : 0)
            }
        }
        let ascending = self.ascending
        let key = self.key
        return rows.sorted { a, b in
            switch key {
            case .captureDate:
                switch (a.date, b.date) {
                case let (x?, y?) where x != y: return ascending ? x < y : x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            case .name:
                let c = Self.compareNames(a.photo, b.photo)
                if c != .orderedSame { return ascending ? c == .orderedAscending : c == .orderedDescending }
                return a.photo.id.cacheKey < b.photo.id.cacheKey
            case .rating, .edited:
                if a.number != b.number { return ascending ? a.number < b.number : a.number > b.number }
            }
            return Self.tieBreak(a.photo, b.photo)
        }.map(\.photo)
    }

    /// Names in Finder's order (`IMG_2` before `IMG_10`).
    private static func compareNames(_ a: Photo, _ b: Photo) -> ComparisonResult {
        a.name.localizedStandardCompare(b.name)
    }

    /// Equal keys: by name, then by id, both ascending.
    private static func tieBreak(_ a: Photo, _ b: Photo) -> Bool {
        let c = compareNames(a, b)
        if c != .orderedSame { return c == .orderedAscending }
        return a.id.cacheKey < b.id.cacheKey
    }
}

/// Capture dates, read once per photo and kept: a Photos asset's comes with
/// the listing (`Photo.captureDate`, the asset's `creationDate`); a file's
/// is its EXIF `DateTimeOriginal` (`CaptureDates.read`), else the file's
/// creation date, else its modification date. Only the header is read,
/// never the pixels. The cache lives as long as the library and is keyed
/// by photo id; `reader` is injected so a test can count the reads.
@MainActor
final class CaptureDates {
    private var cache: [Photo.ID: Date?] = [:]
    private let reader: (URL) -> Date?

    init(reader: @escaping (URL) -> Date? = CaptureDates.read) {
        self.reader = reader
    }

    func date(for photo: Photo) -> Date? {
        if let d = photo.captureDate { return d }
        if let hit = cache[photo.id] { return hit }
        let d = photo.fileURL.flatMap(reader)
        cache[photo.id] = .some(d)
        return d
    }

    /// EXIF `DateTimeOriginal` (local time, `yyyy:MM:dd HH:mm:ss`), else the
    /// file's creation date, else its modification date; nil when neither
    /// the header nor the file can be read.
    nonisolated static func read(_ url: URL) -> Date? {
        if let d = exifDate(url) { return d }
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return v?.creationDate ?? v?.contentModificationDate
    }

    nonisolated static func exifDate(_ url: URL) -> Date? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, options) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        return exifFormatter.date(from: text)
    }

    private nonisolated static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f
    }()
}

/// The sort, remembered per source kind (one choice for every folder, one
/// for every Photos album) in the library's injected `UserDefaults`.
extension Library {
    /// `folder` for a `FolderSource`, `photos` for any other (a library of
    /// assets).
    var sortKind: RecentSource.Kind { source is FolderSource ? .folder : .photos }

    static func sortDefaultsKey(_ kind: RecentSource.Kind) -> String { "sort." + kind.rawValue }

    /// The sort a source of `kind` opens in: the remembered choice, else the
    /// kind's default.
    func storedSort(for kind: RecentSource.Kind) -> PhotoSort {
        let fallback: PhotoSort = kind == .folder ? .folderDefault : .photosDefault
        guard rememberFolder, let raw = defaults.string(forKey: Self.sortDefaultsKey(kind)) else { return fallback }
        return PhotoSort(storageKey: raw) ?? fallback
    }

    /// Re-orders `photos` by `sort`. Only the order moves: the selection,
    /// the anchor, the loupe and every map keyed by id are untouched.
    func resort() {
        photos = sort.sorted(photos,
                             captureDate: { captureDates.date(for: $0) },
                             rating: { rating(for: $0) },
                             edited: { isEdited($0) })
    }
}
