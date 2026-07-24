// swift-tools-version: 6.0
import PackageDescription

// WhisperNotion — local real-time STT → Notion menu-bar app.
// This package holds the engine-side libraries, validation CLIs, and the
// SwiftUI menu-bar app. The app bundle is assembled by scripts/make-app.sh
// because SwiftPM does not copy Info.plist or entitlements into the product.
//
// Distribution floor is macOS 14.4 (Core Audio process taps). The package
// platform is .v14; 14.4-specific and macOS 26-specific (Apple SpeechAnalyzer)
// code is guarded with `if #available` at the call site.
let package = Package(
    name: "WhisperNotion",
    platforms: [
        // v1 is Apple SpeechAnalyzer-only (macOS 26). The WhisperKit fallback
        // backend stays in the repo but is not wired into the app.
        .macOS("26.0")
    ],
    products: [
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "NotionSync", targets: ["NotionSync"]),
        .library(name: "Summarization", targets: ["Summarization"]),
        .executable(name: "wn-validate", targets: ["wn-validate"]),
        .executable(name: "wn-live", targets: ["wn-live"]),
        .executable(name: "WhisperNotionApp", targets: ["WhisperNotionApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "TranscriptionKit",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .target(
            name: "AudioCapture",
            dependencies: ["TranscriptionKit"]
        ),
        .target(
            name: "NotionSync"
        ),
        .target(
            name: "Summarization"
        ),
        .executableTarget(
            name: "wn-validate",
            dependencies: ["TranscriptionKit"]
        ),
        .executableTarget(
            name: "wn-live",
            dependencies: ["TranscriptionKit", "AudioCapture"]
        ),
        .executableTarget(
            name: "WhisperNotionApp",
            dependencies: ["TranscriptionKit", "AudioCapture", "NotionSync", "Summarization"]
        ),
        .testTarget(
            name: "TranscriptionKitTests",
            dependencies: ["TranscriptionKit"]
        ),
        .testTarget(
            name: "NotionSyncTests",
            dependencies: ["NotionSync"]
        ),
        .testTarget(
            name: "SummarizationTests",
            dependencies: ["Summarization"]
        ),
        .testTarget(
            name: "AudioCaptureTests",
            dependencies: ["AudioCapture", "TranscriptionKit"]
        )
    ]
)
