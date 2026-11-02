import Combine
import Foundation

struct DictionaryRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var target: String
    var aliases: [String]
}

struct Replacement: Equatable {
    let ruleID: UUID
    let alias: String
    let originalRange: NSRange
    let outputRange: NSRange
}

struct ReplacementResult: Equatable {
    let original: String
    let text: String
    let replacements: [Replacement]

    /// Map a visible selection back to the original. Never learn half of a replacement.
    func originalSelection(_ selection: NSRange) -> String? {
        guard selection.location != NSNotFound, selection.length > 0,
              NSMaxRange(selection) <= (text as NSString).length else { return nil }
        let visible = text as NSString
        var selected = selection
        while selected.length > 0, Self.isWhitespace(visible.character(at: selected.location)) {
            selected.location += 1; selected.length -= 1
        }
        while selected.length > 0, Self.isWhitespace(visible.character(at: NSMaxRange(selected) - 1)) {
            selected.length -= 1
        }
        guard selected.length > 0 else { return nil }
        var start = selected.location
        var end = NSMaxRange(selected)
        for edit in replacements {
            if NSIntersectionRange(edit.outputRange, selected).length > 0,
               !(selected.location <= edit.outputRange.location && NSMaxRange(selected) >= NSMaxRange(edit.outputRange)) {
                return nil
            }
            let delta = edit.originalRange.length - edit.outputRange.length
            if NSMaxRange(edit.outputRange) <= selected.location { start += delta }
            if NSMaxRange(edit.outputRange) <= NSMaxRange(selected) { end += delta }
        }
        let sourceRange = NSRange(location: start, length: end - start)
        guard Range(sourceRange, in: original) != nil else { return nil }
        return (original as NSString).substring(with: sourceRange).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

/// UTF-16 trie: literal code-unit comparisons avoid Swift String's canonical equivalence.
/// Ranges use UTF-16 too, matching AppKit selection and highlighting APIs.
struct DictionaryMatcher {
    private struct Candidate {
        let ruleID: UUID
        let alias: String
        let target: [UInt16]
    }
    private struct Node {
        var children: [UInt16: Int] = [:]
        var candidate: Candidate?
    }
    private var nodes = [Node()]
    private static let trailingPunctuation = Set(".,;'\"?!)’”".utf16)
    private static let tokens = try! NSRegularExpression(pattern: #"\S+"#)
    private static let domain = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_-]+\.[\p{L}\p{N}_-]+"#)
    private static let scheme = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*:"#)
    private static let quotedEmail = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"@[^\s]+"#)
    private static let links = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    init(rules: [DictionaryRule] = []) {
        for rule in rules {
            for alias in rule.aliases where !alias.isEmpty {
                var node = 0
                for unit in alias.utf16 {
                    if let child = nodes[node].children[unit] { node = child }
                    else {
                        let child = nodes.count
                        nodes.append(Node())
                        nodes[node].children[unit] = child
                        node = child
                    }
                }
                nodes[node].candidate = Candidate(ruleID: rule.id, alias: alias, target: Array(rule.target.utf16))
            }
        }
    }

    func apply(to original: String) -> ReplacementResult {
        guard nodes.count > 1 else { return ReplacementResult(original: original, text: original, replacements: []) }
        let input = Array(original.utf16)
        let protected = Self.protectedRanges(in: original)
        // Mark protected units once; prefix sums make overlap checks constant-time.
        var mask = [Int](repeating: 0, count: input.count + 1)
        for range in protected {
            mask[range.location] += 1
            mask[NSMaxRange(range)] -= 1
        }
        var active = 0
        var protectedCount = [Int](repeating: 0, count: input.count + 1)
        for i in input.indices {
            active += mask[i]
            protectedCount[i + 1] = protectedCount[i] + (active > 0 ? 1 : 0)
        }
        var output: [UInt16] = []
        var replacements: [Replacement] = []
        var position = 0
        func isBreak(_ index: Int) -> Bool {
            index < 0 || index >= input.count || ReplacementResult.isWhitespace(input[index])
        }
        // Punctuation may follow an alias only if the word ends there: "don" must not match in "don't".
        func endsWord(_ index: Int) -> Bool {
            var end = index
            while end < input.count, Self.trailingPunctuation.contains(input[end]) { end += 1 }
            return isBreak(end)
        }
        while position < input.count {
            var node = 0
            var cursor = position
            var best: (Candidate, Int)?
            if isBreak(position - 1) {
                while cursor < input.count, let child = nodes[node].children[input[cursor]] {
                    node = child
                    cursor += 1
                    if let candidate = nodes[node].candidate, endsWord(cursor),
                       protectedCount[cursor] == protectedCount[position] {
                        best = (candidate, cursor)
                    }
                }
            }
            if let (candidate, end) = best {
                let sourceRange = NSRange(location: position, length: end - position)
                // An explicitly entered identity alias does not need a highlight.
                if Array(input[position..<end]) != candidate.target {
                    replacements.append(Replacement(ruleID: candidate.ruleID, alias: candidate.alias,
                                                    originalRange: sourceRange,
                                                    outputRange: NSRange(location: output.count, length: candidate.target.count)))
                }
                output += candidate.target
                position = end
            } else {
                output.append(input[position]); position += 1
            }
        }
        return ReplacementResult(original: original, text: String(decoding: output, as: UTF16.self), replacements: replacements)
    }

    private static func protectedRanges(in text: String) -> [NSRange] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        var ranges = links.matches(in: text, range: full).map(\.range)
        ranges += quotedEmail.matches(in: text, range: full).map(\.range)
        // Extend beyond a detector's interpretation: protect the complete token, including
        // query/fragment/punctuation and unrecognized domains, addresses and paths.
        for match in tokens.matches(in: text, range: full) {
            let token = (text as NSString).substring(with: match.range)
            if token.contains("@") || token.contains("/") || token.contains("\\")
                || scheme.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)) != nil
                || domain.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)) != nil
                || ranges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                ranges.append(match.range)
            }
        }
        return ranges
    }
}

@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var rules: [DictionaryRule] = []
    @Published private(set) var loadError: String?
    let url: URL

    init(url: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = url ?? support.appendingPathComponent("Paraketto/dictionary.json")
        do {
            let data = try Data(contentsOf: self.url)
            let loaded = try JSONDecoder().decode([DictionaryRule].self, from: data)
            try Self.validate(loaded)
            rules = loaded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A new dictionary starts empty.
        } catch {
            loadError = "Could not read dictionary: \(error.localizedDescription)"
        }
    }

    func save(_ rule: DictionaryRule) throws {
        var next = rules
        if let index = next.firstIndex(where: { $0.id == rule.id }) { next[index] = rule }
        else { next.append(rule) }
        try commit(next)
    }

    /// Saves a rule, joining it to any other rule with the same target so each target keeps one rule.
    func saveMerging(_ rule: DictionaryRule) throws {
        var next = rules
        if let index = next.firstIndex(where: { $0.id != rule.id && Array($0.target.utf16) == Array(rule.target.utf16) }) {
            let known = next[index].aliases.map { Array($0.utf16) }
            next[index].aliases += rule.aliases.filter { !known.contains(Array($0.utf16)) }
            next.removeAll { $0.id == rule.id }
        } else if let index = next.firstIndex(where: { $0.id == rule.id }) {
            next[index] = rule
        } else {
            next.append(rule)
        }
        if next != rules { try commit(next) }
    }

    func remove(id: UUID) throws { try commit(rules.filter { $0.id != id }) }

    func removeAlias(_ alias: String, from id: UUID) throws {
        guard var rule = rules.first(where: { $0.id == id }) else { return }
        rule.aliases.removeAll { Array($0.utf16) == Array(alias.utf16) }
        if rule.aliases.isEmpty { try remove(id: id) }
        else { try save(rule) }
    }

    private func commit(_ next: [DictionaryRule]) throws {
        if let loadError { throw DictionaryError(loadError) }
        try Self.validate(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: url, options: .atomic)
        rules = next
    }

    static func validate(_ rules: [DictionaryRule]) throws {
        var aliases = Set<[UInt16]>()
        var ids = Set<UUID>()
        var targets = Set<[UInt16]>()
        for rule in rules {
            guard ids.insert(rule.id).inserted else { throw DictionaryError("Duplicate replacement.") }
            guard !rule.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DictionaryError("Enter the text to write instead.")
            }
            guard targets.insert(Array(rule.target.utf16)).inserted else {
                throw DictionaryError("Two replacements write “\(rule.target)”.")
            }
            guard !rule.aliases.isEmpty else { throw DictionaryError("Add at least one spelling to replace.") }
            for alias in rule.aliases {
                guard !alias.isEmpty, alias == alias.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw DictionaryError("Spellings can’t be empty or start or end with a space.")
                }
                guard aliases.insert(Array(alias.utf16)).inserted else {
                    throw DictionaryError("“\(alias)” already belongs to another replacement.")
                }
            }
        }
    }
}

/// A replacement while it is being typed. Separate from the view so its rules can be tested.
struct ReplacementForm: Equatable {
    let ruleID: UUID
    private(set) var aliases: [String]
    var pendingAlias = ""
    var target: String
    private let originalTarget: String
    private var keptCommas = 0

    init(rule: DictionaryRule) {
        ruleID = rule.id
        aliases = rule.aliases
        target = rule.target
        originalTarget = rule.target
    }

    /// What saving would store, counting the spelling still being typed.
    var rule: DictionaryRule {
        var form = self
        form.commitPendingAlias()
        return DictionaryRule(id: ruleID, target: target.trimmingCharacters(in: .whitespacesAndNewlines), aliases: form.aliases)
    }

    /// A typed comma finishes a spelling. Commas already in a reopened spelling stay in it.
    mutating func finishTypedAliases() {
        let commas = Self.commas(in: pendingAlias)
        var rest = pendingAlias
        if commas > keptCommas {
            var parts = pendingAlias.components(separatedBy: ",")
            rest = parts.removeLast()
            parts.forEach { add($0) }
            keptCommas = 0
        } else {
            keptCommas = commas
        }
        let trimmed = String(rest.drop(while: \.isWhitespace))
        if trimmed != pendingAlias { pendingAlias = trimmed }
    }

    mutating func commitPendingAlias() {
        add(pendingAlias)
        pendingAlias = ""
        keptCommas = 0
    }

    mutating func removeAlias(at index: Int) {
        aliases.remove(at: index)
    }

    /// Turns a finished spelling back into text, first finishing whatever was being typed.
    mutating func reopenAlias(at index: Int) {
        let alias = aliases.remove(at: index)
        commitPendingAlias()
        pendingAlias = alias
        keptCommas = Self.commas(in: alias)
    }

    private static func commas(in text: String) -> Int { text.filter { $0 == "," }.count }

    private mutating func add(_ alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !aliases.contains(where: { Array($0.utf16) == Array(trimmed.utf16) }) else { return }
        aliases.append(trimmed)
    }

    /// The other rule this one would join by having the same target.
    func existingTarget(in rules: [DictionaryRule]) -> DictionaryRule? {
        let target = Array(rule.target.utf16)
        return rules.first { $0.id != ruleID && Array($0.target.utf16) == target }
    }

    /// A spelling that a rule other than this one, or the one it would join, already replaces.
    func conflict(in rules: [DictionaryRule]) -> (alias: String, owner: DictionaryRule)? {
        let joined = existingTarget(in: rules)?.id
        for alias in rule.aliases {
            let units = Array(alias.utf16)
            if let owner = rules.first(where: { other in
                other.id != ruleID && other.id != joined && other.aliases.contains { Array($0.utf16) == units }
            }) {
                return (alias, owner)
            }
        }
        return nil
    }

    func isComplete(in rules: [DictionaryRule]) -> Bool {
        let rule = rule
        return !rule.target.isEmpty && !rule.aliases.isEmpty && conflict(in: rules) == nil
    }

    /// Targets with a word starting with what is typed, for joining an existing rule.
    func suggestions(in rules: [DictionaryRule], limit: Int = 4) -> [DictionaryRule] {
        let query = rule.target
        guard !query.isEmpty, query != originalTarget, existingTarget(in: rules) == nil else { return [] }
        return Array(rules.filter { $0.id != ruleID && Self.anyWord(of: $0.target, startsWith: query) }
            .sorted { $0.target.localizedStandardCompare($1.target) == .orderedAscending }
            .prefix(limit))
    }

    private static func anyWord(of text: String, startsWith query: String) -> Bool {
        var rest = Substring(text)
        while true {
            if rest.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { return true }
            guard let space = rest.firstIndex(where: \.isWhitespace) else { return false }
            rest = rest[space...].drop(while: \.isWhitespace)
        }
    }
}

struct DictionaryError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
