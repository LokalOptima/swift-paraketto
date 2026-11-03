import Foundation

enum TextSearch {
    /// What to look for in what was typed, if anything. A single letter would match nearly everything.
    static func term(in typed: String) -> String {
        let term = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.count < 2 ? "" : term
    }

    /// Every occurrence of `query`, ignoring case and accents. UTF-16 ranges, matching AppKit's text system.
    static func matches(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let text = foldingStrokes(text)
        let query = foldingStrokes(query) as String
        var matches: [NSRange] = []
        var start = 0
        while start < text.length {
            let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: NSRange(location: start, length: text.length - start))
            // Besides not found, some marks such as U+0900 match nothing at all, which would never advance.
            guard match.length > 0 else { break }
            matches.append(match)
            start = NSMaxRange(match)
        }
        return matches
    }

    private static let strokedLetters = Dictionary(uniqueKeysWithValues: zip("ŁłØøĐđÐðĦħıŦŧ".utf16, "LlOoDdDdHhiTt".utf16))

    /// Stroked letters don't decompose, so `.diacriticInsensitive` leaves them alone. Each folds
    /// to a single UTF-16 unit, which keeps ranges valid for the original text.
    private static func foldingStrokes(_ text: String) -> NSString {
        guard !text.utf8.allSatisfy({ $0 < 0x80 }) else { return text as NSString }
        return String(decoding: text.utf16.map { $0 < 0xD0 ? $0 : strokedLetters[$0] ?? $0 }, as: UTF16.self) as NSString
    }

    /// Stretches of `text` around `matches` for when only about `capacity` UTF-16 units fit. When more
    /// matches exist than fit, they are sampled evenly so the stretches span the whole transcript.
    /// Stretches stop at word boundaries, and stretches with only whitespace between them join.
    static func excerpt(of text: String, around matches: [NSRange], capacity: Int, context: Int = 30) -> [NSRange] {
        guard let first = matches.first else { return [] }
        let text = text as NSString
        let separatorLength = 3
        let fitting = max(1, capacity / (2 * context + first.length + separatorLength))
        let chosen = matches.count <= fitting ? matches
            : (0..<fitting).map { matches[$0 * (matches.count - 1) / max(1, fitting - 1)] }
        var stretches: [NSRange] = []
        for match in chosen {
            let next = stretch(around: match, in: text, context: context)
            if let last = stretches.last, onlyWhitespaceSeparates(last, next, in: text) {
                stretches[stretches.count - 1] = NSUnionRange(last, next)
            } else {
                stretches.append(next)
            }
        }
        return stretches
    }

    private static func onlyWhitespaceSeparates(_ first: NSRange, _ second: NSRange, in text: NSString) -> Bool {
        let end = NSMaxRange(first)
        guard second.location > end else { return true }
        let gap = NSRange(location: end, length: second.location - end)
        return text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, range: gap).location == NSNotFound
    }

    private static func stretch(around match: NSRange, in text: NSString, context: Int) -> NSRange {
        let matchEnd = NSMaxRange(match)
        var start = 0
        if match.location > context {
            let earliest = text.rangeOfComposedCharacterSequence(at: match.location - context).location
            let space = text.rangeOfCharacter(from: .whitespacesAndNewlines,
                                              range: NSRange(location: earliest, length: match.location - earliest))
            start = space.location == NSNotFound ? earliest : NSMaxRange(space)
        }
        var end = text.length
        if text.length - matchEnd > context {
            let latest = NSMaxRange(text.rangeOfComposedCharacterSequence(at: matchEnd + context - 1))
            let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards,
                                              range: NSRange(location: matchEnd, length: latest - matchEnd))
            end = space.location == NSNotFound ? latest : space.location
        }
        return NSRange(location: start, length: end - start)
    }
}
