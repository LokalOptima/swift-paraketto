import SwiftUI

struct MenuContent: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var shortcuts: ShortcutSettings
    private let isAccessibilityTrusted: () -> Bool
    @Environment(\.openWindow) private var openWindow

    init(controller: DictationController, isAccessibilityTrusted: @escaping () -> Bool = { Paster.isAccessibilityTrusted }) {
        self.controller = controller
        shortcuts = controller.shortcuts
        self.isAccessibilityTrusted = isAccessibilityTrusted
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
                    .foregroundStyle(controller.state == .idle ? Color(nsColor: .systemGreen) : .primary)
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

            if !isAccessibilityTrusted() {
                Divider().padding(.vertical, 4)
                Button("Grant Accessibility…") { Paster.openAccessibilitySettings() }
            }

            Divider().padding(.vertical, 4)
            Button {
                controller.windowTab = .transcripts
                openWindow(id: "history")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Text("Transcripts")
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
    }

    private var statusLabel: String {
        switch controller.state {
        case .downloadingModel: return "Downloading…"
        case .loadingModel: return "Loading…"
        case .optimizingModel: return "Optimizing…"
        default: return controller.state.label
        }
    }
}

#if DEBUG
#Preview("Ready") { MenuPreview(.idle) }
#Preview("Needs Accessibility") { MenuPreview(.idle, isAccessibilityTrusted: false) }
#Preview("Downloading") { MenuPreview(.downloadingModel(0.42)) }
#Preview("Optimizing") { MenuPreview(.optimizingModel) }
#Preview("Loading") { MenuPreview(.loadingModel) }
#Preview("Recording") { MenuPreview(.recording) }
#Preview("Transcribing") { MenuPreview(.transcribing) }
#Preview("Notice") { MenuPreview(.notice("Kept in history")) }
#Preview("Model failed") {
    MenuPreview(.failed("The network connection was lost."),
                modelError: "Could not load model: The network connection was lost.")
}
#endif
