import AppKit
import SwiftUI

/// A button that captures the next lone modifier tap or key combination as the shortcut.
struct ShortcutRecorder: View {
    @ObservedObject var settings: ShortcutSettings
    @State private var monitors: [Any] = []
    @State private var pendingModifier: UInt16?
    @State private var rejected = false
    @State private var capturedLabel: String?
    @State private var heldKey: NSEvent?
    @State private var isHovered = false
    @State private var hitArea = NSView()

    var body: some View {
        Button {
            settings.isRecording ? stop() : start()
        } label: {
            Text(buttonTitle)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(rejected ? Color.red : settings.isRecording ? .blue : Color.primary.opacity(isHovered ? 0.5 : 0.3),
                                      lineWidth: settings.isRecording ? 1.5 : 1)
                }
                .background(ShortcutButtonHitArea(view: hitArea).allowsHitTesting(false))
        }
        .buttonStyle(.plain)
        .foregroundStyle(rejected ? Color.red : isWaitingForInput ? .secondary : .primary)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Change dictation shortcut")
        .accessibilityValue(captureDescription)
        .help(rejected ? "This shortcut needs a held modifier or a function key. Esc cancels." : "Click to change the shortcut. Tap a modifier or press a combination; Esc cancels.")
        .font(.callout)
        .onDisappear(perform: stop)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private var buttonTitle: String {
        settings.isRecording ? capturedLabel ?? "…" : savedTitle
    }

    private var isWaitingForInput: Bool { settings.isRecording && capturedLabel == nil }

    private var captureDescription: String {
        guard settings.isRecording else { return settings.shortcut.label }
        guard !isWaitingForInput else { return "Waiting for a shortcut" }
        return "\(buttonTitle), \(rejected ? "invalid shortcut" : "recording shortcut")"
    }

    private var savedTitle: String {
        switch settings.shortcut {
        case .tap(let key): return key.label
        case .chord(let chord): return chord.label
        }
    }

    private func start() {
        settings.isRecording = true
        rejected = false
        pendingModifier = nil
        capturedLabel = nil
        heldKey = nil
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if event.type == .keyUp {
                if heldKey?.keyCode == event.keyCode { heldKey = nil }
                return nil
            }
            capturedLabel = Chord.label(for: event)
            heldKey = event
            pendingModifier = nil
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                stop()
            } else if let chord = Chord.from(event) {
                settings.shortcut = .chord(chord)
                stop()
            } else {
                rejected = true
            }
            return nil
        }
        let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard let key = ModifierKey(keyCode: event.keyCode) else { return event }
            if let heldKey, let chord = Chord.from(heldKey, modifiers: event.modifierFlags) {
                settings.shortcut = .chord(chord)
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            if flags.contains(key.flag) {
                let isLoneModifier = flags.rawValue.nonzeroBitCount == 1
                pendingModifier = isLoneModifier ? key.keyCode : nil
                capturedLabel = isLoneModifier ? key.label : Chord.modifierLabel(flags)
                rejected = !isLoneModifier
            } else if pendingModifier == key.keyCode, flags.isEmpty {
                settings.shortcut = .tap(key)
                stop()
            }
            return event
        }
        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            if event.window !== hitArea.window || !hitArea.bounds.contains(hitArea.convert(event.locationInWindow, from: nil)) {
                stop()
            }
            return event
        }
        monitors = [keys, flags, clicks].compactMap { $0 }
    }

    private func stop() {
        guard settings.isRecording || !monitors.isEmpty else { return }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        pendingModifier = nil
        capturedLabel = nil
        heldKey = nil
        rejected = false
        settings.isRecording = false
    }
}

/// Native coordinates let click-away cancellation work anywhere in the menu.
private struct ShortcutButtonHitArea: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
