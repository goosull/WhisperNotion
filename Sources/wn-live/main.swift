import Foundation
import TranscriptionKit
import AudioCapture

// Phase 0 verification: prove the live streaming path works end-to-end with
// Apple SpeechAnalyzer — feed audio in real time and watch volatile (interim)
// text refine into finalized segments.
//
// Two sources:
//   --file <path>   stream a recording in real time (deterministic, no mic prompt)
//   --mic [seconds] capture the real microphone (needs mic permission)
//
//   wn-live --file ~/Downloads/meeting.m4a
//   wn-live --mic 20 --locale ko-KR

// Stream output line-by-line even when redirected to a file/pipe, so live
// progress is visible (and survives an external timeout/kill).
setvbuf(stdout, nil, _IONBF, 0)

@available(macOS 26.0, *)
func run() async {
    let argv = Array(CommandLine.arguments.dropFirst())
    var filePath: String?
    var micSeconds: Double?
    var locale = "ko-KR"

    var i = 0
    while i < argv.count {
        switch argv[i] {
        case "--file":
            i += 1; filePath = i < argv.count ? argv[i] : nil
        case "--mic":
            // optional numeric seconds follows
            if i + 1 < argv.count, let s = Double(argv[i + 1]) { micSeconds = s; i += 1 }
            else { micSeconds = 20 }
        case "--locale":
            i += 1; if i < argv.count { locale = argv[i] }
        default:
            FileHandle.standardError.write(Data("Unknown argument: \(argv[i])\n".utf8))
            exit(2)
        }
        i += 1
    }

    guard AppleSpeechBackend.isAvailable else {
        FileHandle.standardError.write(Data("Apple SpeechTranscriber unavailable.\n".utf8))
        exit(1)
    }

    let backend = AppleSpeechBackend(locale: locale)
    print("WhisperNotion Phase 0 — live streaming (\(locale))")
    print("  legend:  ~ interim (still changing)   ✓ finalized\n")

    do {
        try await backend.startStream(source: .microphone)
    } catch {
        FileHandle.standardError.write(Data("startStream failed: \(error)\n".utf8))
        exit(1)
    }

    // Print segments as they stream.
    let printer = Task {
        var lastInterim = ""
        for await seg in backend.segments {
            if seg.isConfirmed {
                print("✓ \(seg.text)")
                lastInterim = ""
            } else if seg.text != lastInterim {
                print("~ \(seg.text)")
                lastInterim = seg.text
            }
        }
    }

    if let filePath {
        let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("File not found: \(url.path)\n".utf8))
            exit(1)
        }
        print("streaming file in real time: \(url.lastPathComponent)\n")
        // Run the paced file reader on its own thread so its real-time sleeps
        // don't block the Swift concurrency pool (the analyzer + result printer
        // need it). Blocking the cooperative pool starves them and stalls output.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                do {
                    try FileStreamer.stream(url: url, chunkSeconds: 0.5, realtimePaced: true) { samples in
                        backend.feedSamples(samples)
                    }
                } catch {
                    FileHandle.standardError.write(Data("file stream failed: \(error)\n".utf8))
                }
                cont.resume()
            }
        }
    } else {
        let seconds = micSeconds ?? 20
        guard let mic = MicCapture(onSamples: { samples in backend.feedSamples(samples) }) else {
            FileHandle.standardError.write(Data("MicCapture init failed.\n".utf8))
            exit(1)
        }
        do {
            try mic.start()
        } catch {
            FileHandle.standardError.write(Data("mic start failed: \(error)\n(grant microphone permission to your terminal)\n".utf8))
            exit(1)
        }
        print("listening on mic for \(Int(seconds))s — speak now…\n")
        try? await Task.sleep(for: .seconds(seconds))
        mic.stop()
    }

    await backend.finish()
    _ = await printer.value
    print("\n[done]")
}

if #available(macOS 26.0, *) {
    await run()
} else {
    FileHandle.standardError.write(Data("wn-live requires macOS 26+.\n".utf8))
    exit(1)
}
