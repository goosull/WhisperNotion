// swift-tools-version: 6.0
import PackageDescription

// WhisperNotion — local real-time STT → Notion menu-bar app.
// This package holds the engine-side libraries and the Phase -1 validation CLI.
// The SwiftUI menu-bar .app target is added later via an Xcode project that
// depends on these libraries (Info.plist / entitlements / bundle need Xcode).
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
            dependencies: ["TranscriptionKit", "AudioCapture"]
        ),
        .testTarget(
            name: "TranscriptionKitTests",
            dependencies: ["TranscriptionKit"]
        )
    ]
)
