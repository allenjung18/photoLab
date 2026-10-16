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

    /// The colour space the file is written in. nil (`ExportOptions`) keeps
    /// the source's own, as every export did before the option existed.
    enum ColorSpace: String, Codable, CaseIterable, Sendable {
        case sRGB, displayP3

        var label: String {
            switch self {
            case .sRGB: return "sRGB"
            case .displayP3: return "Display P3"
            }
        }

        var cgColorSpace: CGColorSpace {
            switch self {
            case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
            case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
            }
        }
    }

    /// Sharpening for the output, applied after the resize at the written
    /// size (`Renderer.render(sharpening:)`), so a downsized file keeps its
    /// edges. nil (`ExportOptions`) is off.
    enum Sharpening: String, Codable, CaseIterable, Sendable {
        case low, standard, high

        var label: String {
            switch self {
            case .low: return "Low"
            case .standard: return "Standard"
            case .high: return "High"
            }
        }

        /// `CISharpenLuminance.sharpness` at a 1 px radius in the output.
        var sharpness: Float {
            switch self {
            case .low: return 0.3
            case .standard: return 0.6
            case .high: return 1.0
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
    /// The file name as a template (`RenameTemplate`: `{name}`, `{date}`,
    /// `{seq}`) in place of `<stem><suffix>`; `suffix` is then not used.
    /// nil = `<stem><suffix>`; options stored by a build without the field
    /// decode with nil. The export queue resolves it to one stem per photo
    /// (`ExportQueue.start`), and that stem meets the collision policy as a
    /// plain name would (`Exporter.destination`).
    var nameTemplate: RenameTemplate? = nil
    /// With `keepMetadata`, leave out where the photo was taken: the GPS
    /// block and the IPTC location fields (`ExportMetadata.removingLocation`);
    /// the dates, camera and lens still travel. nil = keep it; options
    /// stored by a build without the field decode with nil.
    var removeLocation: Bool? = nil
    /// The file's colour space; nil = the source's own. Options stored by a
    /// build without the field decode with nil.
    var colorSpace: ColorSpace? = nil
    /// Output sharpening after the resize; nil = off. Options stored by a
    /// build without the field decode with nil.
    var sharpening: Sharpening? = nil

    static let `default` = ExportOptions()

    /// `removeLocation` as the sheet's toggle reads it.
    var removesLocation: Bool { removeLocation == true }

    var clampedQuality: Double { min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound) }

    /// The suffix with anything a file name cannot hold removed.
    var cleanSuffix: String { RenameTemplate.clean(suffix) }

    /// `<stem><suffix>.<ext>` for `source`, before any collision handling.
    /// `name` is the photo's own file name when the source file is a cache
    /// copy under another name (a Photos original); its extension is dropped
    /// like the source's. `copy` is a virtual copy's number
    /// (`PhotoID.copyNumber`): `-copy<n>` goes before the extension
    /// (`DSC06727-edit-copy2.jpg`), so a master and its copy exported
    /// together never share a name (an Overwrite would replace the master's
    /// output); nil for a master.
    func fileName(for source: URL, name: String? = nil, copy: Int? = nil) -> String {
        fileName(for: source, name: name, copy: copy, number: 1)
    }

    private static func stem(of source: URL, name: String?) -> String {
        guard let name, !name.isEmpty else { return source.deletingPathExtension().lastPathComponent }
        return (name as NSString).deletingPathExtension
    }

    /// `-copy<n>` for virtual copy `n`; empty for a master (nil).
    static func copySuffix(_ copy: Int?) -> String {
        copy.map { "-copy\($0)" } ?? ""
    }

    /// `fileName(for:)` with a counter: `<stem><suffix> 2.<ext>` (n = 2),
    /// `<stem><suffix>-copy<c> 2.<ext>` for copy `c`.
    func fileName(for source: URL, name: String? = nil, copy: Int? = nil, number n: Int) -> String {
        fileName(stem: Self.stem(of: source, name: name) + cleanSuffix, copy: copy, number: n)
    }

    /// `<stem>.<ext>`, or `<stem> <n>.<ext>` for n > 1: a stem already
    /// made (a `nameTemplate`'s), with this format's extension; a virtual
    /// copy's `-copy<c>` (`copySuffix`) after the stem, before the counter.
    func fileName(stem: String, copy: Int? = nil, number n: Int = 1) -> String {
        let stem = stem + Self.copySuffix(copy)
        return (n <= 1 ? stem : "\(stem) \(n)") + "." + format.fileExtension
    }

    /// One stem per photo of a batch under `nameTemplate`, in order, with
    /// `{name}` the photo's own stem (as `fileName(for:name:)` takes it);
    /// before any collision handling, without the extension. nil without a
    /// template.
    func templatedStems(for photos: [(source: URL, name: String?, date: Date?)]) -> [String]? {
        nameTemplate?.stems(for: photos.map { (Self.stem(of: $0.source, name: $0.name), $0.date) })
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

    /// `properties` without where the photo was taken: the GPS block and the
    /// IPTC city, sub-location, state and country fields go; everything
    /// else (dates, camera, lens, keywords) stays.
    static func removingLocation(from properties: [CFString: Any]) -> [CFString: Any] {
        var p = properties
        p.removeValue(forKey: kCGImagePropertyGPSDictionary)
        if var iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation,
                        kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCCountryPrimaryLocationName,
                        kCGImagePropertyIPTCCountryPrimaryLocationCode] {
                iptc.removeValue(forKey: key)
            }
            p[kCGImagePropertyIPTCDictionary] = iptc
        }
        return p
    }

    /// `properties` with the IPTC Keywords set to the photo's `keywords`
    /// (`Library.keywords(for:)`), replacing any the source carried and
    /// keeping the rest of its IPTC block. No keywords leaves `properties`
    /// as it was (the source's own IPTC Keywords, if any, travel).
    static func setting(keywords: [String], in properties: [CFString: Any]) -> [CFString: Any] {
        guard !keywords.isEmpty else { return properties }
        var p = properties
        var iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        iptc[kCGImagePropertyIPTCKeywords] = keywords
        p[kCGImagePropertyIPTCDictionary] = iptc
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
