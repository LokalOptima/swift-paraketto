import SwiftUI

struct MenuContent: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var shortcuts: ShortcutSettings
    private let isAccessibilityTrusted: () -> Bool
    private let isMicrophoneDenied: () -> Bool
    private let canPostEvents: () -> Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    init(controller: DictationController, isAccessibilityTrusted: @escaping () -> Bool = { Paster.isAccessibilityTrusted },
         isMicrophoneDenied: @escaping () -> Bool = { AudioRecorder.isMicrophoneDenied },
         canPostEvents: @escaping () -> Bool = { Paster.canPostEvents }) {
        self.controller = controller
        shortcuts = controller.shortcuts
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.isMicrophoneDenied = isMicrophoneDenied
        self.canPostEvents = canPostEvents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if controller.state == .loadingModel || controller.state == .optimizingModel {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(statusLabel)
                }
                Text(statusLabel)
                    .fontWeight(.medium)
                    .foregroundStyle(controller.state == .idle && dictationBlocker == nil ? Color(nsColor: .systemGreen) : .primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                ShortcutRecorder(settings: shortcuts)
                    .fixedSize()
                    .disabled(controller.state.isCancellable || controller.isStartingRecording)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 8)

            if case .downloadingModel(let fraction) = controller.state {
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(statusLabel)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            if let error = controller.modelError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
                Button("Retry") { controller.retryModelLoad() }
                    .disabled(controller.isLoadingModel)
            }

            if controller.isShortcutInUse {
                Text("Another app uses this shortcut. Click it to choose a different one.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }

            if isMicrophoneDenied() {
                Divider().padding(.vertical, 4)
                Button("Grant Microphone…") {
                    dismiss()
                    AudioRecorder.openMicrophoneSettings()
                }
            }

            if !isAccessibilityTrusted() {
                Divider().padding(.vertical, 4)
                Button("Grant Accessibility…") {
                    dismiss()
                    Paster.openAccessibilitySettings()
                }
                Text("Without it, text is copied but not pasted, and Esc can't cancel a recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            } else if !canPostEvents() {
                Divider().padding(.vertical, 4)
                Text("Quit and reopen Paraketto to enable pasting after granting Accessibility. Text is copied until then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }

            Divider().padding(.vertical, 4)
            Button {
                controller.showDictionary(using: openWindow)
            } label: {
                Text("Dictionary")
            }

            Divider().padding(.vertical, 4)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                MenuActionLabel(title: "Quit Paraketto", shortcut: "⌘Q")
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(MenuActionStyle())
        .padding(6)
        .frame(width: 260)
        .onAppear { controller.closeMenu = { dismiss() } }
        .onDisappear { controller.closeMenu = nil }
    }

    /// Why the shortcut can't dictate, although the app itself is ready.
    private var dictationBlocker: String? {
        if isMicrophoneDenied() { return "No mic access" }
        if isAccessibilityTrusted(), !canPostEvents() { return "Reopen to paste" }
        return controller.isShortcutInUse ? "Shortcut in use" : nil
    }

    private var statusLabel: String {
        switch controller.state {
        case .downloadingModel: return "Downloading…"
        case .loadingModel: return "Loading…"
        case .optimizingModel: return "Optimizing…"
        case .idle: return dictationBlocker ?? controller.state.label
        default: return controller.state.label
        }
    }
}

#if DEBUG
#Preview("Ready") { MenuPreview(.idle) }
#Preview("Needs Accessibility") { MenuPreview(.idle, isAccessibilityTrusted: false) }
#Preview("Needs Microphone") { MenuPreview(.idle, isMicrophoneDenied: true) }
#Preview("Reopen to paste") { MenuPreview(.idle, canPostEvents: false) }
#Preview("Shortcut in use") { MenuPreview(.idle, isShortcutInUse: true) }
#Preview("Downloading") { MenuPreview(.downloadingModel(0.42)) }
#Preview("Optimizing") { MenuPreview(.optimizingModel) }
#Preview("Loading") { MenuPreview(.loadingModel) }
#Preview("Recording") { MenuPreview(.recording) }
#Preview("Transcribing") { MenuPreview(.transcribing) }
#Preview("Notice") { MenuPreview(.notice("Copied")) }
#Preview("Model failed") {
    MenuPreview(.failed("The network connection was lost."),
                modelError: "Could not load model: The network connection was lost.")
}
#endif
