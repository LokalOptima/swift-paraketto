import AppKit
import SwiftUI

/// A button that captures the next lone modifier tap or key combination as the shortcut.
struct ShortcutRecorder: View {
    @ObservedObject var settings: ShortcutSettings
    @State private var monitors: [Any] = []
    @State private var pendingModifier: UInt16?
    @State private var rejected = false
    @State private var isHovered = false

    var body: some View {
        Button {
            settings.isRecording ? stop() : start()
        } label: {
            Text(settings.isRecording ? (rejected ? "Add a modifier…" : "Press a key…") : settings.shortcut.label)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(settings.isRecording ? Color.accentColor.opacity(0.15)
                              : Color.primary.opacity(isHovered ? 0.08 : 0))
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(settings.isRecording ? (rejected ? Color.red : .primary) : .secondary)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Change dictation shortcut")
        .accessibilityValue(settings.isRecording ? "Waiting for a shortcut" : settings.shortcut.label)
        .help(rejected ? "A plain key would block typing. Add a modifier, or use a function key." : "Click to change the shortcut. Tap a modifier or press a combination; Esc cancels.")
        .onDisappear(perform: stop)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func start() {
        settings.isRecording = true
        rejected = false
        pendingModifier = nil
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
            if event.modifierFlags.contains(key.flag) {
                pendingModifier = key.keyCode
            } else if pendingModifier == key.keyCode {
                settings.shortcut = .tap(key)
                stop()
            }
            return event
        }
        monitors = [keys, flags].compactMap { $0 }
    }

    private func stop() {
        guard settings.isRecording || !monitors.isEmpty else { return }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        pendingModifier = nil
        rejected = false
        settings.isRecording = false
    }
}
