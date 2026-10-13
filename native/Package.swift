// swift-tools-version: 5.10
import PackageDescription

// TBD native modules. Owned Teal Brick code only (no donor packages inside).
let package = Package(
    name: "TBDNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TBDDesign", targets: ["TBDDesign"]),
        .library(name: "TBDModels", targets: ["TBDModels"]),
        .library(name: "TBDSpeech", targets: ["TBDSpeech"]),
        .library(name: "TBDListening", targets: ["TBDListening"]),
        .executable(name: "tbd-listen", targets: ["TBDListenCLI"]),
    ],
    dependencies: [
        // SQLite storage for the Listening library (MIT).
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Parakeet STT and offline diarization on CoreML/ANE (Apache-2.0). Pinned exact:
        // model file names, the download API and diarizer clustering change between minors.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.7"),
        // FluidAudio's module exposes yyjson under current toolchains; hold the same pin.
        .package(url: "https://github.com/ibireme/yyjson.git", exact: "0.12.0"),
        // WhisperKit, the multilingual alternative engine (MIT). Pinned exact.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "0.18.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "TBDDesign"),
        .target(name: "TBDModels"),
        .target(name: "TBDSpeechObjC"),
        .target(name: "TBDSpeech", dependencies: [
            "TBDModels",
            "TBDSpeechObjC",
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "yyjson", package: "yyjson"),
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
        ]),
        .target(name: "TBDListening", dependencies: ["TBDSpeech", "TBDDesign", "TBDModels"]),
        .executableTarget(name: "TBDListenCLI", dependencies: [
            "TBDSpeech",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], exclude: ["README.md"]),
        .testTarget(name: "TBDModelsTests", dependencies: ["TBDModels"]),
        // Host wiring: every Settings section and menu action the host sends resolves (PARITY WP1).
        .testTarget(name: "TBDListeningTests", dependencies: ["TBDListening"]),
        .testTarget(name: "TBDSpeechTests", dependencies: [
            "TBDSpeech",
            // CLI argument parsing and JSON shape tests (`@testable import TBDListenCLI`).
            "TBDListenCLI",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
    ]
)
