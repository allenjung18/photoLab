import Foundation
import CoreImage

/// The learning half of Auto in my style, on the Mac only: how the user's
/// own values differ from Auto's on photos they picked
/// (Photo › Learn Style from Selected Photos…, `Library.learnStyle`).
///
/// A photo is put in a brightness bucket by the luma median of its frame
/// with the Basic and white-balance kinds at neutral (`StyleSample.neutralBase`,
/// measured by `ImageStats`), and per bucket each of `AutoTone.kinds` gets a
/// correction: the median of (user value − Auto value) over that bucket's
/// samples. A median, so one photo pushed far from the rest does not move
/// the correction. A bucket with fewer than `minimumBucketSamples` samples
/// uses the median over every sample instead.
enum StyleBucket: String, Codable, CaseIterable, Sendable {
    case dark, mid, bright

    /// The bucket of a frame whose luma median (0…1) is `median`: below
    /// `ImageStats.shadowCeiling` dark, above `ImageStats.highlightFloor`
    /// bright, else mid (`ImageStats.range(ofLuma:)`).
    static func of(lumaMedian median: Double) -> StyleBucket {
        switch ImageStats.range(ofLuma: median) {
        case .shadow: return .dark
        case .highlight: return .bright
        case .midtone: return .mid
        }
    }
}

/// One photo's evidence: its bucket, Auto's values for it (measured with its
/// Basic and white-balance kinds at neutral) and the photo's own values,
/// each over `AutoTone.kinds`. Values are keyed by `AdjustmentKind` raw value
/// so the JSON stays readable.
struct StyleSample: Codable, Equatable, Sendable {
    var photo: PhotoID
    var bucket: StyleBucket
    var auto: [String: Double]
    var own: [String: Double]

    init(photo: PhotoID, bucket: StyleBucket, auto: [AdjustmentKind: Double], own: [AdjustmentKind: Double]) {
        self.photo = photo
        self.bucket = bucket
        // A kind Auto left alone (a white balance it could not read) is
        // Auto's neutral: it is measured on the neutral base.
        self.auto = Dictionary(uniqueKeysWithValues: AutoTone.kinds.map { ($0.rawValue, auto[$0] ?? $0.neutral) })
        self.own = Dictionary(uniqueKeysWithValues: AutoTone.kinds.map { ($0.rawValue, own[$0] ?? $0.neutral) })
    }

    func auto(_ kind: AdjustmentKind) -> Double { auto[kind.rawValue] ?? kind.neutral }
    func own(_ kind: AdjustmentKind) -> Double { own[kind.rawValue] ?? kind.neutral }
    /// User value − Auto value for `kind`.
    func delta(_ kind: AdjustmentKind) -> Double { own(kind) - auto(kind) }

    /// Why a photo teaches nothing, or nil when it does.
    enum Skip: Equatable, Sendable { case unrefined, neutral }

    /// `.neutral` when every one of the photo's own values is neutral (it
    /// was never edited there), `.unrefined` when they equal Auto's (Auto
    /// applied and left as it was).
    var skip: Skip? {
        if AutoTone.kinds.allSatisfy({ abs(own($0) - $0.neutral) < 1e-9 }) { return .neutral }
        if AutoTone.kinds.allSatisfy({ abs(delta($0)) < 1e-9 }) { return .unrefined }
        return nil
    }

    /// The recipe Auto and the bucket are measured on: `recipe` with the
    /// Basic and white-balance kinds (`AutoTone.kinds`) at neutral and enabled.
    static func neutralBase(_ recipe: Recipe) -> Recipe {
        var r = recipe.normalized
        for kind in AutoTone.kinds { r[kind] = Adjustment(kind: kind, value: kind.neutral) }
        return r
    }

    /// What one photo's decode gives a sample: the bucket and Auto's values,
    /// both from `neutralBase(recipe)`. Synchronous; call off the main thread.
    static func measure(master: CIImage, recipe: Recipe) -> (bucket: StyleBucket, auto: [AdjustmentKind: Double])? {
        let base = neutralBase(recipe)
        guard let stats = ImageStats.of(master: master, recipe: base), let median = stats.luma(at: 0.5),
              let auto = AutoTone.values(for: master, recipe: base) else { return nil }
        return (StyleBucket.of(lumaMedian: median), auto)
    }
}

/// The learned style: the samples it came from and, per bucket, a
/// correction per kind of `AutoTone.kinds` to add to Auto's values. Built
/// only by `learn(from:)`; saved as one JSON file (`StyleStore`).
struct StyleProfile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// A bucket with fewer samples than this uses `overall`.
    static let minimumBucketSamples = 3

    var version: Int
    var samples: [StyleSample]
    /// Median correction per kind over every sample, keyed by raw value.
    var overall: [String: Double]
    /// Median correction per kind per bucket that has at least
    /// `minimumBucketSamples` samples; a thinner bucket is absent.
    var buckets: [String: [String: Double]]

    var sampleCount: Int { samples.count }

    /// The profile `samples` give. Pure: the same samples give the same profile.
    static func learn(from samples: [StyleSample]) -> StyleProfile {
        func medians(_ group: [StyleSample]) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: AutoTone.kinds.map { kind in
                (kind.rawValue, median(group.map { $0.delta(kind) }))
            })
        }
        var buckets: [String: [String: Double]] = [:]
        for bucket in StyleBucket.allCases {
            let group = samples.filter { $0.bucket == bucket }
            if group.count >= minimumBucketSamples { buckets[bucket.rawValue] = medians(group) }
        }
        return StyleProfile(version: currentVersion, samples: samples, overall: medians(samples), buckets: buckets)
    }

    /// `current`'s samples with `added` laid over them: a photo sampled
    /// again keeps only its newest sample.
    static func merging(_ added: [StyleSample], into current: [StyleSample]) -> [StyleSample] {
        let fresh = Set(added.map(\.photo))
        return current.filter { !fresh.contains($0.photo) } + added
    }

    /// The correction for a photo in `bucket`: the bucket's own when it has
    /// enough samples, else the all-photo median.
    func correction(for bucket: StyleBucket) -> [AdjustmentKind: Double] {
        let table = buckets[bucket.rawValue] ?? overall
        return Dictionary(uniqueKeysWithValues: AutoTone.kinds.map { ($0, table[$0.rawValue] ?? 0) })
    }

    /// The middle value, the mean of the two middle ones for an even count;
    /// 0 for none.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}

enum StyleError: LocalizedError, Equatable {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "The learned style was saved by a newer version of PhotoLab (format \(v); this version reads up to \(StyleProfile.currentVersion))."
        }
    }
}

/// The learned style's one file, `<directory>/style.json`, on `PresetStore`'s
/// rules: written atomically (temp file + rename); a file this build cannot
/// decode (damaged, or a `version` too new) is moved aside by
/// `UnreadableBackup` before a save, never overwritten. The directory is
/// injected so tests never touch the user's Application Support folder.
struct StyleStore {
    /// `~/Library/Application Support/PhotoLab/`.
    static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PhotoLab", isDirectory: true)
    }()
    static let fileName = "style.json"

    let directory: URL

    init(directory: URL = StyleStore.defaultDirectory) {
        self.directory = directory
    }

    var file: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// The saved profile, nil when there is none. A file that cannot be
    /// decoded, or whose `version` is newer than this build reads, throws.
    func load() throws -> StyleProfile? {
        guard exists else { return nil }
        return try Self.decode(Data(contentsOf: file))
    }

    static func decode(_ data: Data) throws -> StyleProfile {
        struct Header: Decodable { var version: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.version <= StyleProfile.currentVersion else { throw StyleError.unsupportedVersion(header.version) }
        return try JSONDecoder().decode(StyleProfile.self, from: data)
    }

    /// Writes `profile`, moving an unreadable file aside first.
    func save(_ profile: StyleProfile, now: Date = Date()) throws {
        if exists, (try? load()) == nil {
            try UnreadableBackup.moveAside(file, now: now)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: file, options: .atomic)
    }

    /// Forget Style: deletes the file (no-op when there is none).
    func remove() throws {
        guard exists else { return }
        try FileManager.default.removeItem(at: file)
    }
}

/// Photo › Learn Style from Selected Photos… waiting on Replace or Add to
/// current samples (`Library.requestLearnStyle`).
struct LearnStyleRequest: Identifiable, Equatable {
    let id = UUID()
    let ids: [Photo.ID]
    /// The samples the saved style holds now; 0 offers Replace only.
    let currentSamples: Int

    var title: String { "Learn your style from \(ids.count) photo\(ids.count == 1 ? "" : "s")?" }
    var message: String {
        currentSamples == 0
            ? "Each photo's Basic and white-balance values are compared with Auto's. Photos you left at Auto, or never edited there, are skipped. Nothing leaves this Mac."
            : "The current style holds \(currentSamples) photo\(currentSamples == 1 ? "" : "s"). Replace it, or add these to it."
    }
}
