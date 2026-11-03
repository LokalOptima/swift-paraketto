import AppKit
import SwiftUI

enum TranscriptDictionaryAction {
    case add(String)
    case edit(UUID)
    case remove(UUID, String)
}

/// What layout says about a transcript at one width. It is worth keeping: SwiftUI asks far
/// more often than this changes, and its cost grows with the length of the transcript.
struct TranscriptLayout {
    let text: NSAttributedString
    let fullHeight: CGFloat
    let collapsedHeight: CGFloat
    let collapsed: (text: NSAttributedString, sourceLength: Int)

    init(_ result: ReplacementResult, width: CGFloat) {
        text = TranscriptText.attributed(result)
        fullHeight = TranscriptText.height(text, width: width, lines: 0)
        collapsedHeight = TranscriptText.height(text, width: width, lines: 4)
        collapsed = TranscriptText.collapsedPresentation(text, width: width)
    }
}

/// What a row shows of a transcript, and where each shown stretch sits in `ReplacementResult.text`.
struct TranscriptPresentation {
    struct Segment {
        let shownLocation: Int
        let source: NSRange
    }

    let text: NSAttributedString
    let segments: [Segment]
    let height: CGFloat

    /// Nil when the range runs outside one stretch of the transcript, as across an inserted "…".
    func sourceRange(ofShown shown: NSRange) -> NSRange? {
        guard let segment = segments.first(where: {
            shown.location >= $0.shownLocation && NSMaxRange(shown) <= $0.shownLocation + $0.source.length
        }) else { return nil }
        return NSRange(location: segment.source.location + shown.location - segment.shownLocation, length: shown.length)
    }

    /// Where `ranges` of the transcript appear, clipped to what is shown.
    func shownRanges(of ranges: [NSRange]) -> [NSRange] {
        segments.flatMap { segment in
            ranges.compactMap { range in
                let visible = NSIntersectionRange(range, segment.source)
                guard visible.length > 0 else { return nil }
                return NSRange(location: segment.shownLocation + visible.location - segment.source.location, length: visible.length)
            }
        }
    }
}

/// Native selectable text exposes precise ranges for dictionary actions.
struct TranscriptText: NSViewRepresentable {
    let result: ReplacementResult
    let expanded: Bool
    let matches: [NSRange]
    @Binding var isTruncated: Bool
    let dictionaryAction: (TranscriptDictionaryAction, CGRect) -> Void

    func makeNSView(context: Context) -> DictionaryTextView {
        // Search highlights are temporary layout attributes, which only TextKit 1 has.
        let view = DictionaryTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: DictionaryTextView, context: Context) {
        view.dictionaryAction = dictionaryAction
        // Before the first layout there is no width to wrap to. sizeThatFits configures the view then.
        guard view.bounds.width > 0 else { return }
        configure(view, width: view.bounds.width)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: DictionaryTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let layout = view.layout(of: result, width: width)
        let truncated = layout.fullHeight > layout.collapsedHeight + 0.5
        let shown = configure(view, width: width)
        view.measurementVersion += 1
        let version = view.measurementVersion
        DispatchQueue.main.async { [weak view] in
            guard view?.measurementVersion == version else { return }
            if isTruncated != truncated { isTruncated = truncated }
        }
        return CGSize(width: width, height: shown.height)
    }

    @discardableResult
    private func configure(_ view: DictionaryTextView, width: CGFloat) -> TranscriptPresentation {
        let shown = Self.presentation(of: view.layout(of: result, width: width), matches: matches, expanded: expanded, width: width)
        view.result = result
        view.show(shown, highlighting: matches)
        view.textContainer?.maximumNumberOfLines = expanded ? 0 : 4
        view.textContainer?.lineBreakMode = .byTruncatingTail
        return shown
    }

    /// Everything, the first four lines, or excerpts when those lines would hide a search match.
    static func presentation(of layout: TranscriptLayout, matches: [NSRange], expanded: Bool, width: CGFloat) -> TranscriptPresentation {
        guard !expanded else {
            return TranscriptPresentation(text: layout.text, segments: [.init(shownLocation: 0, source: NSRange(location: 0, length: layout.text.length))],
                                          height: layout.fullHeight)
        }
        let visible = layout.collapsed.sourceLength
        guard let last = matches.last, NSMaxRange(last) > visible else {
            return TranscriptPresentation(text: layout.collapsed.text, segments: [.init(shownLocation: 0, source: NSRange(location: 0, length: visible))],
                                          height: layout.collapsedHeight)
        }
        // A little under what the first four lines hold, as inserted separators can end a line early.
        let stretches = TextSearch.excerpt(of: layout.text.string, around: matches, capacity: visible * 9 / 10)
        let text = NSMutableAttributedString()
        let marker = { (string: String) in
            NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                                            .foregroundColor: NSColor.secondaryLabelColor])
        }
        var segments: [TranscriptPresentation.Segment] = []
        for (index, stretch) in stretches.enumerated() {
            if index > 0 { text.append(marker(" … ")) } else if stretch.location > 0 { text.append(marker("… ")) }
            segments.append(.init(shownLocation: text.length, source: stretch))
            text.append(layout.text.attributedSubstring(from: stretch))
        }
        if let end = stretches.last.map(NSMaxRange), end < layout.text.length { text.append(marker(" …")) }
        return TranscriptPresentation(text: text, segments: segments, height: height(text, width: width, lines: 4))
    }

    /// TextKit does not draw an ellipsis when the next paragraph is outside the line cap.
    /// Append one explicitly in that case, keeping all visible source offsets unchanged.
    static func collapsedPresentation(_ text: NSAttributedString, width: CGFloat) -> (text: NSAttributedString, sourceLength: Int) {
        withLayout(of: text, width: width, lines: 4) { layout, container in
            let glyphs = layout.glyphRange(for: container)
            guard glyphs.length > 0 else { return (text, 0) }
            let truncated = layout.truncatedGlyphRange(inLineFragmentForGlyphAt: NSMaxRange(glyphs) - 1)
            if truncated.location != NSNotFound {
                return (text, layout.characterIndexForGlyph(at: truncated.location))
            }
            let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard NSMaxRange(characters) < text.length else { return (text, text.length) }
            var end = NSMaxRange(characters)
            let string = text.string as NSString
            if end > 0, string.character(at: end - 1) == 10 { end -= 1 }
            if end > 0, string.character(at: end - 1) == 13 { end -= 1 }
            let preview = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: 0, length: end)))
            preview.append(NSAttributedString(string: "…", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                                                      .foregroundColor: NSColor.labelColor]))
            return (preview, end)
        }
    }

    static func attributed(_ result: ReplacementResult) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: result.text.isEmpty ? "No speech detected" : result.text,
                                                    attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                                                 .foregroundColor: NSColor.labelColor])
        for edit in result.replacements {
            attributed.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                      .underlineColor: NSColor.systemTeal,
                                      .toolTip: "Replaced “\(edit.alias)”. Right-click to edit it."], range: edit.outputRange)
        }
        return attributed
    }

    static func height(_ text: NSAttributedString, width: CGFloat, lines: Int) -> CGFloat {
        withLayout(of: text, width: width, lines: lines) { layout, container in
            ceil(max(layout.usedRect(for: container).height, NSFont.systemFontSize + 3))
        }
    }

    /// A layout manager doesn't keep its text storage alive, so the storage has to outlive `body`.
    private static func withLayout<Result>(of text: NSAttributedString, width: CGFloat, lines: Int,
                                           _ body: (NSLayoutManager, NSTextContainer) -> Result) -> Result {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = lines
        container.lineBreakMode = .byTruncatingTail
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return withExtendedLifetime(storage) { body(layout, container) }
    }
}

final class DictionaryTextView: NSTextView {
    var result = ReplacementResult(original: "", text: "", replacements: [])
    var dictionaryAction: ((TranscriptDictionaryAction, CGRect) -> Void)?
    var measurementVersion = 0
    /// Maps what is shown back to `result`. Without one, the shown text is the transcript itself.
    private(set) var presentation: TranscriptPresentation?
    private var layouts: (result: ReplacementResult, byWidth: [CGFloat: TranscriptLayout])?
    private var shownHighlights: [NSRange] = []

    func layout(of result: ReplacementResult, width: CGFloat) -> TranscriptLayout {
        if layouts?.result != result { layouts = (result, [:]) }
        if let cached = layouts?.byWidth[width] { return cached }
        let layout = TranscriptLayout(result, width: width)
        layouts?.byWidth[width] = layout
        return layout
    }

    /// Highlights are drawn over the text rather than stored in it, so Copy doesn't carry them,
    /// layout doesn't slow down with them, and a new search keeps the selection.
    func show(_ shown: TranscriptPresentation, highlighting matches: [NSRange]) {
        presentation = shown
        let textChanged = textStorage?.isEqual(to: shown.text) != true
        if textChanged {
            textStorage?.setAttributedString(shown.text)
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        let highlights = shown.shownRanges(of: matches)
        guard textChanged || highlights != shownHighlights, let layoutManager else { return }
        let everything = NSRange(location: 0, length: shown.text.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: everything)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: everything)
        // Black on the yellow find color stays readable in both light and dark appearance.
        let highlight: [NSAttributedString.Key: Any] = [.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black]
        for range in highlights { layoutManager.addTemporaryAttributes(highlight, forCharacterRange: range) }
        shownHighlights = highlights
    }

    private func sourceRange(ofShown range: NSRange) -> NSRange? {
        presentation.map { $0.sourceRange(ofShown: range) } ?? range
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let layoutManager, let textContainer else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        var clickedIndex: Int?
        if glyph < layoutManager.numberOfGlyphs {
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            let truncated = layoutManager.truncatedGlyphRange(inLineFragmentForGlyphAt: glyph)
            if rect.contains(point), !NSLocationInRange(glyph, truncated) {
                clickedIndex = layoutManager.characterIndexForGlyph(at: glyph)
            }
        }
        if let clickedIndex, !NSLocationInRange(clickedIndex, selectedRange()) {
            setSelectedRange(selectionRange(forProposedRange: NSRange(location: clickedIndex, length: 0), granularity: .selectByWord))
        }
        return dictionaryMenu(clickedIndex: clickedIndex)
    }

    /// Kept separate from hit testing so selection safety is also regression-tested.
    func dictionaryMenu(clickedIndex: Int?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = selectedRange().length > 0
        menu.addItem(copy)
        menu.addItem(.separator())
        let source = sourceRange(ofShown: selectedRange()).flatMap(result.originalSelection)
        let add = item("Add to dictionary…", action: source.map(TranscriptDictionaryAction.add))
        add.isEnabled = source?.isEmpty == false
        if !add.isEnabled { add.toolTip = "Select original text or a complete replacement." }
        menu.addItem(add)
        if let index = clickedIndex, let clicked = sourceRange(ofShown: NSRange(location: index, length: 1)),
           let replacement = result.replacements.first(where: { NSLocationInRange(clicked.location, $0.outputRange) }) {
            menu.addItem(.separator())
            menu.addItem(item("Edit replacement…", action: .edit(replacement.ruleID)))
            menu.addItem(item("Remove this spelling", action: .remove(replacement.ruleID, replacement.alias)))
        }
        return menu
    }

    private func item(_ title: String, action: TranscriptDictionaryAction?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performDictionaryAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        return item
    }

    @objc private func performDictionaryAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? TranscriptDictionaryAction else { return }
        dictionaryAction?(action, selectionFrame)
    }

    /// Where the selected text sits in this view, for attaching the dictionary editor to it.
    private var selectionFrame: CGRect {
        guard let layoutManager, let textContainer else { return bounds }
        let glyphs = layoutManager.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }
}
