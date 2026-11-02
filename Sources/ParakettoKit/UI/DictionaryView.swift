import SwiftUI

struct DictionaryView: View {
    @ObservedObject var store: DictionaryStore
    @State private var query = ""
    @State private var newDraft: DictionaryDraft?
    @State private var deletion: DictionaryRule?
    @State private var error: String?

    private var filtered: [DictionaryRule] {
        store.rules.filter { rule in
            query.isEmpty || ([rule.target] + rule.aliases).contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { $0.target.localizedStandardCompare($1.target) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                OutlinedField {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search dictionary", text: $query).textFieldStyle(.plain)
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).accessibilityLabel("Clear search")
                        }
                    }
                    .frame(height: 20)
                }
                Button { newDraft = DictionaryDraft(rule: DictionaryRule(target: "", aliases: [])) } label: {
                    Image(systemName: "plus").frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .help("Add replacement").accessibilityLabel("Add replacement")
                .disabled(store.loadError != nil)
                .popover(item: $newDraft, arrowEdge: .bottom) { DictionaryEditor(store: store, draft: $0) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            Group {
                if let error = store.loadError {
                    Text(error).foregroundStyle(.secondary).padding(24)
                } else if filtered.isEmpty {
                    VStack(spacing: 6) {
                        Text(query.isEmpty ? "No replacements yet" : "No matches")
                        if query.isEmpty {
                            Text("Add what to replace and what to write instead.")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ScrollViewReader { proxy in
                        List(filtered) { rule in
                            DictionaryRow(rule: rule, store: store) { deletion = rule }
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        // Each search gets a new list. Rows inserted above the visible ones would
                        // otherwise leave it scrolled, hiding the top of the results.
                        .id(query)
                        // A new rule can land anywhere in the sorted list, so bring it into view.
                        .onChange(of: store.rules) { old, new in
                            guard let added = new.first(where: { rule in !old.contains { $0.id == rule.id } }) else { return }
                            proxy.scrollTo(added.id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
        .confirmationDialog("Delete this replacement?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
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

private struct DictionaryRow: View {
    let rule: DictionaryRule
    @ObservedObject var store: DictionaryStore
    let delete: () -> Void
    @State private var draft: DictionaryDraft?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(rule.target).fontWeight(.semibold)
                Text(rule.aliases.joined(separator: "  ·  ")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button { draft = DictionaryDraft(rule: rule) } label: { Image(systemName: "square.and.pencil") }
                    .help("Edit replacement").accessibilityLabel("Edit \(rule.target)")
                    .popover(item: $draft, arrowEdge: .bottom) { DictionaryEditor(store: store, draft: $0) }
                Button { delete() } label: { Image(systemName: "trash") }
                    .help("Delete replacement").accessibilityLabel("Delete \(rule.target)")
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 6)
        .contextMenu {
            Button("Edit replacement…") { draft = DictionaryDraft(rule: rule) }
            Button("Delete replacement…", role: .destructive) { delete() }
        }
    }
}

#if DEBUG
#Preview("Dictionary") {
    LibraryPreview(tab: .dictionary)
}

#Preview("Empty dictionary") {
    LibraryPreview(tab: .dictionary, empty: true)
}
#endif
