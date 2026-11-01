import AppKit
import XCTest
@testable import ParakettoKit

final class DictionaryTests: XCTestCase {
    private func rule(_ alias: String, _ target: String) -> DictionaryRule {
        DictionaryRule(target: target, aliases: [alias])
    }

    func testLiteralCaseSensitiveAliasesAndNoImplicitTarget() {
        let matcher = DictionaryMatcher(rules: [rule("you ess", "US"), rule("café", "coffee"), rule("gee tub", "github")])
        let source = "Please send us You Ess you ess US café cafe\u{301} gee  tub gee tub"
        let expected = "Please send us You Ess US US coffee cafe\u{301} gee  tub github"
        XCTAssertEqual(Array(matcher.apply(to: source).text.utf16), Array(expected.utf16))
    }

    func testPunctuationAfterAnAliasMatches() {
        let matcher = DictionaryMatcher(rules: [rule("gee tub", "github")])
        let source = "gee tub gee tub, (gee tub); gee tub. gee tub! gee tub? ‘gee tub’ gee tub: gee,tub xgee tub gee tub_x\ngee tub\tgee tub"
        XCTAssertEqual(matcher.apply(to: source).text,
                       "github github, (gee tub); github. github! github? ‘gee tub’ gee tub: gee,tub xgee tub gee tub_x\ngithub\tgithub")
        XCTAssertEqual(matcher.apply(to: "\u{a0}gee tub\u{2003}").text, "\u{a0}github\u{2003}")
        XCTAssertEqual(matcher.apply(to: "gee tub' gee tub\" gee tub?! gee tub.\" gee tub) gee tub’ gee tub”").text,
                       "github' github\" github?! github.\" github) github’ github”")
        XCTAssertEqual(DictionaryMatcher(rules: [rule("pulp size", "pop. size")]).apply(to: "the pulp size.").text, "the pop. size.")
        XCTAssertEqual(DictionaryMatcher(rules: [rule("blah blah,", "BLAH")]).apply(to: "blah blah, next blah blah.").text,
                       "BLAH next blah blah.")
    }

    func testPunctuationMustEndTheWord() {
        let matcher = DictionaryMatcher(rules: [rule("don", "X"), rule("it", "X"), rule("3", "X"), rule("gee tub", "X")])
        let untouched = "don't it's 3.5 gee tub's gee tub,next gee tub.next"
        XCTAssertEqual(matcher.apply(to: untouched).text, untouched)
    }

    @MainActor
    func testDictionariesWithTheOldPunctuationOptionStillLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        try Data(#"[{"id":"\#(id.uuidString)","target":"pop. size","aliases":["pulp size"],"allowsPunctuation":false}]"#.utf8).write(to: url)
        let store = DictionaryStore(url: url)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.rules, [DictionaryRule(id: id, target: "pop. size", aliases: ["pulp size"])])
    }

    func testAddressesAndPathsAreProtectedEvenWithPunctuation() {
        let protected = [
            "us@example.com", "person@us.example", "first.us@example.com", "<us@example.com>",
            "https://us.example/us?q=us#us", "https://example.com/(us);us?x=us#us", "www.us.example",
            "us.example", "us.local", "http://localhost/us", "mailto:us@example.com", "ftp://us.example/us",
            "file:///tmp/us", "/tmp/us.txt", "../us", "C:\\us\\file", "us@example.invalid",
            "us.例子", "us.Example", "us@example.com,us", "https://example.com?q=(us)",
            "\"hello us, world\"@example.com", "urn:example;(us)", "data:text/plain,us", "name+us@example.com", "https://example.com/path;us", "https://example.com/#(us)",
        ]
        let matcher = DictionaryMatcher(rules: [rule("us", "US"), rule("example", "EXAMPLE")])
        for text in protected { XCTAssertEqual(matcher.apply(to: text).text, text, text) }
        // A multiword alias must not swallow part of a protected token.
        XCTAssertEqual(DictionaryMatcher(rules: [rule("hello us", "X")])
            .apply(to: "hello us.example").text, "hello us.example")
        XCTAssertEqual(DictionaryMatcher(rules: [rule("us", "US")])
            .apply(to: "(us), us. us; us").text, "(us), US. US; US")
    }

    func testLongestEligibleLeftmostAndNoCascade() {
        let matcher = DictionaryMatcher(rules: [rule("a", "b"), rule("a b", "long"), rule("b", "c")])
        XCTAssertEqual(matcher.apply(to: "a b a bx, a").text, "long b bx, b")
        let overlapping = DictionaryMatcher(rules: [rule("a b", "first"), rule("b c", "second")])
        XCTAssertEqual(overlapping.apply(to: "a b c").text, "first c")
    }

    func testSelectionMappingAndHighlightsWithUnicodeAndLengthChanges() throws {
        let matcher = DictionaryMatcher(rules: [rule("gee tub", "github"), rule("yo", "🦜 café"), rule("long word", "x")])
        let result = matcher.apply(to: "🦜 gee tub and yo long word end")
        XCTAssertEqual(result.text, "🦜 github and 🦜 café x end")
        XCTAssertEqual(result.replacements.count, 3)
        let text = result.text as NSString
        for edit in result.replacements {
            XCTAssertEqual(result.originalSelection(edit.outputRange), edit.alias)
            XCTAssertEqual((result.original as NSString).substring(with: edit.originalRange), edit.alias)
            XCTAssertNotEqual(text.substring(with: edit.outputRange), edit.alias)
        }
        XCTAssertEqual(result.originalSelection(text.range(of: " github and 🦜 café x ")), "gee tub and yo long word")
        XCTAssertEqual(result.originalSelection(text.range(of: " end")), "end")
        XCTAssertNil(result.originalSelection(text.range(of: "hub")))
        XCTAssertNil(result.originalSelection(text.range(of: "🦜 ca")))
        XCTAssertNil(result.originalSelection(NSRange(location: 200, length: 2)))
        XCTAssertNil(result.originalSelection(NSRange(location: NSNotFound, length: 1)))
    }

    func testGeneratedEditsRoundTripExactlyAndDoNotDependOnRuleOrder() {
        let rules = [rule("gee tub", "GitHub"), rule("yo", "🦜 café"),
                     rule("a", "b"), rule("a b", "long"),
                     rule("é", "one"), rule("e\u{301}", "two")]
        let forward = DictionaryMatcher(rules: rules)
        let reverse = DictionaryMatcher(rules: rules.reversed())
        let pieces = ["gee tub", "gee tub,", "yo", "a", "a b", "é", "e\u{301}", "🦜",
                      "https://example.com/(a)", "a@example.com", "(a)", "unmatched"]
        var seed: UInt64 = 42
        func next(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int(seed >> 32) % count
        }
        for _ in 0..<250 {
            let original = (0..<20).map { _ in pieces[next(pieces.count)] }.joined(separator: " ")
            let result = forward.apply(to: original)
            XCTAssertEqual(Array(result.text.utf16), Array(reverse.apply(to: original).text.utf16))
            let restored = NSMutableString(string: result.text)
            for edit in result.replacements.reversed() {
                restored.replaceCharacters(in: edit.outputRange, with: edit.alias)
                XCTAssertEqual(Array(result.originalSelection(edit.outputRange)!.utf16), Array(edit.alias.utf16))
            }
            XCTAssertEqual(Array((restored as String).utf16), Array(original.utf16))
            XCTAssertEqual(Array(result.originalSelection(NSRange(location: 0, length: (result.text as NSString).length))!.utf16),
                           Array(original.utf16))
        }
    }

    @MainActor
    func testValidationPersistenceAndFailedWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("dictionary.json")
        let store = DictionaryStore(url: url)
        XCTAssertNil(store.loadError)
        var entry = rule("gee tub", "github")
        try store.save(entry)
        XCTAssertEqual(DictionaryStore(url: url).rules, [entry])
        XCTAssertThrowsError(try store.save(rule("gee tub", "different")))
        XCTAssertThrowsError(try store.save(rule("other", "github")))
        XCTAssertThrowsError(try store.save(rule("", "empty")))
        XCTAssertEqual(store.rules, [entry])
        entry.aliases.append("git hub")
        try store.save(entry)
        try store.removeAlias("gee tub", from: entry.id)
        XCTAssertEqual(store.rules.first?.aliases, ["git hub"])
        try store.removeAlias("git hub", from: entry.id)
        XCTAssertTrue(store.rules.isEmpty)
        // Canonically equivalent but byte-distinct aliases remain distinct.
        try store.save(rule("é", "one"))
        try store.save(rule("e\u{301}", "two"))
        XCTAssertEqual(store.rules.count, 2)
        // A corrupt file cannot be overwritten with an empty dictionary.
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: url)
        let broken = DictionaryStore(url: url)
        XCTAssertNotNil(broken.loadError)
        XCTAssertThrowsError(try broken.save(entry))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        // Turn the destination into a directory to provoke an atomic-write failure.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let before = store.rules
        XCTAssertThrowsError(try store.save(entry))
        XCTAssertEqual(store.rules, before)
    }

    @MainActor
    func testAllHistoryReprocessesFromOriginalWithoutChangingStoredTextOrAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dictionary = DictionaryStore(url: root.appendingPathComponent("dictionary.json"))
        let history = HistoryStore(directory: root.appendingPathComponent("history"), dictionary: dictionary)
        let recording = try RecordingFile()
        try recording.append([0.1, 0.2, 0.3])
        let entry = HistoryEntry(id: UUID(), date: Date(), text: "gee tub, gee tub", destination: "Example",
                                 duration: 1, inferenceMilliseconds: 1, delivery: .pasted)
        try history.add(entry, recording: recording)
        let json = history.directory.appendingPathComponent("\(entry.id.uuidString).json")
        let originalJSON = try Data(contentsOf: json)
        let originalAudio = try Data(contentsOf: history.audioURL(for: entry))
        var replacement = rule("gee tub", "github")
        try dictionary.save(replacement)
        XCTAssertEqual(history.entries.first?.displayText, "github, github")
        replacement.target = "GitHub"
        try dictionary.save(replacement)
        XCTAssertEqual(history.entries.first?.displayText, "GitHub, GitHub")
        XCTAssertEqual(history.entries.first?.text, entry.text)
        let reloaded = HistoryStore(directory: history.directory, dictionary: DictionaryStore(url: dictionary.url))
        XCTAssertEqual(reloaded.entries.first?.displayText, "GitHub, GitHub")
        try dictionary.remove(id: replacement.id)
        XCTAssertEqual(history.entries.first?.displayText, entry.text)
        XCTAssertEqual(try Data(contentsOf: json), originalJSON)
        XCTAssertEqual(try Data(contentsOf: history.audioURL(for: entry)), originalAudio)
        try history.updateDelivery(id: entry.id, to: .copied)
        let delivered = try JSONDecoder().decode(HistoryEntry.self, from: Data(contentsOf: json))
        XCTAssertEqual(delivered.text, entry.text)
        XCTAssertEqual(delivered.delivery, .copied)
        XCTAssertEqual(try Data(contentsOf: history.audioURL(for: entry)), originalAudio)
    }

    @MainActor
    func testNativeTextLayoutAndContextMenus() throws {
        let result = DictionaryMatcher(rules: [rule("gee tub", "github")]).apply(to: "gee tub then text")
        let view = DictionaryTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.result = result
        view.textStorage?.setAttributedString(TranscriptText.attributed(result))
        view.setSelectedRange(NSRange(location: 0, length: 6))
        let menu = view.dictionaryMenu(clickedIndex: 0)
        XCTAssertEqual(menu.items.map(\.title).filter { !$0.isEmpty }, ["Copy", "Add to dictionary…", "Edit rule…", "Remove this alias"])
        let add = try XCTUnwrap(menu.items.first { $0.title == "Add to dictionary…" })
        guard case .add(let source) = add.representedObject as? TranscriptDictionaryAction else { return XCTFail("Missing action") }
        XCTAssertEqual(source, "gee tub")
        view.setSelectedRange(NSRange(location: 1, length: 2))
        XCTAssertFalse(try XCTUnwrap(view.dictionaryMenu(clickedIndex: 1).items.first { $0.title == "Add to dictionary…" }).isEnabled)
        let long = TranscriptText.attributed(ReplacementResult(original: "", text: String(repeating: "A long transcript with words. ", count: 30), replacements: []))
        let collapsed = TranscriptText.height(long, width: 300, lines: 4)
        let full = TranscriptText.height(long, width: 300, lines: 0)
        XCTAssertGreaterThan(full, collapsed * 2)
        XCTAssertLessThan(collapsed, 85)
        XCTAssertLessThan(TranscriptText.height(long, width: 600, lines: 0), full)
        let multiline = NSAttributedString(string: "One\nTwo\nThree\nFour\nFive", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        let preview = TranscriptText.collapsedPresentation(multiline, width: 300)
        XCTAssertEqual(preview.0.string, "One\nTwo\nThree\nFour…")
        XCTAssertEqual(preview.1, ("One\nTwo\nThree\nFour" as NSString).length)

    }
}
