import SwiftUI

struct DictionaryDraft: Identifiable {
    let id = UUID()
    var rule: DictionaryRule
}

struct DictionaryEditor: View {
    @ObservedObject var store: DictionaryStore
    let draft: DictionaryDraft
    private struct AliasDraft: Identifiable {
        let id = UUID()
        var text: String
    }
    @State private var rule: DictionaryRule
    @State private var aliases: [AliasDraft]
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var targetFocused: Bool

    init(store: DictionaryStore, draft: DictionaryDraft) {
        self.store = store
        self.draft = draft
        _rule = State(initialValue: draft.rule)
        _aliases = State(initialValue: draft.rule.aliases.map { AliasDraft(text: $0) })
    }

    private var isAdding: Bool { !store.rules.contains { $0.id == rule.id } }
    private var targetQuery: String { rule.target.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var existingTarget: DictionaryRule? {
        guard isAdding else { return nil }
        return store.rules.first { Array($0.target.utf16) == Array(targetQuery.utf16) }
    }

    private var suggestions: [DictionaryRule] {
        guard isAdding, !targetQuery.isEmpty, existingTarget == nil else { return [] }
        return store.rules.filter { $0.target.localizedCaseInsensitiveContains(targetQuery) }
            .sorted { $0.target.localizedStandardCompare($1.target) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.rules.contains(where: { $0.id == rule.id }) ? "Edit replacement" : "Add replacement")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                TextField("TO — target spelling", text: $rule.target).focused($targetFocused)
                if !suggestions.isEmpty {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(suggestions) { suggestion in
                                Button {
                                    useTarget(suggestion)
                                } label: {
                                    HStack {
                                        Text(suggestion.target).lineLimit(1)
                                        Spacer()
                                        Text("Use existing").foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 28)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Use existing target \(suggestion.target)")
                            }
                        }
                    }
                    .frame(height: min(140, CGFloat(suggestions.count) * 28))
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                } else if isAdding, !targetQuery.isEmpty {
                    Text(existingTarget == nil ? "New target" : "Add to existing target")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("FROM: ").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { aliases.append(AliasDraft(text: "")) } label: {
                    Image(systemName: "plus").frame(width: 16, height: 16)
                }
                .help("Add spelling").accessibilityLabel("Add spelling")
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($aliases) { $alias in
                        HStack {
                            TextField("Source spelling", text: $alias.text)
                            Button {
                                aliases.removeAll { $0.id == alias.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .disabled(aliases.count == 1)
                                .accessibilityLabel("Remove source spelling")
                        }
                    }
                }
                .padding(1)
            }
            .frame(height: min(160, CGFloat(aliases.count) * 30))
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if isAdding {
                targetFocused = true
            } else {
                // Sheets focus their first text field on their own, which would select the target.
                DispatchQueue.main.async { NSApp.windows.first(where: \.isSheet)?.makeFirstResponder(nil) }
            }
        }
    }

    private func useTarget(_ suggestion: DictionaryRule) {
        rule.target = suggestion.target
        targetFocused = false
    }

    private func save() {
        var result = rule
        result.target = result.target.trimmingCharacters(in: .whitespacesAndNewlines)
        result.aliases = aliases.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if var existing = existingTarget {
            existing.aliases += result.aliases
            result = existing
        }
        do { try store.save(result); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

#if DEBUG
#Preview("Add replacement") {
    DictionaryEditorPreview()
}

#Preview("Edit replacement") {
    DictionaryEditorPreview(editing: true)
}
#endif
