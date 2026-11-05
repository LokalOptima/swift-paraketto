import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptRow: View {
    let entry: HistoryEntry
    @ObservedObject var store: HistoryStore
    let dictionary: DictionaryStore
    let removeAlias: (String, UUID) -> Void
    let delete: () -> Void
    /// Where the active search matches this transcript.
    let matches: [NSRange]
    @Binding var expanded: Bool
    @State private var draft: DictionaryDraft?
    @State private var draftAnchor = CGRect.zero
    @State private var isTruncated = false
    @State private var isHovered = false
    @State private var copied = false
    @State private var copySequence = 0
    @FocusState private var focusedAction: Action?
    @ObservedObject private var scrollActivity = ScrollActivity.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private enum Action: Hashable { case expand, download, copy, delete }
    private var showsActions: Bool {
        (isHovered && !scrollActivity.isScrolling) || focusedAction != nil || voiceOverEnabled
    }

    private var canExpand: Bool { isTruncated || expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                TranscriptText(result: entry.processed, expanded: expanded, matches: matches,
                               isTruncated: $isTruncated, dictionaryAction: handle)
                    .popover(item: $draft, attachmentAnchor: .rect(.rect(draftAnchor)), arrowEdge: .bottom) {
                        DictionaryEditor(store: dictionary, draft: $0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { toggleExpansion() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .frame(width: 24, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .focused($focusedAction, equals: .expand)
                .disabled(!canExpand)
                .accessibilityHidden(!canExpand)
                .accessibilityLabel(expanded ? "Collapse transcript" : "Expand transcript")
                .help(expanded ? "Collapse transcript" : "Expand transcript")
                .opacity(canExpand && showsActions ? 1 : 0)
                .allowsHitTesting(canExpand && showsActions)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsActions)
            }
            HStack(spacing: 8) {
                Text(entry.date.formatted(.dateTime.hour().minute()))
                    .monospacedDigit()
                if let filename = entry.sourceFilename {
                    Text("·")
                    Text(filename).lineLimit(1).truncationMode(.middle)
                } else if !entry.destination.isEmpty {
                    Text("·")
                    Text(entry.destination)
                }
                if entry.delivery == .copied || entry.delivery == .keptInHistory {
                    Text("·")
                    Text(entry.delivery == .copied ? "copied" : "not pasted")
                }
                if !matches.isEmpty {
                    Text("·")
                    Text("^[\(matches.count) match](inflect: true)")
                }
                Spacer()
                actions
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .task(id: copySequence) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.5)) }
            catch { return }
            copied = false
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { downloadRecording() } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .focused($focusedAction, equals: .download)
            .accessibilityLabel("Download recording")
            .help("Download recording")

            Button { copyTranscript() } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .foregroundStyle(copied ? Color(nsColor: .systemGreen) : .secondary)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: copied)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .focused($focusedAction, equals: .copy)
            .accessibilityLabel(copied ? "Copied to clipboard" : "Copy transcript")
            .help(copied ? "Copied!" : "Copy transcript")

            Button(role: .destructive) {
                delete()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .focused($focusedAction, equals: .delete)
            .accessibilityLabel("Delete transcript and recording")
            .help("Delete transcript and recording")
        }
        .font(.system(size: 13))
        // Keep the reserved width so revealing controls never shifts the metadata.
        .opacity(showsActions ? 1 : 0)
        .allowsHitTesting(showsActions)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsActions)
    }

    /// Asks where to save because writing straight to Downloads would need a permission of its own.
    private func downloadRecording() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = store.recordingFilename(for: entry)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        Task {
            let response = if let window = NSApplication.shared.mainWindow {
                await panel.beginSheetModal(for: window)
            } else {
                await panel.begin()
            }
            guard response == .OK, let destination = panel.url else { return }
            do {
                try await store.saveRecording(of: entry, to: destination)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(entry.displayText, forType: .string) {
            copied = true
            copySequence += 1
        }
    }

    private func handle(_ action: TranscriptDictionaryAction, anchor: CGRect) {
        draftAnchor = anchor
        switch action {
        case .add(let source):
            draft = DictionaryDraft(rule: DictionaryRule(target: "", aliases: [source]))
        case .edit(let id):
            draft = dictionary.rules.first { $0.id == id }.map { DictionaryDraft(rule: $0) }
        case .remove(let id, let alias):
            removeAlias(alias, id)
        }
    }

    private func toggleExpansion() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
    }
}

/// Whether a scroll is under way, when hover means nothing: rows passing under a still pointer count
/// as hovered, which would make their actions flicker past. Separate from the rows' parent so that
/// starting and stopping re-renders only the rows, not the whole list.
@MainActor
final class ScrollActivity: ObservableObject {
    static let shared = ScrollActivity()

    /// Short, because the glide after the fingers lift can take a second and the actions shouldn't wait for it.
    private static let waitAfterLift: Duration = .milliseconds(200)
    /// The lift never arrives if another window comes up under the fingers, which would leave the actions hidden.
    private static let liftTimeout: Duration = .seconds(2)

    @Published private(set) var isScrolling = false
    private var hoverReturn: Task<Void, Never>?
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.scrolled(phase: event.phase, momentumPhase: event.momentumPhase)
            return event
        }
    }

    func scrolled(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        // Older mice report no phases, so each notch both starts a scroll and ends it.
        let isWheelNotch = phase.isEmpty && momentumPhase.isEmpty
        if phase == .began || phase == .changed || isWheelNotch {
            // Events arrive at the display's rate, and each assignment would re-render the rows.
            if !isScrolling { isScrolling = true }
            endScrolling(after: isWheelNotch ? Self.waitAfterLift : Self.liftTimeout)
        } else if isScrolling, phase == .ended || phase == .cancelled {
            endScrolling(after: Self.waitAfterLift)
        }
    }

    private func endScrolling(after wait: Duration) {
        hoverReturn?.cancel()
        hoverReturn = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            isScrolling = false
        }
    }
}
