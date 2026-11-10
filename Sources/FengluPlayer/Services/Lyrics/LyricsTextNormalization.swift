import Foundation

enum LyricsTextNormalization {
    static func uniqueNonEmptyStrings(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.compactMap { string in
            guard let value = string.nonEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    /// Shared keys for alias merging, lookup, identity checks, and page-chrome detection.
    static func key(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
