import AppKit
import SwiftUI

/// The last week's dictations grouped by day, with search, the folder of all transcripts, and download, copy and delete per entry.
struct TranscriptsView: View {
    let removeAlias: (String, UUID) -> Void
    @ObservedObject var controller: DictationController
    @ObservedObject var store: HistoryStore
    @ObservedObject var shortcuts: ShortcutSettings
    @State private var isDropTargeted = false
    @State private var query: String
    /// Kept here rather than on the rows, so an expanded row stays expanded when a search hides it for a moment.
    @State private var expandedEntries: Set<UUID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    private static let listTop = "listTop"

    init(controller: DictationController, removeAlias: @escaping (String, UUID) -> Void, query: String = "") {
        self.removeAlias = removeAlias
        self.controller = controller
        store = controller.history
        shortcuts = controller.shortcuts
        _query = State(initialValue: query)
    }

    private var searchText: String { TextSearch.term(in: query) }

    /// One pass over the history per update: the filter, the counts and each row's highlights all come from it.
    private var searchResults: (entries: [HistoryEntry], matches: [UUID: [NSRange]]) {
        let query = searchText
        guard !query.isEmpty else { return (store.entries, [:]) }
        var matches: [UUID: [NSRange]] = [:]
        let entries = store.entries.filter { entry in
            let found = TextSearch.matches(of: query, in: entry.displayText)
            if !found.isEmpty { matches[entry.id] = found }
            return !found.isEmpty
        }
        return (entries, matches)
    }

    private func sections(of entries: [HistoryEntry]) -> [(day: Date, title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            (day: day, title: Self.dayTitle(day, calendar: calendar), entries: grouped[day] ?? [])
        }
    }

    var body: some View {
        let results = searchResults
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SearchField(prompt: "Search the last \(HistoryStore.retentionDays) days", text: $query)
                    // While focused, the field would take a dropped file for itself and insert its path.
                    .disabled(isDropTargeted)
                Button { openTranscriptsFolder() } label: {
                    Image(systemName: "folder").frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .help("Open the folder with all transcripts").accessibilityLabel("Open the folder with all transcripts")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if let job = controller.fileImport {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.filename).lineLimit(1).truncationMode(.middle)
                        ProgressView(value: job.progress)
                            .accessibilityLabel("Transcribing \(job.filename)")
                    }
                    Button("Cancel") { controller.cancelFileImport() }
                }
                .padding()
                Divider()
            }
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
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "No recent transcripts",
                    systemImage: "mic",
                    description: Text("Start and stop with \(shortcuts.shortcut.label). Older transcripts are in the transcripts folder.")
                )
                .frame(maxHeight: .infinity)
            } else if results.entries.isEmpty {
                ContentUnavailableView {
                    Label("No results for “\(searchText)”", systemImage: "magnifyingglass")
                } description: {
                    Text("Search covers the last \(HistoryStore.retentionDays) days. Older transcripts are in the transcripts folder.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Color.clear.frame(height: 0).id(Self.listTop)
                            ForEach(sections(of: results.entries), id: \.day) { section in
                                Section {
                                    ForEach(section.entries) { entry in
                                        TranscriptRow(entry: entry, store: store, dictionary: controller.dictionary,
                                                      removeAlias: removeAlias, matches: results.matches[entry.id] ?? [],
                                                      expanded: isExpanded(entry))
                                            .padding(.horizontal, 16)
                                        if entry.id != section.entries.last?.id {
                                            separator.padding(.horizontal, 16)
                                        }
                                    }
                                } header: {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(section.title)
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(Color(nsColor: .systemTeal))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                        separator
                                    }
                                    .background(Color(nsColor: .textBackgroundColor))
                                }
                            }
                        }
                    }
                    // Transparent title bars must not reveal scroll content outside this viewport.
                    .clipped()
                    // Results would otherwise appear at the old scroll position.
                    .onChange(of: searchText) { proxy.scrollTo(Self.listTop, anchor: .top) }
                }
            }
            Divider()
            footer(results)
        }
        .frame(minWidth: 460, minHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if isDropTargeted {
                AudioFileDropOverlay(isAvailable: controller.canImportFiles)
                    .padding(12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.16), value: isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = controller.importFiles(urls)
            // What comes out of the file may not match a search left in the box.
            if accepted { query = "" }
            return accepted
        } isTargeted: { isDropTargeted = $0 }
        .onExitCommand {
            // Clearing the search comes first, as it is the one that loses nothing.
            if !query.isEmpty { query = "" } else if controller.fileImport != nil { controller.cancelFileImport() }
        }
        .onChange(of: store.entries.count) { old, new in
            // A new dictation may not match a search left in the box. Imports clear it when
            // dropped instead, so that a search started while they run isn't lost with each file.
            if new > old, controller.fileImport == nil { query = "" }
        }
    }

    private func openTranscriptsFolder() {
        // Nothing may have been saved yet, or the folder may have been removed.
        try? FileManager.default.createDirectory(at: store.transcriptsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.transcriptsDirectory)
    }

    private var separator: some View {
        Color(nsColor: .separatorColor).frame(height: 1 / displayScale)
    }

    private func isExpanded(_ entry: HistoryEntry) -> Binding<Bool> {
        Binding {
            expandedEntries.contains(entry.id)
        } set: { isExpanded in
            if isExpanded { expandedEntries.insert(entry.id) } else { expandedEntries.remove(entry.id) }
        }
    }

    private func footer(_ results: (entries: [HistoryEntry], matches: [UUID: [NSRange]])) -> some View {
        HStack {
            if searchText.isEmpty {
                Text("Last \(HistoryStore.retentionDays) days")
                Text("·").foregroundStyle(.tertiary)
                Text("^[\(store.entries.count) transcript](inflect: true)")
                Text("·").foregroundStyle(.tertiary)
                Text("^[\(store.totalWords) word](inflect: true)")
            } else {
                Text("\(results.entries.count) of ^[\(store.entries.count) transcript](inflect: true)")
                Text("·").foregroundStyle(.tertiary)
                Text("^[\(results.matches.values.reduce(0) { $0 + $1.count }) match](inflect: true)")
            }
            Spacer()
            Text("Start and stop: \(shortcuts.shortcut.label)")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// Appears only while dragging over Transcripts; there is no persistent import prompt.
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
#Preview("Transcripts") {
    LibraryPreview()
}

#Preview("Empty transcripts") {
    LibraryPreview(empty: true)
}

#Preview("Search") {
    TranscriptSearchPreview(query: "the")
}

#Preview("Search in a long transcript") {
    TranscriptSearchPreview(query: "budget")
}

#Preview("Search without matches") {
    TranscriptSearchPreview(query: "zebra")
}

#Preview("Importing") {
    LibraryPreview(fileImport: .init(filename: "Team meeting.m4a", progress: 0.42))
}

#Preview("Import failed") {
    LibraryPreview(importErrors: ["Team meeting.m4a: The operation could not be completed.",
                                  "notes.txt: The file is not an audio file."])
}

#Preview("Importing with errors") {
    LibraryPreview(fileImport: .init(filename: "Interview.wav", progress: 0.8),
                   importErrors: ["notes.txt: The file is not an audio file."])
}

#Preview("Drop audio files") {
    LibraryPreview().overlay { AudioFileDropOverlay(isAvailable: true).padding(12) }
}

#Preview("Drop while busy") {
    LibraryPreview().overlay { AudioFileDropOverlay(isAvailable: false).padding(12) }
}
#endif
