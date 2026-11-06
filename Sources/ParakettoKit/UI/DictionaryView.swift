import AppKit
import SwiftUI

/// The replacements with search, the folder of all transcripts, and audio files dropped to be transcribed.
struct DictionaryView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var store: DictionaryStore
    @State private var query = ""
    @State private var newDraft: DictionaryDraft?
    @State private var deletion: DictionaryRule?
    @State private var error: String?
    @State private var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(controller: DictationController) {
        self.controller = controller
        store = controller.dictionary
    }

    private var filtered: [DictionaryRule] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.rules.filter { rule in
            search.isEmpty || ([rule.target] + rule.aliases).contains { TextSearch.contains(search, in: $0) }
        }.sorted { $0.target.localizedStandardCompare($1.target) == .orderedAscending }
    }

    var body: some View {
        FileDropArea(isTargeted: { isDropTargeted = $0 }, drop: { controller.importFiles($0) }, content: AnyView(content))
            .frame(minWidth: 500, minHeight: 380)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
            .toolbarBackground(.hidden, for: .windowToolbar)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SearchField(prompt: "Search dictionary", text: $query)
                    // While focused, the field would take a dropped file for itself and insert its path.
                    .disabled(isDropTargeted)
                Button { newDraft = DictionaryDraft(rule: DictionaryRule(target: "", aliases: [])) } label: {
                    Image(systemName: "plus").frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .help("Add replacement").accessibilityLabel("Add replacement")
                .disabled(store.loadError != nil)
                .popover(item: $newDraft, arrowEdge: .bottom) { DictionaryEditor(store: store, draft: $0) }
                Button { openTranscriptsFolder() } label: {
                    Image(systemName: "folder").frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .help("Open the folder with all transcripts").accessibilityLabel("Open the folder with all transcripts")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            importErrors
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
        .overlay {
            if isDropTargeted {
                AudioFileDropOverlay(isAvailable: controller.canImportFiles)
                    .padding(12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.16), value: isDropTargeted)
        // During an import the controller takes Esc unless the search holds text, so this clears it first.
        .onExitCommand { query = "" }
        .confirmationDialog("Delete this replacement?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let deletion else { return }
                do { try store.remove(id: deletion.id) }
                catch { self.error = error.localizedDescription }
                self.deletion = nil
            }
        } message: { Text("Transcripts already saved stay as they are.") }
        .alert("Could not update dictionary", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    /// Progress shows in the pill; what went wrong with which file needs the room here.
    @ViewBuilder private var importErrors: some View {
        if !controller.importErrors.isEmpty {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(controller.importErrors, id: \.self) { error in
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Spacer()
                Button("Dismiss") { controller.dismissImportErrors() }
            }
            .padding()
            Divider()
        }
    }

    private func openTranscriptsFolder() {
        // Nothing may have been saved yet, or the folder may have been removed.
        try? FileManager.default.createDirectory(at: controller.transcripts.url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(controller.transcripts.url)
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

/// Appears only while dragging over the window; there is no persistent import prompt.
struct AudioFileDropOverlay: View {
    let isAvailable: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isAvailable ? Color.accentColor : Color.secondary,
                                  style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: isAvailable ? "arrow.down.doc" : "hourglass")
                        .font(.system(size: 38, weight: .light))
                    Text(isAvailable ? "Drop audio files here" : "Paraketto is busy")
                        .font(.title3.weight(.semibold))
                }
                .foregroundStyle(isAvailable ? Color.accentColor : Color.secondary)
            }
    }
}

#if DEBUG
#Preview("Dictionary") {
    DictionaryPreview()
}

#Preview("Empty dictionary") {
    DictionaryPreview(empty: true)
}

#Preview("Import failed") {
    DictionaryPreview(importErrors: ["Team meeting.m4a: The operation could not be completed.",
                                     "Voice memo.m4a: No speech detected."])
}

#Preview("Drop audio files") {
    DictionaryPreview().overlay { AudioFileDropOverlay(isAvailable: true).padding(12) }
}

#Preview("Drop while busy") {
    DictionaryPreview().overlay { AudioFileDropOverlay(isAvailable: false).padding(12) }
}
#endif
