import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var controller: DictationController
    @StateObject private var secondaryClick = MenuBarSecondaryClick()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch controller.state {
            case .idle, .notice:
                Image(nsImage: ParakeetArtwork.menuIcon)
            case .recording:
                Image(nsImage: ParakeetArtwork.recordingIcon)
            default:
                Image(systemName: controller.state.symbolName)
            }
        }
        .accessibilityLabel("Paraketto: \(controller.state.label)")
        .onAppear {
            secondaryClick.start {
                controller.windowTab = .transcripts
                openWindow(id: "history")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        .onDisappear { secondaryClick.stop() }
    }
}
