import SwiftUI

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
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search dictionary", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                Button { edit(DictionaryDraft(rule: DictionaryRule(target: "", aliases: [""]))) } label: {
                    Image(systemName: "plus").frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .help("Add dictionary entry").accessibilityLabel("Add dictionary entry")
                .disabled(store.loadError != nil)
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
                            Text("Add a target spelling and the spellings to replace.")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                } else {
                    List(filtered) { rule in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(rule.target).fontWeight(.semibold)
                                Text(rule.aliases.joined(separator: "  ·  ")).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 12) {
                                Button { edit(DictionaryDraft(rule: rule)) } label: { Image(systemName: "square.and.pencil") }
                                    .help("Edit rule").accessibilityLabel("Edit \(rule.target)")
                                Button { deletion = rule } label: { Image(systemName: "trash") }
                                    .help("Delete rule").accessibilityLabel("Delete \(rule.target)")
                            }
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 6)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .contextMenu {
                            Button("Edit rule…") { edit(DictionaryDraft(rule: rule)) }
                            Button("Delete rule…", role: .destructive) { deletion = rule }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    // Each search gets a new list. Rows inserted above the visible ones would
                    // otherwise leave it scrolled, hiding the top of the results.
                    .id(query)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

#if DEBUG
#Preview("Dictionary") {
    LibraryPreview(tab: .dictionary)
}

#Preview("Empty dictionary") {
    LibraryPreview(tab: .dictionary, empty: true)
}
#endif
