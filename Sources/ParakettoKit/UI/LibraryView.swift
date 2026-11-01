import SwiftUI

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
        .frame(minWidth: 500, minHeight: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
        .toolbarBackground(.hidden, for: .windowToolbar)
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
            draft = DictionaryDraft(rule: DictionaryRule(target: "", aliases: [source]))
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
