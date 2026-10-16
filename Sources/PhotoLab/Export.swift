import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What an export writes: the container, its quality, the output size, the
/// file name, what happens when the name is taken, and whether the source's
/// camera metadata travels, and an optional text watermark. One value per run; `Exporter.export` is the one
/// path that reads it. Persisted as JSON between runs by `ExportQueue`.
struct ExportOptions: Codable, Hashable, Sendable {
    enum Format: String, Codable, CaseIterable, Sendable {
        case jpeg, heic, tiff

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .tiff: return "tif"
            }
        }

        var utType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .tiff: return .tiff
            }
        }

        var label: String {
            switch self {
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            case .tiff: return "TIFF"
            }
        }

        /// Whether `quality` means anything: TIFF is lossless (LZW).
        var isLossy: Bool { self != .tiff }
    }

    /// What to do when the output file already exists.
    enum Collision: String, Codable, CaseIterable, Sendable {
        /// `<name> 2.jpg`, `<name> 3.jpg`, …: nothing is ever replaced.
        case number
        /// Leave the existing file and count the photo as skipped.
        case skip
        /// Replace the existing file (never the photo's own original).
        case overwrite

        var label: String {
            switch self {
            case .number: return "Add a number"
            case .skip: return "Skip"
            case .overwrite: return "Overwrite"
            }
        }
    }

    /// The quality a lossy export may ask for: the sheet's slider range and
    /// the clamp `clampedQuality` applies are this one constant.
    static let qualityRange: ClosedRange<Double> = 0.3...1.0


    var format: Format = .jpeg
    /// Lossy compression quality, `qualityRange`; ignored for TIFF.
    var quality: Double = 0.9
    /// nil = the rendered size.
    var resize: OutputSize? = nil
    /// Carry the source's EXIF / TIFF / GPS / IPTC over to the output.
    var keepMetadata = true
    /// Appended to the original's stem: `DSC06727` + `-edit` → `DSC06727-edit.jpg`.
    var suffix = ""
    var collision: Collision = .number
    /// A text mark drawn over the output, the render's last stage
    /// (`Watermark`). nil = none; options stored by a build without the
    /// field decode with nil.
    var watermark: Watermark? = nil

    static let `default` = ExportOptions()

    var clampedQuality: Double { min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound) }

    /// The suffix with anything a file name cannot hold removed.
    var cleanSuffix: String {
        String(suffix.filter { !"/:\\\u{0}".contains($0) && !$0.isNewline })
    }

    /// `<stem><suffix>.<ext>` for `source`, before any collision handling.
    /// `name` is the photo's own file name when the source file is a cache
    /// copy under another name (a Photos original); its extension is dropped
    /// like the source's.
    func fileName(for source: URL, name: String? = nil) -> String {
        Self.stem(of: source, name: name) + cleanSuffix + "." + format.fileExtension
    }

    private static func stem(of source: URL, name: String?) -> String {
        guard let name, !name.isEmpty else { return source.deletingPathExtension().lastPathComponent }
        return (name as NSString).deletingPathExtension
    }

    /// `fileName(for:)` with a counter: `<stem><suffix> 2.<ext>` (n = 2).
    func fileName(for source: URL, name: String? = nil, number n: Int) -> String {
        let stem = Self.stem(of: source, name: name) + cleanSuffix
        return (n <= 1 ? stem : "\(stem) \(n)") + "." + format.fileExtension
    }
}

/// The source's metadata, made true for the file being written.
enum ExportMetadata {
    /// Every property ImageIO reads from the source (TIFF Make / Model /
    /// DateTime, the EXIF block with exposure, lens and dates, GPS, IPTC,
    /// the maker's aux block), with what describes the SOURCE container
    /// corrected or dropped: orientation is 1 (the render is already
    /// upright), pixel dimensions are the output's, the source format's
    /// own dictionaries (PNG, JFIF, Raw, DNG, …) and its compression /
    /// photometric tags go. Empty when the source has no readable
    /// properties.
    static func properties(of source: URL, outputWidth: Int, outputHeight: Int) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              var p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyHasAlpha, kCGImagePropertyColorModel, kCGImagePropertyProfileName,
                    kCGImagePropertyIsIndexed, kCGImagePropertyIsFloat,
                    kCGImagePropertyPNGDictionary, kCGImagePropertyJFIFDictionary, kCGImagePropertyGIFDictionary,
                    kCGImagePropertyRawDictionary, kCGImagePropertyDNGDictionary, kCGImagePropertyHEICSDictionary,
                    kCGImagePropertyWebPDictionary, kCGImagePropertyFileContentsDictionary] {
            p.removeValue(forKey: key)
        }
        p[kCGImagePropertyOrientation] = 1
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            tiff.removeValue(forKey: kCGImagePropertyTIFFCompression)
            tiff.removeValue(forKey: kCGImagePropertyTIFFPhotometricInterpretation)
            p[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = outputWidth
            exif[kCGImagePropertyExifPixelYDimension] = outputHeight
            p[kCGImagePropertyExifDictionary] = exif
        }
        return p
    }
}

/// Where an export run goes: files in a folder, or new photos in the Photos
/// library (optionally added to an album, created by title on first use).
/// Both render through `Exporter.export`; the Photos target writes each
/// file into a staging directory, hands it to a `PhotosWriter` and removes
/// it. Every Photos export is a NEW asset, so the collision policy does not
/// apply there; a photo opened from Photos comes back beside its original,
/// which is not changed.
enum ExportTarget: Hashable, Sendable {
    case folder(URL)
    /// nil = the library only, in no album.
    case photosLibrary(album: String?)

    /// The album the export sheet offers first.
    static let defaultAlbum = "PhotoLab"

    var folder: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }

    var isPhotosLibrary: Bool { folder == nil }

    /// What the export bar names as the destination: the folder's name,
    /// or `Photos` / `Photos › <album>`.
    var displayName: String {
        switch self {
        case .folder(let url): return url.lastPathComponent
        case .photosLibrary(nil): return "Photos"
        case .photosLibrary(let album?): return "Photos › \(album)"
        }
    }

    /// The album field's text as an album: trimmed, and nil when empty.
    static func album(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
