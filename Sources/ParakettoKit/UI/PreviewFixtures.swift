#if DEBUG
import SwiftUI

/// Canvas previews use the real views and stores with disposable sample data. They never start the
/// controller, load models, register hotkeys, or touch the real dictionary or transcripts folder.
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
                                        transcripts: TranscriptFolder(url: directory.appendingPathComponent("transcripts")),
                                        shortcuts: ShortcutSettings(defaults: defaults))
        guard !empty else { return }
        do {
            let rules = [
                DictionaryRule(target: "Paraketto", aliases: ["para keto", "parakeeto"]),
                DictionaryRule(target: "GitHub", aliases: ["git hub", "get hub"]),
                DictionaryRule(target: "SwiftUI", aliases: ["swift you eye", "swift ui"]),
                DictionaryRule(target: "macOS", aliases: ["mac os", "Mac OS"]),
                DictionaryRule(target: "Core ML", aliases: ["core em el", "core ml"]),
                DictionaryRule(target: "hello@example.com", aliases: ["my email address"]),
            ]
            for rule in rules { try dictionary.save(rule) }
        } catch {
            fatalError("Could not create preview fixtures: \(error)")
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: defaultsName)
    }
}

struct DictionaryPreview: View {
    @StateObject private var fixtures: PreviewFixtures
    private let importErrors: [String]

    init(empty: Bool = false, importErrors: [String] = []) {
        self.importErrors = importErrors
        _fixtures = StateObject(wrappedValue: PreviewFixtures(empty: empty))
    }

    var body: some View {
        DictionaryView(controller: fixtures.controller)
            .frame(width: 560, height: 480)
            .onAppear {
                fixtures.controller.showPreview(.idle, importErrors: importErrors)
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
    private let isMicrophoneDenied: Bool
    private let canPostEvents: Bool
    private let isShortcutInUse: Bool

    init(_ state: DictationController.State, modelError: String? = nil, isAccessibilityTrusted: Bool = true,
         isMicrophoneDenied: Bool = false, isShortcutInUse: Bool = false, canPostEvents: Bool = true) {
        self.state = state
        self.modelError = modelError
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.isMicrophoneDenied = isMicrophoneDenied
        self.canPostEvents = canPostEvents
        self.isShortcutInUse = isShortcutInUse
    }

    var body: some View {
        MenuContent(controller: fixtures.controller, isAccessibilityTrusted: { isAccessibilityTrusted },
                    isMicrophoneDenied: { isMicrophoneDenied }, canPostEvents: { canPostEvents })
            .onAppear { fixtures.controller.showPreview(state, modelError: modelError, isShortcutInUse: isShortcutInUse) }
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

/// The pill while dropped files are transcribed, its bar filling and starting over.
struct PillImportPreview: View {
    @StateObject private var fixtures = PreviewFixtures(empty: true)

    var body: some View {
        PillView(controller: fixtures.controller)
            .background(Color(white: 0.6))
            .task {
                for tick in 0... {
                    let status = DictationController.FileImportStatus(filename: "Team meeting.m4a",
                                                                      progress: Double(tick % 40) / 40)
                    fixtures.controller.showPreview(.transcribing, fileImport: status)
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                }
            }
    }
}

/// Every fixed message the pill can show, to see at a glance that none is truncated.
struct PillMessagesPreview: View {
    private static let messages: [DictationController.State] = [
        .notice("Copied"), .failed("No mic access"), .failed("No microphone"),
        .failed("Can’t record"), .failed("Recording failed"), .failed("Dictation failed"), .failed("Shortcut in use"),
        .failed("Import failed"), .failed("Copy failed"),
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
