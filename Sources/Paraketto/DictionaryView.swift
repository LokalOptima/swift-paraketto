import SwiftUI

struct DictionaryDraft: Identifiable {
    let id = UUID()
    var rule: DictionaryRule
    var sourceSelection: String? = nil
}

/// One window, including the shared editor sheet opened from either tab.
struct LibraryView: View {
    @ObservedObject var controller: DictationController
    @State private var draft: DictionaryDraft?
    @State private var error: String?

    var body: some View {
        TabView(selection: $controller.windowTab) {
            TranscriptsView(controller: controller, dictionaryAction: handle)
                .tabItem { Label("Transcripts", systemImage: "text.alignleft") }
                .tag(DictationController.WindowTab.transcripts)
            DictionaryView(store: controller.dictionary, edit: { draft = $0 })
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
                .tag(DictationController.WindowTab.dictionary)
        }
        .padding(8)
        .frame(minWidth: 500, minHeight: 380)
        .sheet(item: $draft) { draft in
            DictionaryEditor(store: controller.dictionary, draft: draft)
        }
        .alert("Could not update dictionary", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func handle(_ action: TranscriptDictionaryAction) {
        switch action {
        case .add(let source):
            draft = DictionaryDraft(rule: DictionaryRule(target: "", aliases: [source]), sourceSelection: source)
        case .edit(let id):
            if let rule = controller.dictionary.rules.first(where: { $0.id == id }) {
                draft = DictionaryDraft(rule: rule)
            }
        case .remove(let id, let alias):
            do { try controller.dictionary.removeAlias(alias, from: id) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct DictionaryView: View {
    @ObservedObject var store: DictionaryStore
    let edit: (DictionaryDraft) -> Void
    @State private var query = ""
    @State private var deletion: DictionaryRule?
    @State private var error: String?

    private var filtered: [DictionaryRule] {
        store.rules.filter { rule in
            query.isEmpty || ([rule.target] + rule.aliases).contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { $0.target.localizedStandardCompare($1.target) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search dictionary", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).accessibilityLabel("Clear search")
                }
                Button { edit(DictionaryDraft(rule: DictionaryRule(target: "", aliases: [""]))) } label: {
                    Image(systemName: "plus")
                }
                .help("Add dictionary entry").accessibilityLabel("Add dictionary entry")
                .disabled(store.loadError != nil)
            }
            .padding(12)
            Divider()
            if let error = store.loadError {
                ContentUnavailableView("Dictionary unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No replacements yet" : "No matches",
                                       systemImage: "character.book.closed",
                                       description: Text(query.isEmpty ? "Add a target spelling and the spellings to replace." : "Try another spelling."))
            } else {
                List(filtered) { rule in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(rule.target).fontWeight(.semibold)
                            Text(rule.aliases.joined(separator: "  ·  ")).foregroundStyle(.secondary)
                            Text(rule.allowsPunctuation ? "Allows , . ; ( )" : "Strict boundaries")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button { edit(DictionaryDraft(rule: rule)) } label: { Image(systemName: "pencil") }
                            .help("Edit rule").accessibilityLabel("Edit \(rule.target)")
                        Button { deletion = rule } label: { Image(systemName: "trash") }
                            .help("Delete rule").accessibilityLabel("Delete \(rule.target)")
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 6)
                    .contextMenu {
                        Button("Edit rule…") { edit(DictionaryDraft(rule: rule)) }
                        Button("Delete rule…", role: .destructive) { deletion = rule }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .confirmationDialog("Delete this rule?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            Button("Delete rule", role: .destructive) {
                guard let deletion else { return }
                do { try store.remove(id: deletion.id) }
                catch { self.error = error.localizedDescription }
                self.deletion = nil
            }
        } message: { Text("All transcripts will be reprocessed from their originals.") }
        .alert("Could not update dictionary", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
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
    @State private var existingTarget: UUID?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var targetFocused: Bool

    init(store: DictionaryStore, draft: DictionaryDraft) {
        self.store = store
        self.draft = draft
        _rule = State(initialValue: draft.rule)
        _aliases = State(initialValue: draft.rule.aliases.map { AliasDraft(text: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.rules.contains(where: { $0.id == rule.id }) ? "Edit replacement" : "Add replacement")
                .font(.headline)
            if draft.sourceSelection != nil, !store.rules.isEmpty {
                Picker("Target", selection: $existingTarget) {
                    Text("New target").tag(nil as UUID?)
                    ForEach(store.rules.sorted { $0.target.localizedStandardCompare($1.target) == .orderedAscending }) { entry in
                        Text(entry.target).tag(Optional(entry.id))
                    }
                }
            }
            if existingTarget == nil {
                TextField("TO — target spelling", text: $rule.target).focused($targetFocused)
            }
            Text("FROM — exact spellings").font(.subheadline).foregroundStyle(.secondary)
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
            Button("Add spelling", systemImage: "plus") { aliases.append(AliasDraft(text: "")) }
            if existingTarget == nil {
                Toggle("Allow punctuation , . ; ( )", isOn: $rule.allowsPunctuation)
            } else {
                Text("Uses the existing target’s punctuation setting.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Exact, case-sensitive matches. Changes apply to all transcripts.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 420)
        .onAppear { targetFocused = true }
    }

    private func save() {
        var result = rule
        result.target = result.target.trimmingCharacters(in: .whitespacesAndNewlines)
        result.aliases = aliases.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let existingTarget, var existing = store.rules.first(where: { $0.id == existingTarget }) {
            existing.aliases += result.aliases
            result = existing
        }
        do { try store.save(result); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
