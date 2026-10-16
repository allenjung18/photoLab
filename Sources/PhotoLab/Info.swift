import Foundation
import ImageIO
import SwiftUI

/// What the loupe panel's Info section knows about one photo: the camera
/// and exposure from the header's TIFF and EXIF blocks, the pixel
/// dimensions as displayed (orientation applied), the file's name, size and
/// folder, the capture date and the GPS position. Every field is optional;
/// `rows(edited:keywords:)` leaves a missing one out rather than showing it blank.
/// The edited state and the keywords are not stored here: they change with
/// every edit, so the view asks the library (`Library.isEdited`,
/// `Library.keywords(for:)`) each time it draws.
struct PhotoInfo: Equatable, Sendable {
    var make: String?
    var model: String?
    var lens: String?
    /// Millimetres.
    var focalLength: Double?
    var fNumber: Double?
    /// Seconds.
    var exposureTime: Double?
    var iso: Int?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var fileName: String?
    /// Bytes.
    var fileSize: Int64?
    var folder: URL?
    var captureDate: Date?
    /// Degrees, north positive.
    var latitude: Double?
    /// Degrees, east positive.
    var longitude: Double?

    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// The labels in display order (`rows(edited:keywords:)` shows a subset of them).
    static let labels = ["Camera", "Lens", "Focal Length", "Aperture", "Shutter", "ISO",
                         "Dimensions", "File", "Size", "Folder", "Captured", "GPS", "Keywords", "Edited"]

    /// The present fields, formatted, in `labels` order; Keywords (the
    /// photo's, comma-separated) only when it has any; Edited is always
    /// there.
    func rows(edited: Bool, keywords: [String] = []) -> [Row] {
        var out: [Row] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            out.append(Row(label: label, value: value))
        }
        add("Camera", Self.camera(make: make, model: model))
        add("Lens", lens)
        add("Focal Length", focalLength.flatMap(Self.focalLength))
        add("Aperture", fNumber.flatMap(Self.aperture))
        add("Shutter", exposureTime.flatMap(Self.shutter))
        add("ISO", iso.flatMap { $0 > 0 ? "ISO \($0)" : nil })
        if let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 { add("Dimensions", "\(w) × \(h)") }
        add("File", fileName)
        add("Size", fileSize.map(Self.size))
        add("Folder", folder.map { ($0.path as NSString).abbreviatingWithTildeInPath })
        add("Captured", captureDate.map(Self.date))
        if let latitude, let longitude { add("GPS", Self.coordinates(latitude: latitude, longitude: longitude)) }
        add("Keywords", keywords.joined(separator: ", "))
        add("Edited", edited ? "Yes" : "No")
        return out
    }

    // MARK: Formatting

    /// "Canon EOS R5" from make "Canon" and model "Canon EOS R5" (most
    /// cameras repeat the make in the model); "Fujifilm X-T5" from "Fujifilm"
    /// and "X-T5"; either alone when the other is missing.
    static func camera(make: String?, model: String?) -> String? {
        let make = make.flatMap(trimmed), model = model.flatMap(trimmed)
        switch (make, model) {
        case let (make?, model?):
            return model.lowercased().hasPrefix(make.lowercased()) ? model : make + " " + model
        case let (make?, nil): return make
        case let (nil, model?): return model
        default: return nil
        }
    }

    /// "50 mm", "23.5 mm".
    static func focalLength(_ mm: Double) -> String? {
        mm > 0 ? decimal(mm) + " mm" : nil
    }

    /// "f/2.8", "f/8".
    static func aperture(_ f: Double) -> String? {
        f > 0 ? "f/" + decimal(f) : nil
    }

    /// "1/250 s" under a second, "1 s", "2.5 s" from a second up.
    static func shutter(_ seconds: Double) -> String? {
        guard seconds > 0 else { return nil }
        if seconds >= 1 { return decimal(seconds) + " s" }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    /// Decimal units as the Finder counts them: "512 bytes", "48.2 KB",
    /// "12.3 MB", "1.25 GB".
    static func size(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if bytes < 1_000 { return "\(bytes) byte\(bytes == 1 ? "" : "s")" }
        if b < 1e6 { return String(format: "%.1f KB", b / 1e3) }
        if b < 1e9 { return String(format: "%.1f MB", b / 1e6) }
        return String(format: "%.2f GB", b / 1e9)
    }

    /// The capture date in the user's locale and time zone.
    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    /// "47.60000° N, 122.33210° W": five decimals, about a metre.
    static func coordinates(latitude: Double, longitude: Double) -> String {
        String(format: "%.5f° %@, %.5f° %@",
               abs(latitude), latitude < 0 ? "S" : "N", abs(longitude), longitude < 0 ? "W" : "E")
    }

    /// One decimal at most, none when it is whole: 50, 2.8, 23.5.
    private static func decimal(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    private static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return t.isEmpty ? nil : t
    }

    // MARK: Reading

    /// Everything a file says about itself, from one header read
    /// (`CaptureDates.properties(of:)`, never the pixels) plus its file
    /// attributes. The capture date follows the sort's rule
    /// (`CaptureDates.date(properties:url:)`). Runs off the main thread
    /// (`PhotoInfoStore`).
    nonisolated static func read(_ url: URL) -> PhotoInfo {
        let props = CaptureDates.properties(of: url)
        var info = PhotoInfo(properties: props ?? [:])
        info.fileName = url.lastPathComponent
        info.folder = url.deletingLastPathComponent()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        info.fileSize = values?.fileSize.map(Int64.init)
        info.captureDate = CaptureDates.date(properties: props, url: url)
        return info
    }

    /// The header's fields alone (no file name, size, folder or date).
    init(properties p: [CFString: Any]) {
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        make = tiff[kCGImagePropertyTIFFMake] as? String
        model = tiff[kCGImagePropertyTIFFModel] as? String
        lens = ((exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]) as? String)
            .flatMap(Self.trimmed)
        focalLength = Self.number(exif[kCGImagePropertyExifFocalLength])
        fNumber = Self.number(exif[kCGImagePropertyExifFNumber])
        exposureTime = Self.number(exif[kCGImagePropertyExifExposureTime])
        let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any]
        iso = isos?.first.flatMap(Self.number).map { Int($0.rounded()) }
        if let w = Self.number(p[kCGImagePropertyPixelWidth]), let h = Self.number(p[kCGImagePropertyPixelHeight]) {
            // Orientations 5 to 8 turn the picture a quarter: it is
            // displayed (and exported) h wide.
            let turned = (5...8).contains(Int(Self.number(p[kCGImagePropertyOrientation]) ?? 1))
            pixelWidth = Int(turned ? h : w)
            pixelHeight = Int(turned ? w : h)
        }
        if let lat = Self.number(gps[kCGImagePropertyGPSLatitude]),
           let lon = Self.number(gps[kCGImagePropertyGPSLongitude]) {
            latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" ? -lat : lat
            longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" ? -lon : lon
        }
    }

    init() {}

    private static func number(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }
}

/// The Info section's reads: each photo's header is read once, off the main
/// thread, and kept for as long as the library (keyed by photo id, as
/// `CaptureDates` is). A folder photo's capture date goes to `CaptureDates`
/// too, so a later Capture Date sort does not read that header again; what
/// the sort already knows wins, so the two never disagree.
///
/// A Photos asset (`.asset` id) shows what PhotoKit gives: the listing's
/// name and `creationDate` at once, and once the loupe has the original
/// PhotoKit wrote out (`PhotoSource.originalFile(for:)`) the camera,
/// exposure, dimensions, size and GPS read from it. It has no folder: the
/// copy lives in the Caches directory, not where the user keeps it.
/// `reader` is injected so a test can count the reads.
@MainActor
final class PhotoInfoStore {
    private var cache: [Photo.ID: PhotoInfo] = [:]
    private var pending: [Photo.ID: Task<PhotoInfo, Never>] = [:]
    private let captureDates: CaptureDates
    private let reader: @Sendable (URL) -> PhotoInfo

    init(captureDates: CaptureDates, reader: @escaping @Sendable (URL) -> PhotoInfo = { PhotoInfo.read($0) }) {
        self.captureDates = captureDates
        self.reader = reader
    }

    /// What is known before any read: the name (none while the photo is
    /// unnamed) and, for an asset, the listing's capture date.
    static func listing(_ photo: Photo) -> PhotoInfo {
        var info = PhotoInfo()
        info.fileName = photo.isNamed ? photo.name : nil
        info.folder = photo.fileURL?.deletingLastPathComponent()
        info.captureDate = photo.captureDate
        return info
    }

    func cached(_ id: Photo.ID) -> PhotoInfo? { cache[id] }

    /// A photo renamed in place (`Library.rename`): its read info is the
    /// new id's, with the new file name (the folder is the same).
    func rename(_ old: Photo.ID, to new: Photo.ID, name: String) {
        guard var info = cache.removeValue(forKey: old) else { return }
        info.fileName = name
        cache[new] = info
    }

    /// The photo's info, reading `file` (its original) the first time;
    /// without a file yet, the listing's part, not kept.
    func info(for photo: Photo, file: URL?) async -> PhotoInfo {
        if let hit = cache[photo.id] { return hit }
        guard let file else { return Self.listing(photo) }
        let task: Task<PhotoInfo, Never>
        if let running = pending[photo.id] {
            task = running
        } else {
            let reader = reader
            task = Task.detached(priority: .utility) { reader(file) }
            pending[photo.id] = task
        }
        var info = await task.value
        pending[photo.id] = nil
        if let hit = cache[photo.id] { return hit }
        switch photo.id.master {
        case .file:
            captureDates.remember(info.captureDate, for: photo.id)
            info.captureDate = captureDates.date(for: photo)
        case .asset:
            info.fileName = photo.isNamed ? photo.name : nil
            info.folder = nil
            info.captureDate = photo.captureDate
        case .copy:
            break  // `master` is never a copy
        }
        cache[photo.id] = info
        return info
    }
}

/// The Info section of the loupe panel (View › Info, ⌘I): one row per field
/// the photo has, the label on the left; a missing field has no row.
struct InfoSection: View {
    @Environment(Library.self) private var library
    let photo: Photo
    /// The photo's original file; nil until the source has it.
    let file: URL?
    @State private var loaded: (id: Photo.ID, info: PhotoInfo)?

    private struct Load: Equatable {
        let id: Photo.ID
        let file: URL?
    }

    /// The loaded info, else the store's, else the listing's; an asset's
    /// File row is always the photo's current name, which may land after
    /// its header was read (`Library.resolveName`).
    private var shown: PhotoInfo {
        var info = loaded.flatMap { $0.id == photo.id ? $0.info : nil }
            ?? library.photoInfo.cached(photo.id)
            ?? PhotoInfoStore.listing(photo)
        if case .asset = photo.id.master { info.fileName = photo.isNamed ? photo.name : nil }
        return info
    }

    var body: some View {
        let info = shown
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(info.rows(edited: library.isEdited(photo.id), keywords: library.keywords(for: photo.id))) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(row.value)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(row.value)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: Load(id: photo.id, file: file)) {
            let info = await library.photoInfo.info(for: photo, file: file)
            if !Task.isCancelled { loaded = (photo.id, info) }
        }
    }
}
