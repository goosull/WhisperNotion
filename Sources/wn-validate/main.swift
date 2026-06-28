import Foundation
import AVFoundation
import TranscriptionKit

// NOTE (2026-06-28): Phase -1 picked Apple SpeechAnalyzer (macOS 26+) as the v1
// backend after this CLI showed it at RTF 0.01 with KO+EN quality on par with
// WhisperKit large-v3 (RTF 0.25) and no 1.5GB download. WhisperKitBackend stays
// in the repo as a documented future fallback. This CLI runs either backend.
//
// Phase -1 quality gate (autoplan UC2): transcribe a real KO+EN meeting
// recording offline and print the result + timing, so we can judge whether
// streaming WhisperKit is good enough before building the live pipeline.
//
// Usage:
//   wn-validate <audio-file> [--model large-v3] [--source microphone|system]
//
// Prints each segment with timestamps, then wall-clock time and real-time
// factor (RTF = processing time / audio duration; < 1.0 means faster than
// real time, the bar for live streaming to ever keep up).

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    wn-validate — Phase -1 STT quality gate

    Usage:
      wn-validate <audio-file> [--backend whisperkit|apple] [--model <name>]
                  [--locale <bcp47>] [--source microphone|system]

    Options:
      --backend  whisperkit (default) or apple (macOS 26 SpeechAnalyzer)
      --model    WhisperKit model (default: large-v3; "large-v3-v20240930_turbo" for speed)
      --locale   Apple backend locale (default: ko-KR)
      --source   tag segments as microphone or system (default: microphone)

    Examples:
      wn-validate ~/Desktop/meeting.m4a
      wn-validate ~/Desktop/meeting.m4a --backend apple --locale ko-KR

    """.utf8))
    exit(2)
}

func audioDurationSeconds(_ url: URL) -> Double? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let frames = Double(file.length)
    let rate = file.fileFormat.sampleRate
    guard rate > 0 else { return nil }
    return frames / rate
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let pathArg = argv.first, !pathArg.hasPrefix("--") else { usage() }

var model = "large-v3"
var backendName = "whisperkit"
var locale = "ko-KR"
var language = "ko"   // WhisperKit forced language; "auto" = detect (will translate KO→EN)
var source: AudioSource = .microphone
var i = 1
while i < argv.count {
    switch argv[i] {
    case "--model":
        i += 1
        if i < argv.count { model = argv[i] } else { usage() }
    case "--backend":
        i += 1
        if i < argv.count { backendName = argv[i] } else { usage() }
    case "--language":
        i += 1
        if i < argv.count { language = argv[i] } else { usage() }
    case "--locale":
        i += 1
        if i < argv.count { locale = argv[i] } else { usage() }
    case "--source":
        i += 1
        guard i < argv.count, let s = AudioSource(rawValue: argv[i]) else { usage() }
        source = s
    default:
        FileHandle.standardError.write(Data("Unknown argument: \(argv[i])\n".utf8))
        usage()
    }
    i += 1
}

let url = URL(fileURLWithPath: (pathArg as NSString).expandingTildeInPath)
guard FileManager.default.fileExists(atPath: url.path) else {
    FileHandle.standardError.write(Data("File not found: \(url.path)\n".utf8))
    exit(1)
}

// Resolve backend (Apple is macOS 26+ only).
let backend: any TranscriptionBackend
switch backendName {
case "whisperkit":
    backend = WhisperKitBackend(model: model, language: language == "auto" ? nil : language)
case "apple":
    if #available(macOS 26.0, *) {
        guard AppleSpeechBackend.isAvailable else {
            FileHandle.standardError.write(Data("Apple SpeechTranscriber unavailable on this machine.\n".utf8))
            exit(1)
        }
        backend = AppleSpeechBackend(locale: locale)
    } else {
        FileHandle.standardError.write(Data("--backend apple requires macOS 26+.\n".utf8))
        exit(1)
    }
default:
    FileHandle.standardError.write(Data("Unknown backend: \(backendName) (use whisperkit|apple)\n".utf8))
    usage()
}

let duration = audioDurationSeconds(url)
print("WhisperNotion Phase -1 validation")
print("  file:    \(url.lastPathComponent)")
print("  backend: \(backendName)")
if backendName == "whisperkit" { print("  model:   \(model)"); print("  language:\(language)") }
if backendName == "apple" { print("  locale:  \(locale)") }
print("  source:  \(source.internalLabel)")
if let duration { print(String(format: "  length:  %.1fs", duration)) }
print("  (first run downloads the model/assets — this can take a few minutes)\n")
let started = Date()
do {
    let segments = try await backend.transcribeFile(at: url, source: source)
    let elapsed = Date().timeIntervalSince(started)

    print("──── transcript ────")
    for seg in segments where !seg.text.isEmpty {
        print(String(format: "[%6.1f–%6.1f] [%@] %@",
                     seg.start, seg.end, seg.source.internalLabel, seg.text))
    }
    print("────────────────────")
    print("\nsegments: \(segments.count)")
    print(String(format: "wall time: %.1fs", elapsed))
    if let duration, duration > 0 {
        print(String(format: "RTF: %.2f  (%@ real time)",
                     elapsed / duration,
                     elapsed < duration ? "faster than" : "SLOWER than"))
    }
} catch {
    FileHandle.standardError.write(Data("Transcription failed: \(error)\n".utf8))
    exit(1)
}
