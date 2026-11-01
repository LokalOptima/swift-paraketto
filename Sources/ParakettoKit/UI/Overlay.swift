import AppKit
import SwiftUI

/// A floating, click-through pill above the Dock on the screen the cursor is on.
/// While recording it shows only a scrolling level meter; notices and errors share the same card.
///
/// The panel has a fixed, transparent size and the pill draws centred inside it, so
/// state changes never resize the window.
@MainActor
final class Overlay {
    static let panelSize = NSSize(width: 420, height: 84)
    /// The visible card never changes size; text inside it is truncated instead.
    static let pillSize = CGSize(width: 160, height: 40)

    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    init(controller: DictationController) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hostingView = NSHostingView(rootView: PillView(controller: controller))
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    func show() {
        hideTask?.cancel()
        position()
        panel.orderFrontRegardless()
    }

    func hide(after delay: Duration = .zero) {
        hideTask?.cancel()
        guard delay > .zero else {
            panel.orderOut(nil)
            return
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.midX - Self.panelSize.width / 2, y: visible.minY + 12))
    }
}
