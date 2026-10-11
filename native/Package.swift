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
    dependencies: [],
    targets: [
        .target(name: "TBDDesign"),
        .target(name: "TBDModels"),
        .target(name: "TBDSpeech", dependencies: ["TBDModels"]),
        .target(name: "TBDListening", dependencies: ["TBDSpeech", "TBDDesign", "TBDModels"]),
        .executableTarget(name: "TBDListenCLI", dependencies: ["TBDSpeech"]),
        .testTarget(name: "TBDModelsTests", dependencies: ["TBDModels"]),
        .testTarget(name: "TBDSpeechTests", dependencies: ["TBDSpeech"]),
    ]
)
