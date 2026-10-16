import Foundation

/// A file-name template over a batch of photos: literal text with the
/// tokens `{name}` (the original's stem), `{date}` (its capture date,
/// `yyyy-MM-dd`, `undated` when it has none) and `{seq}` (its 1-based place
/// in the batch, counted from `start` and zero-padded to the widest number
/// the batch reaches: 9 photos `1`…`9`, 10 photos `01`…`10`). Anything a file
/// name cannot hold is removed (`clean`, the rule `ExportOptions.cleanSuffix`
/// uses), and a result with nothing left falls back to `{name}`. It makes a
/// stem only; the caller adds the extension. Export's name template
/// (`ExportOptions.nameTemplate`) is one use.
struct RenameTemplate: Codable, Hashable, Sendable {
    static let nameToken = "{name}"
    static let dateToken = "{date}"
    static let seqToken = "{seq}"
    static let tokens = [nameToken, dateToken, seqToken]
    /// What `{date}` becomes for a photo with no capture date.
    static let undated = "undated"

    var pattern: String = "{name}"
    /// The number `{seq}` gives the batch's first photo (never below 0).
    var start: Int = 1

    init(pattern: String = "{name}", start: Int = 1) {
        self.pattern = pattern
        self.start = start
    }

    /// Either field missing from a stored template takes its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? "{name}"
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 1
    }

    private enum CodingKeys: String, CodingKey { case pattern, start }

    var clampedStart: Int { max(0, start) }

    /// The digits `{seq}` is padded to over a batch of `count`: those of the
    /// largest number it reaches (`start + count - 1`).
    func seqWidth(count: Int) -> Int {
        String(clampedStart + max(count, 1) - 1).count
    }

    /// The stem for the photo at `index` (0-based) of a batch of `count`,
    /// whose original stem is `name` and capture date `date`.
    func stem(name: String, date: Date?, index: Int, count: Int) -> String {
        let n = String(clampedStart + index)
        let seq = String(repeating: "0", count: max(0, seqWidth(count: count) - n.count)) + n
        let expanded = pattern
            .replacingOccurrences(of: Self.nameToken, with: name)
            .replacingOccurrences(of: Self.dateToken, with: date.map(Self.dateString) ?? Self.undated)
            .replacingOccurrences(of: Self.seqToken, with: seq)
        let cleaned = Self.clean(expanded)
        if cleaned.trimmingCharacters(in: .whitespaces).isEmpty { return Self.clean(name) }
        return cleaned
    }

    /// One stem per photo, in order: the batch is `photos`.
    func stems(for photos: [(name: String, date: Date?)]) -> [String] {
        photos.enumerated().map { stem(name: $1.name, date: $1.date, index: $0, count: photos.count) }
    }

    /// `text` with the characters a file name cannot hold removed: `/`, `:`,
    /// `\`, NUL and line breaks.
    static func clean(_ text: String) -> String {
        String(text.filter { !"/:\\\u{0}".contains($0) && !$0.isNewline })
    }

    /// `yyyy-MM-dd` in the local calendar (the zone `CaptureDates` reads
    /// EXIF times in).
    static func dateString(_ date: Date) -> String {
        let d = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }
}
