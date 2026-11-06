#if DEBUG
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Development-only exports of the real app views with disposable preview fixtures.
@MainActor
public enum AppScreenshots {
    public struct Capture: Encodable {
        public let name: String
        public let title: String
        public let appearance: String
        public let file: String
        public let width: Int
        public let height: Int
        public let scale: Int
    }

    public static let names = [
        "dictionary", "dictionary-empty", "dictionary-import-errors", "dictionary-drop",
        "editor-add", "editor-edit", "editor-conflict",
        "menu-ready", "menu-downloading", "menu-loading", "menu-model-error",
        "menu-needs-accessibility", "menu-needs-microphone", "menu-reopen-to-paste",
        "pill-recording", "pill-transcribing", "pill-importing", "pill-copied", "pill-error",
    ]

    private enum Style { case window, menu, popover, pill }
    private struct Scene {
        let title: String
        let style: Style
        let view: AnyView
        let fixtures: PreviewFixtures
        var meter: Bool = false
    }

    @available(macOS 14.4, *)
    public static func export(to directory: URL, only: String? = nil) async throws -> [Capture] {
        let mode = "dark"
        var captures: [Capture] = []
        let folder = directory.appendingPathComponent(mode, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names where only == nil || only == name {
            let scene = makeScene(name)
            let image = try await render(scene)
            let file = "\(mode)/\(name).png"
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CaptureError("Could not encode \(file).")
            }
            try png.write(to: directory.appendingPathComponent(file), options: .atomic)
            captures.append(Capture(name: name, title: scene.title, appearance: mode, file: file,
                                    width: image.width, height: image.height, scale: scene.style == .popover ? 1 : 2))
            print("\(file)  \(image.width) × \(image.height)")
        }
        return captures
    }

    private static func makeScene(_ name: String) -> Scene {
        let fixtures = PreviewFixtures(empty: name == "dictionary-empty")
        let controller = fixtures.controller
        controller.showPreview(.idle)
        func scene(_ title: String, _ style: Style, _ view: some View, meter: Bool = false) -> Scene {
            Scene(title: title, style: style, view: AnyView(view), fixtures: fixtures, meter: meter)
        }
        switch name {
        case "dictionary", "dictionary-empty", "dictionary-import-errors", "dictionary-drop":
            if name == "dictionary-import-errors" {
                controller.showPreview(.idle, importErrors: ["Meeting.m4a: No speech detected."])
            }
            return scene("Dictionary", .window,
                DictionaryView(controller: controller).frame(width: 520, height: 380)
                    .overlay {
                        if name == "dictionary-drop" { AudioFileDropOverlay(isAvailable: true).padding(12) }
                    })
        case "editor-add":
            return scene("Add a replacement", .popover, DictionaryEditor(store: controller.dictionary,
                draft: DictionaryDraft(rule: DictionaryRule(target: "", aliases: []))))
        case "editor-edit":
            return scene("Edit a replacement", .popover, DictionaryEditor(store: controller.dictionary,
                draft: DictionaryDraft(rule: controller.dictionary.rules.first { $0.target == "Paraketto" }!)))
        case "editor-conflict":
            return scene("Conflicting spelling", .popover, DictionaryEditor(store: controller.dictionary,
                draft: DictionaryDraft(rule: DictionaryRule(target: "Another app", aliases: ["para keto"]))))
        case "pill-recording", "pill-transcribing":
            controller.showPreview(name == "pill-recording" ? .recording : .transcribing)
            return scene(name == "pill-recording" ? "Recording" : "Transcribing", .pill,
                         PillView(controller: controller), meter: true)
        case "pill-importing":
            controller.showPreview(.transcribing, fileImport: .init(filename: "Meeting.m4a", progress: 0.58))
            return scene("Importing audio", .pill, PillView(controller: controller))
        case "pill-copied":
            controller.showPreview(.notice("Copied"))
            return scene("Copied to clipboard", .pill, PillView(controller: controller))
        case "pill-error":
            controller.showPreview(.failed("No mic access"))
            return scene("Microphone unavailable", .pill, PillView(controller: controller))
        default:
            let title: String
            switch name {
            case "menu-downloading": controller.showPreview(.downloadingModel(0.42)); title = "Downloading the model"
            case "menu-loading": controller.showPreview(.loadingModel); title = "Loading the model"
            case "menu-model-error":
                controller.showPreview(.failed("Offline"), modelError: "Could not load model: The network connection was lost.")
                title = "Model setup failed"
            case "menu-needs-accessibility": title = "Accessibility permission"
            case "menu-needs-microphone": title = "Microphone permission"
            case "menu-reopen-to-paste": title = "Reopen after granting access"
            default: title = "Ready to dictate"
            }
            return scene(title, .menu, MenuContent(controller: controller,
                isAccessibilityTrusted: { name != "menu-needs-accessibility" },
                isMicrophoneDenied: { name == "menu-needs-microphone" },
                canPostEvents: { name != "menu-reopen-to-paste" }))
        }
    }

    @available(macOS 14.4, *)
    private static func render(_ scene: Scene) async throws -> CGImage {
        let cocoaAppearance = NSAppearance(named: .darkAqua)!
        let previousAppearance = NSApplication.shared.appearance
        NSApplication.shared.appearance = cocoaAppearance
        defer { NSApplication.shared.appearance = previousAppearance }
        let hosting = NSHostingController(rootView: scene.view
            .environment(\.colorScheme, .dark)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .environment(\.locale, Locale(identifier: "en_US")))
        hosting.view.appearance = cocoaAppearance
        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: scene.style == .window ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = cocoaAppearance
        window.title = scene.title
        window.isOpaque = scene.style == .window
        window.backgroundColor = scene.style == .pill || scene.style == .popover ? .clear : .windowBackgroundColor
        window.hasShadow = true
        window.center()
        var popover: NSPopover?
        var target = window
        if scene.style == .popover {
            let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
            window.contentView = anchor
            window.setContentSize(anchor.frame.size)
            window.orderFrontRegardless()
            let editor = NSPopover()
            editor.appearance = cocoaAppearance
            editor.behavior = .applicationDefined
            editor.contentViewController = hosting
            editor.contentSize = size
            editor.show(relativeTo: NSRect(x: 188, y: 0, width: 24, height: 24), of: anchor, preferredEdge: .minY)
            popover = editor
            guard let editorWindow = hosting.view.window else { throw CaptureError("Could not show the editor popover.") }
            target = editorWindow
        } else {
            window.contentViewController = hosting
            if scene.style == .menu {
                hosting.view.wantsLayer = true
                hosting.view.layer?.cornerRadius = 9
                hosting.view.layer?.masksToBounds = true
                window.isOpaque = false
                window.backgroundColor = .clear
                hosting.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            window.makeKeyAndOrderFront(nil)
        }
        defer { popover?.close(); window.close() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Let SwiftUI mount AppKit-backed controls and settle its layout before capturing.
        try await Task.sleep(for: .milliseconds(300))
        if scene.meter {
            for tick in 0..<36 {
                let time = Double(tick) * 0.05
                let level = abs(sin(time * 5)) * (0.35 + 0.65 * abs(sin(time * 0.9)))
                scene.fixtures.controller.showPreviewMeter(level: Float(level), elapsed: time)
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        target.contentView?.layoutSubtreeIfNeeded()
        target.makeFirstResponder(nil)
        target.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        // macOS 14.4+ exposes this process's own windows without requesting desktop access.
        let content = try await SCShareableContent.currentProcess
        guard let ownWindow = content.windows.first(where: { $0.windowID == CGWindowID(target.windowNumber) }) else {
            throw CaptureError("The preview window is not available to capture. Run from a logged-in macOS desktop.")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(target.frame.width * 2)
        configuration.height = Int(target.frame.height * 2)
        configuration.scalesToFit = true
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
        return try trimmed(image, scale: scene.style == .popover ? 1 : 2)
    }

    /// Remove transparent panel margins; leave only eight logical points around the native content.
    private static func trimmed(_ image: CGImage, scale: Int) throws -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            let pointer = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw CaptureError("Could not allocate the screenshot bitmap.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var left = width, right = 0, top = height, bottom = 0
        for y in 0..<height {
            for x in 0..<width where pointer[(y * width + x) * 4 + 3] > 2 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top, let normalized = context.makeImage(),
              let crop = normalized.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else {
            throw CaptureError("The screenshot is empty.")
        }
        let padding = 8 * scale
        guard let output = CGContext(data: nil, width: crop.width + padding * 2, height: crop.height + padding * 2,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError("Could not allocate the PNG canvas.")
        }
        output.setShadow(offset: CGSize(width: 0, height: -1.5 * Double(scale)), blur: 5 * Double(scale), color: CGColor(gray: 0, alpha: 0.2))
        output.draw(crop, in: CGRect(x: padding, y: padding, width: crop.width, height: crop.height))
        guard let result = output.makeImage() else { throw CaptureError("Could not create the PNG.") }
        return result
    }

    private struct CaptureError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif
