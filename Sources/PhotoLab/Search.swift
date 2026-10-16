import Foundation

/// The grid's search (`Library.searchText`), split into its terms: the
/// field's text at each run of whitespace. A photo matches when EVERY term
/// is found in its name or in one of its keywords, each term on its own
/// (one term may match the name and another a keyword). A term is found as
/// a substring, ignoring case and diacritics ("cafe" finds "Café"). An
/// empty search matches every photo.
struct PhotoSearch: Equatable {
    let terms: [String]

    init(_ text: String) {
        terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var isEmpty: Bool { terms.isEmpty }

    /// `name` nil: a photo its source has not named yet (a Photos asset,
    /// `Photo.isNamed` false), which matches by its keywords only, never by
    /// the asset identifier that stands in for its name.
    func matches(name: String?, keywords: [String]) -> Bool {
        terms.allSatisfy { term in
            if let name, Self.finds(term, in: name) { return true }
            return keywords.contains { Self.finds(term, in: $0) }
        }
    }

    func matches(_ photo: Photo, keywords: [String]) -> Bool {
        matches(name: photo.isNamed ? photo.name : nil, keywords: keywords)
    }

    /// True when `term` is a substring of `text`, ignoring case and
    /// diacritics.
    static func finds(_ term: String, in text: String) -> Bool {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
