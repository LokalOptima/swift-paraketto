import AppKit
import Combine
import Foundation

/// What the pill's meter shows. Separate from the controller because it publishes 20 times a
/// second while recording, which must not re-render every view that observes the controller.
@MainActor
final class RecordingMeter: ObservableObject {
    @Published fileprivate(set) var level: Float = 0
    @Published fileprivate(set) var elapsed: TimeInterval = 0
}

/// Owns the record → transcribe → paste loop and exposes state for the menu bar, overlay and history.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case downloadingModel(Double)
        case optimizingModel
        case loadingModel
        case idle
        case recording
        case transcribing
        case notice(String)
        case failed(String)

        var symbolName: String {
            switch self {
            case .downloadingModel: return "arrow.down.circle"
            case .loadingModel, .optimizingModel: return "hourglass"
            case .idle, .notice: return "mic"
            case .recording: return "mic.fill"
            case .transcribing: return "waveform"
            case .failed: return "exclamationmark.triangle"
            }
        }

        var label: String {
            switch self {
            case .downloadingModel(let fraction): return "Downloading model… \(Int(fraction * 100))%"
            case .loadingModel: return "Loading model…"
            case .optimizingModel: return "Optimizing model…"
            case .idle: return "Ready"
            case .recording: return "Recording…"
            case .transcribing: return "Transcribing…"
            case .notice(let message): return message
            case .failed(let message): return "Error: \(message)"
            }
        }

        var canStartRecording: Bool {
            switch self {
            case .idle, .notice, .failed: return true
            default: return false
            }
        }

        var isCancellable: Bool {
            self == .recording || self == .transcribing
        }
    }

    @Published private(set) var state: State = .loadingModel {
        didSet { if state != oldValue, !isPreview { Log.info("state: \(state.label)") } }
    }
    /// Set for Xcode's canvas, which must not write to the user's log or load models.
    private var isPreview = false
    let meter = RecordingMeter()
    @Published private(set) var destination: Destination?
    @Published private(set) var modelError: String?
    @Published private(set) var isLoadingModel = true
    @Published private(set) var isStartingRecording = false
    /// The saved key combination could not be registered, so pressing it does nothing.
    @Published private(set) var isShortcutInUse = false
    private var isModelReady = false
    private var modelLoadID = UUID()

    struct FileImportStatus {
        let id = UUID()
        let filename: String
        var progress: Double = 0
    }
    @Published private(set) var fileImport: FileImportStatus?
    @Published private(set) var importErrors: [String] = []
    private var importTask: Task<Void, Never>?

    var canImportFiles: Bool {
        isModelReady && !isLoadingModel && !isStartingRecording && state.canStartRecording && importTask == nil
    }

    enum WindowTab: Hashable { case transcripts, dictionary }

    /// Set while the menu is open, so showing Transcripts can close it from any route.
    var closeMenu: (() -> Void)?
    @Published var windowTab: WindowTab = .transcripts
    let dictionary: DictionaryStore
    let history: HistoryStore
    let shortcuts: ShortcutSettings

    private static let noticeDuration: Duration = .seconds(2)
    private static let meterInterval: Duration = .milliseconds(50)

    private let transcriber = Transcriber()
    private let recorder = AudioRecorder()
    private var hotkey: Hotkey?
    private var modifierTap: ModifierTap?
    private var shortcutSubscription: AnyCancellable?
    private var escapeMonitors: [Any] = []
    private var overlay: Overlay?
    private var smoother = LevelSmoother()
    private var meterTask: Task<Void, Never>?
    private var recordingStarted = Date()
    private var transcription: Task<Void, Never>?
    /// Coalesces file-length notifications; audio stays on disk if inference falls behind.
    private var audioStream: AsyncStream<Int>.Continuation?
    private var feeder: Task<Void, Never>?

    init(dictionary: DictionaryStore? = nil, historyDirectory: URL? = nil, shortcuts: ShortcutSettings? = nil) {
        let dictionary = dictionary ?? DictionaryStore()
        self.dictionary = dictionary
        self.shortcuts = shortcuts ?? ShortcutSettings()
        history = HistoryStore(directory: historyDirectory, dictionary: dictionary)
    }

    func start() {
        Log.startSession()
        Log.info("launch, log at \(Log.fileURL.path)")
        overlay = Overlay(controller: self)
        recorder.onRMS = { [weak self] rms in
            Task { @MainActor in self?.smoother.update(rms: rms) }
        }
        applyShortcuts()
        shortcutSubscription = shortcuts.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyShortcuts() }
        if !Paster.isAccessibilityTrusted {
            Paster.requestAccessibility()
        }
        Task { await loadModel() }
    }

    /// (Re)arms the shortcut from settings. Nothing is armed while the menu recorder is
    /// capturing a key, so the current shortcut can be pressed to replace itself.
    private func applyShortcuts() {
        hotkey = nil
        modifierTap = nil
        isShortcutInUse = false
        guard !shortcuts.isRecording else { return }
        switch shortcuts.shortcut {
        case .chord(let chord):
            let hotkey = Hotkey(chord: chord, onPress: { [weak self] in self?.toggleRecording() })
            self.hotkey = hotkey
            isShortcutInUse = hotkey.registrationError != nil
            if isShortcutInUse, state == .idle {
                show(.failed("Shortcut in use"))
            }
        case .tap(let key):
            modifierTap = ModifierTap(key) { [weak self] in self?.toggleRecording() }
        }
    }

    /// Escape while recording or transcribing: discard the audio, paste nothing.
    func cancel() {
        if importTask != nil { cancelFileImport(); return }
        guard state.isCancellable else { return }
        Log.info("cancelled")
        transcription?.cancel()
        transcription = nil
        if state == .recording { _ = try? recorder.stop() }
        audioStream?.finish()
        audioStream = nil
        feeder?.cancel()
        feeder = Task { [transcriber, feeder] in await feeder?.value; await transcriber.discard() }
        finishSession()
        state = .idle
        overlay?.hide()
    }

    private func loadModel() async {
        let loadID = UUID()
        modelLoadID = loadID
        isLoadingModel = true
        modelError = nil
        state = .loadingModel
        defer { isLoadingModel = false }
        do {
            await feeder?.value
            let started = Date()
            try await transcriber.load { phase in
                Task { @MainActor [weak self] in
                    guard let self, self.isLoadingModel, self.modelLoadID == loadID else { return }
                    switch phase {
                    case .downloading(let fraction): self.state = .downloadingModel(fraction)
                    case .loading: self.state = .loadingModel
                    case .optimizing: self.state = .optimizingModel
                    }
                }
            }
            isModelReady = true
            state = .idle
            Log.info("Parakeet Ultra ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            // Shortcuts are armed while the model loads, too early for the pill to report a failure.
            if isShortcutInUse { show(.failed("Shortcut in use")) }
        } catch {
            modelError = "Could not load model: \(error.localizedDescription)"
            state = .failed(error.localizedDescription)
            Log.info("Model load failed: \(error)")
        }
    }

    func retryModelLoad() {
        guard !isLoadingModel, !isModelReady, !isPreview else { return }
        // Reserve the transition synchronously, before another shortcut/menu action can run.
        isLoadingModel = true
        state = .loadingModel
        overlay?.hide()
        Task { await loadModel() }
    }

    /// Finder drops process a batch in order, sharing the loaded recognizer.
    @discardableResult
    func importFiles(_ urls: [URL]) -> Bool {
        guard canImportFiles, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        state = .transcribing
        overlay?.hide()
        importErrors = []
        fileImport = FileImportStatus(filename: urls[0].lastPathComponent)
        importTask = Task {
            defer {
                fileImport = nil
                importTask = nil
                state = .idle
            }
            await feeder?.value
            for url in urls {
                guard !Task.isCancelled else { return }
                let status = FileImportStatus(filename: url.lastPathComponent)
                fileImport = status
                do {
                    let result = try await transcriber.transcribeFile(url) { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, self.fileImport?.id == status.id else { return }
                            self.fileImport?.progress = fraction
                        }
                    }
                    try Task.checkCancellation()
                    let entry = HistoryEntry(id: UUID(), date: Date(), text: result.text,
                                             destination: "", duration: result.recording.duration,
                                             inferenceMilliseconds: result.inferenceMilliseconds,
                                             delivery: .imported, sourceFilename: url.lastPathComponent)
                    try history.add(entry, recording: result.recording)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    importErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    func cancelFileImport() { importTask?.cancel() }
    func dismissImportErrors() { importErrors = [] }

    /// One press starts a recording, the next press stops it and transcribes.
    private func toggleRecording() {
        Log.info("shortcut")
        if state == .recording {
            stopRecording()
        } else if state.canStartRecording {
            beginRecording()
        }
    }

    private func beginRecording() {
        guard !isLoadingModel, isModelReady, !isStartingRecording else { return }
        isStartingRecording = true
        Task {
            defer { isStartingRecording = false }
            guard await AudioRecorder.requestMicrophoneAccess() else {
                show(.failed("No mic access"))
                return
            }
            guard state.canStartRecording, !isLoadingModel else { return }
            await feeder?.value  // a cancelled recording may still be draining into the old session
            do {
                destination = Destination.frontmost
                try await transcriber.startSession()
                let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
                audioStream = continuation
                recorder.onProgress = { continuation.yield($0) }
                let recording = try recorder.start()
                feeder = Task { [transcriber] in
                    var consumed = 0
                    do {
                        for await available in stream {
                            while consumed < available {
                                try Task.checkCancellation()
                                let count = min(1600, available - consumed)
                                let chunk = try recording.readSamples(from: consumed, count: count)
                                await transcriber.append(chunk)
                                consumed += count
                            }
                        }
                    } catch is CancellationError {
                        // The cancellation path discards the recognizer session.
                    } catch {
                        await transcriber.fail(error)
                    }
                }
                startSession()
                state = .recording
                overlay?.show()
            } catch {
                audioStream?.finish()
                audioStream = nil
                await transcriber.discard()
                Log.info("Recorder start failed: \(error)")
                show(.failed(error is AudioRecorder.RecorderError ? error.localizedDescription : "Can’t record"))
            }
        }
    }

    private func stopRecording() {
        guard state == .recording else { return }
        let recording: RecordingFile
        do { recording = try recorder.stop() }
        catch {
            Log.info("Recorder stop failed: \(error)")
            audioStream?.finish()
            audioStream = nil
            feeder?.cancel()
            feeder = Task { [transcriber, feeder] in await feeder?.value; await transcriber.discard() }
            finishSession()
            show(.failed("Recording failed"))
            return
        }
        audioStream?.finish()
        audioStream = nil
        guard recording.sampleCount >= Transcriber.minimumSamples else {
            feeder = Task { [transcriber, feeder] in await feeder?.value; await transcriber.discard() }
            finishSession()
            state = .idle
            overlay?.hide()
            return
        }
        state = .transcribing
        transcription = Task { [feeder] in
            let started = Date()
            do {
                await feeder?.value
                try Task.checkCancellation()
                self.feeder = nil
                let text = try await transcriber.finish()
                guard !Task.isCancelled else { return }
                let inferenceMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
                let duration = recording.duration
                Log.info("finished \(String(format: "%.1f", duration))s recording \(inferenceMilliseconds) ms after stop, \(text.count) characters")
                finishSession()
                guard !text.isEmpty else {
                    state = .idle
                    overlay?.hide()
                    return
                }
                // Keep the original and audio even if paste delivery fails or is cancelled.
                let entry = HistoryEntry(
                    id: UUID(), date: recordingStarted, text: text,
                    destination: destination?.name ?? "", duration: duration,
                    inferenceMilliseconds: inferenceMilliseconds, delivery: .keptInHistory
                )
                try history.add(entry, recording: recording)
                let outcome = try await Paster.deliver(history.process(text).text, to: destination)
                Log.info("delivery: \(outcome)")
                try history.updateDelivery(id: entry.id, to: delivery(for: outcome))
                switch outcome {
                case .pasted:
                    state = .idle
                    overlay?.hide()
                case .copiedOnly:
                    show(.notice("Copied"))
                case .destinationChanged:
                    show(.notice("Kept in history"))
                }
            } catch is CancellationError {
                return
            } catch {
                Log.info("Transcription failed: \(error)")
                finishSession()
                show(.failed("Dictation failed"))
            }
        }
    }

    private func delivery(for outcome: Paster.Outcome) -> HistoryEntry.Delivery {
        switch outcome {
        case .pasted: return .pasted
        case .copiedOnly: return .copied
        case .destinationChanged: return .keptInHistory
        }
    }

    /// Watches for Escape and starts the meter/elapsed ticker for the duration of a dictation.
    private func startSession() {
        recordingStarted = Date()
        meter.elapsed = 0
        smoother.reset()
        meter.level = 0
        // Passive monitors rather than a Carbon hotkey: registering a hotkey while ⌃⌥Space is
        // physically held makes Carbon drop that key's release event, which left recordings stuck.
        // The global monitor needs Accessibility and misses this app's own windows, hence the local
        // one, which consumes the key so that one press never also acts on the window.
        escapeMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.isEscape else { return }
                Task { @MainActor in self?.cancel() }
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.isEscape, !Self.escapeBelongsToField(event.window?.firstResponder) else { return event }
                Task { @MainActor in self?.cancel() }
                return nil
            },
        ].compactMap { $0 }
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.meterInterval)
                guard let self, !Task.isCancelled else { return }
                if self.state == .recording {
                    self.smoother.tick(interval: 0.05)
                    self.meter.level = self.smoother.level
                    self.meter.elapsed = Date().timeIntervalSince(self.recordingStarted)
                }
            }
        }
    }

    /// Esc in a text field holding text is about that text, such as clearing a search, not about the dictation.
    static func escapeBelongsToField(_ responder: NSResponder?) -> Bool {
        guard let editor = responder as? NSTextView else { return false }
        return editor.isFieldEditor && !editor.string.isEmpty
    }

    private func finishSession() {
        for monitor in escapeMonitors { NSEvent.removeMonitor(monitor) }
        escapeMonitors = []
        meterTask?.cancel()
        meterTask = nil
    }

    /// Shows a transient message in the pill, then returns to idle so the hotkey keeps working.
    /// The pill truncates anything past about 16 characters, so details belong in the log.
    private func show(_ transient: State) {
        state = transient
        overlay?.show()
        overlay?.hide(after: Self.noticeDuration)
        Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard let self, self.state == transient else { return }
            self.state = .idle
        }
    }
}

#if DEBUG
extension DictationController {
    /// Sets what the views observe, for Xcode's canvas. Starts no audio, model load or hotkey.
    func showPreview(_ state: State, modelError: String? = nil, isShortcutInUse: Bool = false,
                     fileImport: FileImportStatus? = nil, importErrors: [String] = []) {
        isPreview = true
        self.state = state
        self.modelError = modelError
        self.isShortcutInUse = isShortcutInUse
        self.fileImport = fileImport
        self.importErrors = importErrors
        switch state {
        case .downloadingModel, .optimizingModel, .loadingModel: isLoadingModel = true
        default: isLoadingModel = false
        }
    }

    func showPreviewMeter(level: Float, elapsed: TimeInterval) {
        meter.level = level
        meter.elapsed = elapsed
    }
}
#endif
