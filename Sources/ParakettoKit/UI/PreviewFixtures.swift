#if DEBUG
import SwiftUI

/// Canvas previews use the real views and stores with disposable sample data.
/// They never start the controller, load models, register hotkeys, or use personal history.
@MainActor
final class PreviewFixtures: ObservableObject {
    let controller: DictationController
    private let directory: URL
    private let defaults: UserDefaults
    private let defaultsName: String

    init(empty: Bool = false) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParakettoPreviews/\(UUID().uuidString)", isDirectory: true)
        defaultsName = "io.lfrati.paraketto.preview.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
        let dictionary = DictionaryStore(url: directory.appendingPathComponent("dictionary.json"))
        controller = DictationController(dictionary: dictionary,
                                        historyDirectory: directory.appendingPathComponent("history"),
                                        shortcuts: ShortcutSettings(defaults: defaults))
        guard !empty else { return }
        do {
            try dictionary.save(DictionaryRule(target: "GitHub", aliases: ["gee tub", "git hub"]))
            try dictionary.save(DictionaryRule(target: "Paraketto", aliases: ["para keto"]))
            try dictionary.save(DictionaryRule(target: "pop. size", aliases: ["population size"]))
            let samples = [
                "I pushed the changes to gee tub, then checked the para keto build.",
                "There is population size and the specific case. Replacements keep the same contrast as the surrounding text.",
                String(repeating: "This longer transcript shows how text wraps and expands. ", count: 10),
                "Yesterday’s note: send us the details at us@example.com."
            ]
            // Add oldest first, as HistoryStore inserts new recordings at the top.
            for index in samples.indices.reversed() {
                let recording = try RecordingFile(directory: directory)
                try recording.append([Float](repeating: 0, count: 16_000))
                let date = Date().addingTimeInterval(index == 3 ? -86_400 : Double(index) * -300)
                try controller.history.add(HistoryEntry(id: UUID(), date: date, text: samples[index],
                    destination: index == 0 ? "Signal" : "Notes", duration: 1,
                    inferenceMilliseconds: 10, delivery: .pasted), recording: recording)
            }
        } catch {
            fatalError("Could not create preview fixtures: \(error)")
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: defaultsName)
    }
}

struct LibraryPreview: View {
    @StateObject private var fixtures: PreviewFixtures
    private let tab: DictationController.WindowTab
    private let fileImport: DictationController.FileImportStatus?
    private let importErrors: [String]

    init(tab: DictationController.WindowTab = .transcripts, empty: Bool = false,
         fileImport: DictationController.FileImportStatus? = nil, importErrors: [String] = []) {
        self.tab = tab
        self.fileImport = fileImport
        self.importErrors = importErrors
        _fixtures = StateObject(wrappedValue: PreviewFixtures(empty: empty))
    }

    var body: some View {
        LibraryView(controller: fixtures.controller)
            .frame(width: 560, height: 480)
            .onAppear {
                fixtures.controller.windowTab = tab
                fixtures.controller.showPreview(fileImport == nil ? .idle : .transcribing,
                                                fileImport: fileImport, importErrors: importErrors)
            }
    }
}

struct DictionaryEditorPreview: View {
    @StateObject private var fixtures = PreviewFixtures()
    var editing = false
    var target = ""
    var aliases: [String] = []

    var body: some View {
        DictionaryEditor(store: fixtures.controller.dictionary,
                         draft: DictionaryDraft(rule: editing
                            ? fixtures.controller.dictionary.rules[0]
                            : DictionaryRule(target: target, aliases: aliases)))
    }
}

struct MenuPreview: View {
    @StateObject private var fixtures = PreviewFixtures(empty: true)
    private let state: DictationController.State
    private let modelError: String?
    private let isAccessibilityTrusted: Bool

    init(_ state: DictationController.State, modelError: String? = nil, isAccessibilityTrusted: Bool = true) {
        self.state = state
        self.modelError = modelError
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    var body: some View {
        MenuContent(controller: fixtures.controller, isAccessibilityTrusted: { isAccessibilityTrusted })
            .onAppear { fixtures.controller.showPreview(state, modelError: modelError) }
    }
}

/// The pill on a desktop-like backdrop, its meter fed with synthetic speech while recording.
struct PillPreview: View {
    @StateObject private var fixtures = PreviewFixtures(empty: true)
    private let state: DictationController.State

    init(_ state: DictationController.State) {
        self.state = state
    }

    var body: some View {
        PillView(controller: fixtures.controller)
            .background(Color(white: 0.6))
            .task { await run() }
    }

    private func run() async {
        guard state.isCancellable else {
            fixtures.controller.showPreview(state)
            return
        }
        fixtures.controller.showPreview(.recording)
        // Fill the meter before freezing it, since transcribing shows the bars recording left.
        let ticks = state == .transcribing ? 40 : Int.max
        for tick in 0..<ticks {
            let time = Double(tick) * 0.05
            let level = abs(sin(time * 5)) * (0.35 + 0.65 * abs(sin(time * 0.9)))
            fixtures.controller.showPreviewMeter(level: Float(level), elapsed: time)
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
        }
        fixtures.controller.showPreview(state)
    }
}

/// Every fixed message the pill can show, to see at a glance that none is truncated.
struct PillMessagesPreview: View {
    private static let messages: [DictationController.State] = [
        .notice("Copied"), .notice("Kept in history"), .failed("No mic access"), .failed("No microphone"),
        .failed("Can’t record"), .failed("Recording failed"), .failed("Dictation failed"), .failed("Shortcut in use"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.messages, id: \.label) { PillPreview($0) }
        }
    }
}

struct ShortcutRecorderPreview: View {
    @StateObject private var fixtures = PreviewFixtures(empty: true)

    var body: some View {
        ShortcutRecorder(settings: fixtures.controller.shortcuts)
            .padding(40)
    }
}

/// Every look of the shortcut button, including those the recorder only shows for a moment.
struct ShortcutStatesPreview: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            row("Saved tap", ShortcutButton(title: "Right ⌥", action: {}))
            row("Saved chord", ShortcutButton(title: "⌃⌥Space", action: {}))
            row("Hovered", ShortcutButton(title: "Right ⌥", isHovered: true, action: {}))
            row("Waiting", ShortcutButton(title: "…", isRecording: true, isWaiting: true, action: {}))
            row("Pressing keys", ShortcutButton(title: "⌃⌥", isRecording: true, action: {}))
            row("Invalid", ShortcutButton(title: "A", isRecording: true, isRejected: true, action: {}))
            row("Just saved", ShortcutButton(title: "⌃⌥Space", didSave: true, action: {}))
            row("Disabled", ShortcutButton(title: "Right ⌥", action: {}).disabled(true))
        }
        .padding(20)
    }

    private func row(_ name: String, _ button: some View) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            button
        }
    }
}
#endif
