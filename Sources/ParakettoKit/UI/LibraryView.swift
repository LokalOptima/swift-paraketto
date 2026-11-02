import SwiftUI

/// One window with the Transcripts and Dictionary tabs.
struct LibraryView: View {
    @ObservedObject var controller: DictationController
    @State private var error: String?

    var body: some View {
        TabView(selection: $controller.windowTab) {
            TranscriptsView(controller: controller, removeAlias: removeAlias)
                .tabItem { Label("Transcripts", systemImage: "text.alignleft") }
                .tag(DictationController.WindowTab.transcripts)
            DictionaryView(store: controller.dictionary)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
                .tag(DictationController.WindowTab.dictionary)
        }
        .frame(minWidth: 500, minHeight: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .alert("Could not update dictionary", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func removeAlias(_ alias: String, from id: UUID) {
        do { try controller.dictionary.removeAlias(alias, from: id) }
        catch { self.error = error.localizedDescription }
    }
}
