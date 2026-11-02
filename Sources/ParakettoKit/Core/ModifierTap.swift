import AppKit
import Carbon.HIToolbox

/// Fires when a single modifier key is tapped on its own: pressed and released within
/// `maxHold` seconds with no other input in between, so Option+letter typing is ignored.
/// Carbon hotkeys cannot bind a bare modifier, so this watches modifier changes. macOS delivers
/// those without the Accessibility permission but withholds other keys, so input is counted instead.
@MainActor
final class ModifierTap {
    private static let maxHold: TimeInterval = 0.6

    private let keyCode: UInt16
    private let flag: NSEvent.ModifierFlags
    private let inputCount: () -> UInt32
    private let onTap: () -> Void
    private var monitors: [Any] = []
    private var pressedAt: Date?
    private var inputCountAtPress: UInt32 = 0
    private var interrupted = false

    init(_ key: ModifierKey, inputCount: @escaping () -> UInt32 = ModifierTap.systemInputCount,
         onTap: @escaping () -> Void) {
        keyCode = key.keyCode
        flag = key.flag
        self.inputCount = inputCount
        self.onTap = onTap
        // A global monitor only sees events sent to other apps, so this app's windows need a local one.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            Task { @MainActor in self?.flagsChanged(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            Task { @MainActor in self?.flagsChanged(event) }
            return event
        }) { monitors.append(local) }
        Log.info("Modifier tap \(key.label) armed")
    }

    deinit {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
    }

    /// Key presses and clicks so far in this login session. Reading the count needs no permission.
    nonisolated static func systemInputCount() -> UInt32 {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown]
        return types.reduce(0) { $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1) }
    }

    func flagsChanged(_ event: NSEvent) {
        guard event.keyCode == keyCode else {
            // Another modifier joined or left while ours is down: treat it as a chord, not a tap.
            if pressedAt != nil { interrupted = true }
            return
        }
        if event.modifierFlags.contains(flag) {
            pressedAt = Date()
            inputCountAtPress = inputCount()
            interrupted = false
        } else if let pressedAt {
            self.pressedAt = nil
            if !interrupted, inputCount() == inputCountAtPress, Date().timeIntervalSince(pressedAt) <= Self.maxHold {
                onTap()
            }
        }
    }
}
