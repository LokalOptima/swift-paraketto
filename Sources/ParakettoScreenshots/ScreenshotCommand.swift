import AppKit
import CoreImage
import ParakettoKit

@main
@MainActor
struct ScreenshotCommand {
    static func main() {
        #if DEBUG
        var output = ".build/screenshots"
        var only: String?
        var arguments = Array(CommandLine.arguments.dropFirst())
        do {
            while let argument = arguments.first {
                arguments.removeFirst()
                if argument == "--help" {
                    print("Usage: paraketto-screenshots [--output DIRECTORY] [--only SCREEN] [--list]")
                    return
                }
                if argument == "--list" {
                    print(AppScreenshots.names.joined(separator: "\n"))
                    return
                }
                guard let value = arguments.first, !value.hasPrefix("--") else {
                    throw ScreenshotCommandError("Missing value for \(argument).")
                }
                arguments.removeFirst()
                switch argument {
                case "--output": output = value
                case "--only": only = value
                default: throw ScreenshotCommandError("Unknown option: \(argument).")
                }
            }
            if let only, !AppScreenshots.names.contains(only) {
                throw ScreenshotCommandError("Unknown screen: \(only). Use --list to see screen names.")
            }
            guard #available(macOS 14.4, *) else {
                throw ScreenshotCommandError("Screenshot export requires macOS 14.4 or later.")
            }
            let destination = URL(fileURLWithPath: output, isDirectory: true)
            let template = try String(contentsOf: Bundle.module.url(forResource: "showcase", withExtension: "html")!, encoding: .utf8)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    let captures = try await AppScreenshots.export(to: destination, only: only)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(captures)
                    try data.write(to: destination.appendingPathComponent("screenshots.json"), options: .atomic)
                    try writeLogo(to: destination.appendingPathComponent("logo.png"))
                    let html = template.replacingOccurrences(of: "__SCREENSHOTS__", with: String(decoding: data, as: UTF8.self))
                    try html.write(to: destination.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
                    print("Saved \(captures.count) PNGs and showcase: \(destination.appendingPathComponent("index.html").path)")
                    exit(EXIT_SUCCESS)
                } catch { fail(error) }
            }
            app.run()
        } catch { fail(error) }
        #else
        FileHandle.standardError.write(Data("Use make screenshots (debug builds include the preview fixtures).\n".utf8))
        exit(EXIT_FAILURE)
        #endif
    }

    private static func writeLogo(to destination: URL) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = CIImage(contentsOf: root.appendingPathComponent("Resources/paraketto.png")) else {
            throw ScreenshotCommandError("Could not read the app's parakeet artwork. Run from the source checkout.")
        }
        let mask = source.applyingFilter("CIMaskToAlpha")
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 64 / source.extent.width])
        guard let image = CIContext().createCGImage(mask, from: mask.extent),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ScreenshotCommandError("Could not export the parakeet logo.")
        }
        try data.write(to: destination, options: .atomic)
    }

    private static func fail(_ error: Error) -> Never {
        FileHandle.standardError.write(Data("Screenshots: \(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

private struct ScreenshotCommandError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
