import SwiftUI

public enum ParakettoMain {
    @MainActor
    public static func main() {
        if CommandLine.arguments.contains("--prepare-models") {
            let cachedOnly = CommandLine.arguments.contains("--cached-only")
            Task.detached {
                do {
                    try await ModelPreparation.run(cachedOnly: cachedOnly)
                    exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(Data("Model preparation failed: \(error.localizedDescription)\n".utf8))
                    exit(EXIT_FAILURE)
                }
            }
            dispatchMain()
        } else {
            ParakettoApp.main()
        }
    }
}

struct ParakettoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            MenuBarLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)

        Window("Dictionary", id: "dictionary") {
            DictionaryView(controller: appDelegate.controller)
                // Cmd-Tab only lists regular apps, so be one while this window is open.
                .onAppear { NSApplication.shared.setActivationPolicy(.regular) }
                .onDisappear { NSApplication.shared.setActivationPolicy(.accessory) }
        }
        .defaultSize(width: 560, height: 480)
    }
}

extension DictationController {
    /// The order matters. A window-style menu stays open until told otherwise, and closing it after the
    /// window opens can send the app to the background. Becoming regular has to come before activating,
    /// or the app stays last in Cmd-Tab because only a regular app's activation moves it up.
    func showDictionary(using openWindow: OpenWindowAction) {
        closeMenu?()
        NSApplication.shared.setActivationPolicy(.regular)
        openWindow(id: "dictionary")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// Starts dictation at launch. The menu content only exists while the menu is open,
/// so the hotkey and model load cannot be tied to it.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    #if DEBUG
    @MainActor private lazy var previewData = PreviewFixtures()
    #endif
    @MainActor lazy var controller: DictationController = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return previewData.controller
        }
        #endif
        return DictationController()
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        #endif
        controller.start()
    }
}
