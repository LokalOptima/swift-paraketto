import AppKit
import SwiftUI

enum TranscriptDictionaryAction {
    case add(String)
    case edit(UUID)
    case remove(UUID, String)
}

/// Native selectable text exposes precise ranges for dictionary actions.
struct TranscriptText: NSViewRepresentable {
    let result: ReplacementResult
    let expanded: Bool
    @Binding var isTruncated: Bool
    let dictionaryAction: (TranscriptDictionaryAction) -> Void

    func makeNSView(context: Context) -> DictionaryTextView {
        let view = DictionaryTextView(frame: .zero)
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
        view.result = result
        view.dictionaryAction = dictionaryAction
        configure(view, width: max(1, view.bounds.width))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: DictionaryTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let attributed = Self.attributed(result)
        let full = Self.height(attributed, width: width, lines: 0)
        let collapsed = Self.height(attributed, width: width, lines: 4)
        let truncated = full > collapsed + 0.5
        configure(view, width: width)
        view.measurementVersion += 1
        let version = view.measurementVersion
        DispatchQueue.main.async { [weak view] in
            guard view?.measurementVersion == version else { return }
            if isTruncated != truncated { isTruncated = truncated }
        }
        return CGSize(width: width, height: expanded ? full : collapsed)
    }

    private func configure(_ view: DictionaryTextView, width: CGFloat) {
        let full = Self.attributed(result)
        let presentation = expanded ? (full, full.length) : Self.collapsedPresentation(full, width: width)
        view.selectableSourceLength = presentation.1
        if view.textStorage?.isEqual(to: presentation.0) != true {
            view.textStorage?.setAttributedString(presentation.0)
            view.setSelectedRange(NSRange(location: 0, length: 0))
        }
        view.textContainer?.maximumNumberOfLines = expanded ? 0 : 4
        view.textContainer?.lineBreakMode = .byTruncatingTail
    }

    /// TextKit does not draw an ellipsis when the next paragraph is outside the line cap.
    /// Append one explicitly in that case, keeping all visible source offsets unchanged.
    static func collapsedPresentation(_ text: NSAttributedString, width: CGFloat) -> (NSAttributedString, Int) {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 4
        container.lineBreakMode = .byTruncatingTail
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
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

    static func attributed(_ result: ReplacementResult) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: result.text.isEmpty ? "No speech detected" : result.text,
                                                    attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                                                 .foregroundColor: NSColor.labelColor])
        for edit in result.replacements {
            attributed.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                      .underlineColor: NSColor.systemTeal,
                                      .toolTip: "Replaced “\(edit.alias)”. Right-click to edit the rule."], range: edit.outputRange)
        }
        return attributed
    }

    static func height(_ text: NSAttributedString, width: CGFloat, lines: Int) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = lines
        container.lineBreakMode = .byTruncatingTail
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(max(layout.usedRect(for: container).height, NSFont.systemFontSize + 3))
    }
}

final class DictionaryTextView: NSTextView {
    var result = ReplacementResult(original: "", text: "", replacements: [])
    var dictionaryAction: ((TranscriptDictionaryAction) -> Void)?
    var measurementVersion = 0
    var selectableSourceLength = Int.max

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
        let source = NSMaxRange(selectedRange()) <= selectableSourceLength ? result.originalSelection(selectedRange()) : nil
        let add = item("Add to dictionary…", action: source.map(TranscriptDictionaryAction.add))
        add.isEnabled = source?.isEmpty == false
        if !add.isEnabled { add.toolTip = "Select original text or a complete replacement." }
        menu.addItem(add)
        if let index = clickedIndex,
           let replacement = result.replacements.first(where: { NSLocationInRange(index, $0.outputRange) }) {
            menu.addItem(.separator())
            menu.addItem(item("Edit rule…", action: .edit(replacement.ruleID)))
            menu.addItem(item("Remove this alias", action: .remove(replacement.ruleID, replacement.alias)))
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
        dictionaryAction?(action)
    }
}
