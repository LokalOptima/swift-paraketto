// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Paraketto",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ParakettoKit", targets: ["ParakettoKit"]),
    ],
    targets: [
        // Parakeet TDT inference with Core ML: model download, mel, encoder, greedy TDT decode, VAD segmentation.
        .target(
            name: "ParakeetTDT",
            path: "Sources/ParakeetTDT",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app itself, as a library so Xcode can preview its views and Paraketto.xcodeproj can link it.
        .target(
            name: "ParakettoKit",
            dependencies: ["ParakeetTDT"],
            path: "Sources/ParakettoKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Only the process entry point, for `swift build` and `make bundle`.
        .executableTarget(
            name: "ParakettoLauncher",
            dependencies: ["ParakettoKit"],
            path: "Sources/ParakettoLauncher",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command-line transcription for testing and benchmarking against reference transcripts.
        .executableTarget(
            name: "paraketto-cli",
            dependencies: ["ParakeetTDT"],
            path: "Sources/ParakettoCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "paraketto-screenshots",
            dependencies: ["ParakettoKit"],
            path: "Sources/ParakettoScreenshots",
            resources: [.copy("showcase.html")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ParakettoTests",
            dependencies: ["ParakeetTDT", "ParakettoKit"],
            path: "tests/swift",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
