import Foundation

enum TextSearch {
    /// Whether `text` contains `query`, ignoring case and accents.
    static func contains(_ query: String, in text: String) -> Bool {
        guard !query.isEmpty else { return false }
        let match = foldingStrokes(text).range(of: foldingStrokes(query) as String,
                                               options: [.caseInsensitive, .diacriticInsensitive])
        // Besides not found, some marks such as U+0900 match nothing at all.
        return match.length > 0
    }

    private static let strokedLetters = Dictionary(uniqueKeysWithValues: zip("ŁłØøĐđÐðĦħıŦŧ".utf16, "LlOoDdDdHhiTt".utf16))

    /// Stroked letters don't decompose, so `.diacriticInsensitive` leaves them alone.
    private static func foldingStrokes(_ text: String) -> NSString {
        guard !text.utf8.allSatisfy({ $0 < 0x80 }) else { return text as NSString }
        return String(decoding: text.utf16.map { $0 < 0xD0 ? $0 : strokedLetters[$0] ?? $0 }, as: UTF16.self) as NSString
    }
}
