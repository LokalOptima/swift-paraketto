import AppKit
import XCTest
@testable import ParakettoKit

@MainActor
final class TranscriptSearchTests: XCTestCase {
    func testASingleCharacterIsNotSearchedFor() {
        XCTAssertEqual(TextSearch.term(in: ""), "")
        XCTAssertEqual(TextSearch.term(in: "a"), "")
        XCTAssertEqual(TextSearch.term(in: "  a \n"), "")
        XCTAssertEqual(TextSearch.term(in: "é"), "")
        XCTAssertEqual(TextSearch.term(in: "e\u{301}"), "", "A base letter and its accent are one character")
    }

    func testSearchStartsAtTwoCharacters() {
        XCTAssertEqual(TextSearch.term(in: "ab"), "ab")
        XCTAssertEqual(TextSearch.term(in: "  ab \n"), "ab")
        XCTAssertEqual(TextSearch.term(in: "a b"), "a b")
    }

    func testMatchesIgnoreCaseAndAccents() {
        let matches = TextSearch.matches(of: "cafe", in: "Café, CAFE and cafeteria")
        XCTAssertEqual(matches.map(\.location), [0, 6, 15])
        XCTAssertEqual(matches.map(\.length), [4, 4, 4])
        XCTAssertEqual(TextSearch.matches(of: "CAFÉ", in: "cafe").count, 1)
    }

    func testMatchesFoldStrokedLettersWithoutMovingRanges() {
        XCTAssertEqual(TextSearch.matches(of: "wroclaw", in: "Wrocław"), [NSRange(location: 0, length: 7)])
        XCTAssertEqual(TextSearch.matches(of: "lodz", in: "w Łódź"), [NSRange(location: 2, length: 4)])
        XCTAssertEqual(TextSearch.matches(of: "københavn", in: "Kobenhavn").count, 1)
        XCTAssertEqual(TextSearch.matches(of: "dakovo", in: "😀 Đakovo"), [NSRange(location: 3, length: 6)])
    }

    func testMatchesAreUTF16RangesThatDoNotOverlap() {
        XCTAssertEqual(TextSearch.matches(of: "word", in: "😀 word"), [NSRange(location: 3, length: 4)])
        XCTAssertEqual(TextSearch.matches(of: "aa", in: "aaaaa").map(\.location), [0, 2])
    }

    func testQueriesThatFindNothingEnd() {
        XCTAssertTrue(TextSearch.matches(of: "", in: "text").isEmpty)
        XCTAssertTrue(TextSearch.matches(of: "zebra", in: "text").isEmpty)
        XCTAssertTrue(TextSearch.matches(of: "text", in: "").isEmpty)
        // This mark matches an empty range, which would loop forever if it counted as a match.
        XCTAssertTrue(TextSearch.matches(of: "\u{900}", in: "some text").isEmpty)
    }

    // MARK: Excerpts

    private static let numbers = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen"

    private func excerpt(of text: String, around queries: [String], capacity: Int = 1000, context: Int = 12) -> [String] {
        let matches = queries.flatMap { TextSearch.matches(of: $0, in: text) }.sorted { $0.location < $1.location }
        return TextSearch.excerpt(of: text, around: matches, capacity: capacity, context: context)
            .map { (text as NSString).substring(with: $0) }
    }

    func testExcerptKeepsWholeWordsAroundAMatch() {
        XCTAssertEqual(excerpt(of: Self.numbers, around: ["eight"]), ["six seven eight nine ten"])
    }

    func testExcerptSeparatesDistantMatchesAndJoinsNearbyOnes() {
        XCTAssertEqual(excerpt(of: Self.numbers, around: ["seven", "fifteen"], context: 6), ["six seven", "fifteen"])
        XCTAssertEqual(excerpt(of: Self.numbers, around: ["seven", "nine"]), ["five six seven eight nine ten eleven"])
    }

    func testExcerptJoinsStretchesThatOnlyWhitespaceSeparates() {
        // With this context the first stretch ends at "delta" and the second starts at "echo".
        let text = "needle alpha bravo charlie delta echo foxtrot golf hotel india needle"
        XCTAssertEqual(excerpt(of: text, around: ["needle"], context: 31), [text])
    }

    func testExcerptSamplesMatchesAcrossTheTranscript() {
        let text = String(repeating: "needle in a very long haystack of words that go on and on. ", count: 500)
        let matches = TextSearch.matches(of: "needle", in: text)
        XCTAssertEqual(matches.count, 500)
        let stretches = TextSearch.excerpt(of: text, around: matches, capacity: 300)
        XCTAssertEqual(stretches.count, 4)
        XCTAssertEqual(stretches.first?.location, 0)
        XCTAssertTrue(NSLocationInRange(matches[499].location, stretches[3]))
        XCTAssertLessThanOrEqual(stretches.reduce(0) { $0 + $1.length }, 300)
    }

    func testExcerptNeverSplitsACharacter() {
        let emoji = String(repeating: "😀", count: 60)
        let text = emoji + "needle" + emoji
        for context in 19...24 {
            let matches = TextSearch.matches(of: "needle", in: text)
            let shown = TextSearch.excerpt(of: text, around: matches, capacity: 400, context: context)
                .map { (text as NSString).substring(with: $0) }
            XCTAssertTrue(shown[0].contains("needle"))
            XCTAssertFalse(shown[0].unicodeScalars.contains("\u{FFFD}"))
        }
    }

    // MARK: What a row shows

    /// A long transcript whose only replacement and rare word are past the fourth line.
    private static let long: ReplacementResult = {
        let filler = String(repeating: "This sentence only exists to fill the first lines of the row. ", count: 20)
        let rule = DictionaryRule(target: "GitHub", aliases: ["gee tub"])
        return DictionaryMatcher(rules: [rule]).apply(to: filler + "We moved the quarterly budget to gee tub today. " + filler)
    }()

    private func presentation(of result: ReplacementResult = TranscriptSearchTests.long, query: String,
                              expanded: Bool = false, width: CGFloat = 496) -> (TranscriptPresentation, [NSRange]) {
        let matches = TextSearch.matches(of: query, in: result.text)
        let layout = TranscriptLayout(result, width: width)
        return (TranscriptText.presentation(of: layout, matches: matches, expanded: expanded, width: width), matches)
    }

    func testShortTranscriptsAndVisibleMatchesStayAsTheyAre() {
        let short = ReplacementResult(original: "a short note", text: "a short note", replacements: [])
        let (shown, _) = presentation(of: short, query: "short")
        XCTAssertEqual(shown.text.string, "a short note")

        let text = "A needle on the first line. " + String(repeating: "Then many more words follow it. ", count: 50)
        let early = ReplacementResult(original: text, text: text, replacements: [])
        let (collapsed, matches) = presentation(of: early, query: "needle")
        XCTAssertEqual(collapsed.segments.count, 1)
        XCTAssertEqual(collapsed.shownRanges(of: matches), matches)

        XCTAssertEqual(presentation(query: "This sentence", expanded: true).0.text.string, Self.long.text)
    }

    func testExcerptRevealsAHiddenMatchAndMapsBackToTheTranscript() throws {
        let (shown, matches) = presentation(query: "budget")
        let string = shown.text.string as NSString
        XCTAssertTrue(string.hasPrefix("… "))
        XCTAssertTrue(string.hasSuffix(" …"))
        let highlight = try XCTUnwrap(shown.shownRanges(of: matches).first)
        XCTAssertEqual(string.substring(with: highlight), "budget")
        XCTAssertEqual(shown.sourceRange(ofShown: highlight), matches[0])
        XCTAssertNil(shown.sourceRange(ofShown: NSRange(location: 0, length: 1)), "The inserted marker has no source")
    }

    func testExcerptKeepsReplacementUnderlines() throws {
        let (shown, _) = presentation(query: "budget")
        let location = (shown.text.string as NSString).range(of: "GitHub").location
        XCTAssertNotEqual(location, NSNotFound)
        XCTAssertNotNil(shown.text.attribute(.underlineStyle, at: location, effectiveRange: nil))
    }

    func testExcerptsFitInFourLinesAtAnyWidth() {
        let text = (1...40).map { "Sentence number \($0) has a word in it, and then a few more words after that." }.joined(separator: " ")
        let result = ReplacementResult(original: text, text: text, replacements: [])
        for width in stride(from: 300 as CGFloat, through: 1200, by: 100) {
            for query in ["word", "number 40", "Sentence", "e"] {
                let (shown, _) = presentation(of: result, query: query, width: width)
                XCTAssertEqual(TranscriptText.height(shown.text, width: width, lines: 0), shown.height,
                               "\(query) at \(width) was clipped")
            }
        }
    }

    func testAnInsertedMarkerIsNeverHighlighted() {
        let text = String(repeating: "This sentence only fills the row. ", count: 30) + "He paused… and went on. " + String(repeating: "More words here. ", count: 30)
        let (shown, matches) = presentation(of: ReplacementResult(original: text, text: text, replacements: []), query: "…")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(shown.shownRanges(of: matches).count, 1)
    }

    // MARK: The text view

    private func textView(showing shown: TranscriptPresentation, matches: [NSRange]) -> DictionaryTextView {
        let view = DictionaryTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: 496, height: 200)
        view.isRichText = true
        view.result = Self.long
        view.show(shown, highlighting: matches)
        return view
    }

    func testHighlightIsDrawnButNotPartOfTheText() throws {
        let (shown, matches) = presentation(query: "budget")
        let view = textView(showing: shown, matches: matches)
        let highlight = try XCTUnwrap(shown.shownRanges(of: matches).first)
        let layoutManager = try XCTUnwrap(view.layoutManager)
        XCTAssertNotNil(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: highlight.location, effectiveRange: nil))
        XCTAssertNil(view.textStorage?.attribute(.backgroundColor, at: highlight.location, effectiveRange: nil))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.lfrati.paraketto.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        view.setSelectedRange(highlight)
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        let rtf = try XCTUnwrap(pasteboard.data(forType: .rtf))
        let copied = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(copied.string, "budget")
        XCTAssertNil(copied.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testANewSearchKeepsTheSelectionAndMovesTheHighlight() throws {
        let text = "alpha beta gamma"
        let result = ReplacementResult(original: text, text: text, replacements: [])
        let (first, firstMatches) = presentation(of: result, query: "alpha")
        let view = textView(showing: first, matches: firstMatches)
        view.setSelectedRange(NSRange(location: 6, length: 4))

        let (second, secondMatches) = presentation(of: result, query: "gamma")
        view.show(second, highlighting: secondMatches)
        let layoutManager = try XCTUnwrap(view.layoutManager)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 4))
        XCTAssertNil(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
        XCTAssertNotNil(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 11, effectiveRange: nil))
    }

    func testDictionaryActionsWorkInExcerpts() throws {
        let (shown, matches) = presentation(query: "budget")
        let view = textView(showing: shown, matches: matches)
        let location = (shown.text.string as NSString).range(of: "GitHub").location

        view.setSelectedRange(NSRange(location: location, length: 6))
        let menu = view.dictionaryMenu(clickedIndex: location)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Edit replacement…"))
        XCTAssertTrue(titles.contains("Remove this spelling"))
        let add = try XCTUnwrap(menu.items.first { $0.title == "Add to dictionary…" })
        XCTAssertTrue(add.isEnabled)
        guard case .add(let source) = add.representedObject as? TranscriptDictionaryAction else { return XCTFail("Missing action") }
        XCTAssertEqual(source, "gee tub")

        view.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertFalse(try XCTUnwrap(view.dictionaryMenu(clickedIndex: 0).items.first { $0.title == "Add to dictionary…" }).isEnabled,
                       "A selection that includes an inserted marker has no original text")
    }

    // MARK: Around dictation

    func testThisAppIsNowhereToPaste() throws {
        XCTAssertNil(Destination(application: .current))
        let other = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0 != .current && $0.localizedName != nil })
        XCTAssertEqual(Destination(application: other)?.name, other.localizedName)
    }

    func testEscapeBelongsToAFieldOnlyWhileItHoldsText() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        XCTAssertFalse(DictationController.escapeBelongsToField(editor))
        editor.string = "budget"
        XCTAssertTrue(DictationController.escapeBelongsToField(editor))
        XCTAssertFalse(DictationController.escapeBelongsToField(NSTextView()))
        XCTAssertFalse(DictationController.escapeBelongsToField(nil))
    }

    func testMeterDoesNotRepublishTheController() {
        let fixtures = PreviewFixtures(empty: true)
        var changes = 0
        let subscription = fixtures.controller.objectWillChange.sink { changes += 1 }
        fixtures.controller.showPreviewMeter(level: 0.5, elapsed: 1)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(fixtures.controller.meter.level, 0.5)
        subscription.cancel()
    }
}
