import AppKit
import SwiftUI

struct DictionaryDraft: Identifiable {
    let id = UUID()
    var rule: DictionaryRule
}

/// Edits one replacement inside a popover, so the transcript or list it came from stays in view.
struct DictionaryEditor: View {
    private enum Field { case aliases, target }

    @ObservedObject var store: DictionaryStore
    @State private var form: ReplacementForm
    @State private var selectedSuggestion: Int?
    @State private var error: String?
    @State private var isFinished = false
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    init(store: DictionaryStore, draft: DictionaryDraft) {
        self.store = store
        _form = State(initialValue: ReplacementForm(rule: draft.rule))
    }

    private var isAdding: Bool { !store.rules.contains { $0.id == form.ruleID } }
    private var isComplete: Bool { form.isComplete(in: store.rules) }
    private var conflict: (alias: String, owner: DictionaryRule)? { form.conflict(in: store.rules) }
    private var suggestions: [DictionaryRule] { focus == .target ? form.suggestions(in: store.rules) : [] }

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Form {
                LabeledContent("Replace:") { aliasField }
                LabeledContent("With:") { targetField }
                LabeledContent(" ") {
                    status
                        .font(.callout)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
                }
            }
            .formStyle(.columns)
            HStack {
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button(isAdding ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { focus = form.target.isEmpty && !form.aliases.isEmpty ? .target : .aliases }
        .onChange(of: focus) { old, _ in
            if old == .aliases { form.commitPendingAlias() }
        }
        .onChange(of: form) {
            error = nil
            selectedSuggestion = nil
        }
        // A popover closes itself on Esc before the Cancel button's shortcut can run.
        .onExitCommand { cancel() }
        .onDisappear { saveOnClose() }
    }

    private var aliasField: some View {
        OutlinedField(isFocused: focus == .aliases) {
            AliasFlowLayout {
                ForEach(Array(form.aliases.enumerated()), id: \.offset) { index, alias in
                    AliasChip(text: alias, isConflicting: alias == conflict?.alias) {
                        form.reopenAlias(at: index)
                        focus = .aliases
                    } remove: {
                        form.removeAlias(at: index)
                        focus = .aliases
                    }
                }
                TextField("Replace", text: $form.pendingAlias,
                          prompt: form.aliases.isEmpty ? Text("Separate spellings with commas") : Text(""))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .frame(height: 20)
                    .focused($focus, equals: .aliases)
                    // Not in a binding's setter: the field ignores text changed while it reports typing.
                    .onChange(of: form.pendingAlias) { form.finishTypedAliases() }
                    // The Delete key arrives as U+007F, which isn't SwiftUI's KeyEquivalent.delete.
                    .onKeyPress(KeyEquivalent("\u{7F}")) {
                        guard form.pendingAlias.isEmpty, !form.aliases.isEmpty else { return .ignored }
                        form.reopenAlias(at: form.aliases.count - 1)
                        return .handled
                    }
                    .onSubmit { submit() }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focus = .aliases }
    }

    private var targetField: some View {
        OutlinedField(isFocused: focus == .target) {
            TextField("With", text: $form.target, prompt: Text(""))
                .textFieldStyle(.plain)
                .labelsHidden()
                .frame(height: 20)
                .focused($focus, equals: .target)
                .onKeyPress(.tab) {
                    guard let suggestion = suggestions[safe: selectedSuggestion ?? 0] else { return .ignored }
                    choose(suggestion)
                    return .handled
                }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    guard !suggestions.isEmpty else { return .ignored }
                    let step = press.key == .downArrow ? 1 : suggestions.count - 1
                    selectedSuggestion = selectedSuggestion.map { ($0 + step) % suggestions.count }
                        ?? (press.key == .downArrow ? 0 : suggestions.count - 1)
                    return .handled
                }
                .onSubmit { submit() }
        }
        .contentShape(Rectangle())
        .onTapGesture { focus = .target }
    }

    @ViewBuilder private var status: some View {
        if let message = error ?? conflict.map({ "“\($0.alias)” already becomes \($0.owner.target)." }) {
            Text(message).foregroundStyle(.red)
        } else if !suggestions.isEmpty {
            HStack(spacing: 4) {
                Text("Existing:").foregroundStyle(.secondary).fixedSize().padding(.trailing, 2)
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    Button { choose(suggestion) } label: {
                        Text(suggestion.target)
                            .foregroundStyle(index == selectedSuggestion ? Color.white : Color.primary)
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(index == selectedSuggestion ? Color.accentColor : Color.primary.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add to \(suggestion.target)")
                }
            }
        } else if let existing = form.existingTarget(in: store.rules) {
            Text("Adds to \(existing.target): \(existing.aliases.joined(separator: "  ·  "))")
                .foregroundStyle(.secondary)
        } else {
            Text("Matches the exact spelling and case.").foregroundStyle(.secondary)
        }
    }

    private func choose(_ suggestion: DictionaryRule) {
        form.target = suggestion.target
        focus = .target
    }

    /// Return finishes one thing at a time and saves once nothing is left to finish.
    private func submit() {
        if let suggestion = selectedSuggestion.flatMap({ suggestions[safe: $0] }) {
            choose(suggestion)
        } else if !form.pendingAlias.isEmpty {
            form.commitPendingAlias()
            if form.rule.target.isEmpty { focus = .target }
        } else if form.rule.aliases.isEmpty {
            focus = .aliases
        } else if form.rule.target.isEmpty {
            focus = .target
        } else {
            save()
        }
    }

    private func save() {
        guard isComplete, !isFinished else { return }
        do {
            try store.saveMerging(form.rule)
            isFinished = true
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cancel() {
        isFinished = true
        dismiss()
    }

    /// Clicking away closes a popover. Complete work is kept, and only Cancel discards it.
    private func saveOnClose() {
        guard !isFinished, isComplete else { return }
        do {
            try store.saveMerging(form.rule)
        } catch {
            DispatchQueue.main.async { NSAlert(error: error).runModal() }
        }
    }
}

/// The outline shared by the editor's fields and the search fields.
struct OutlinedField<Content: View>: View {
    var isFocused = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isFocused ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
    }
}

/// The search box shared by the Transcripts and Dictionary tabs.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        OutlinedField {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(prompt, text: $text).textFieldStyle(.plain)
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).accessibilityLabel("Clear search")
                }
            }
            .frame(height: 20)
        }
    }
}

private struct AliasChip: View {
    let text: String
    let isConflicting: Bool
    let edit: () -> Void
    let remove: () -> Void
    @State private var isRemoveHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button { edit() } label: {
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 6)
                    .padding(.trailing, 3)
                    .frame(height: 20)
                    .contentShape(Rectangle())
            }
            .help("Edit spelling")
            .accessibilityLabel("Edit \(text)")
            Button { remove() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isRemoveHovered ? .primary : .secondary)
                    .frame(width: 15, height: 20)
                    .contentShape(Rectangle())
            }
            .onHover { isRemoveHovered = $0 }
            .help("Remove spelling")
            .accessibilityLabel("Remove \(text)")
        }
        .buttonStyle(.plain)
        .background(isConflicting ? Color.red.opacity(0.28) : Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Wraps chips onto new rows and gives the text field after them whatever its row has left.
private struct AliasFlowLayout: Layout {
    private let spacing: CGFloat = 4
    private let minimumFieldWidth: CGFloat = 80

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        return CGSize(width: width, height: frames(of: subviews, width: width).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(of: subviews, width: bounds.width)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(of subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            var size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let isField = index == subviews.count - 1
            if isField { size.width = minimumFieldWidth }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            if isField { size.width = width - x }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

#if DEBUG
#Preview("Add replacement") {
    DictionaryEditorPreview()
}

#Preview("Edit replacement") {
    DictionaryEditorPreview(editing: true)
}

#Preview("From a transcript") {
    DictionaryEditorPreview(aliases: ["cloud code"])
}

#Preview("Adding to an existing target") {
    DictionaryEditorPreview(target: "GitHub", aliases: ["gitt hub"])
}

#Preview("Many spellings") {
    DictionaryEditorPreview(target: "Long list", aliases: (1...7).map { "spelling \($0)" })
}

#Preview("Spelling already used") {
    DictionaryEditorPreview(target: "Other", aliases: ["git hub"])
}
#endif
