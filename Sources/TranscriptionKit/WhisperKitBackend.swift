import Foundation
import WhisperKit

/// WhisperKit-backed STT. The shipping backend for the macOS 14.4 floor.
/// Phase -1 uses `transcribeFile` to judge KO+EN quality on real meetings.
/// Streaming (custom AudioProcessing conformer, single time-sliced model) is
/// built in Phase 0; this type currently implements batch only.
public final class WhisperKitBackend: TranscriptionBackend, @unchecked Sendable {
    public static let identifier = "whisperkit"

    /// WhisperKit runs on Apple Silicon macOS 14+. Treat as available; the
    /// real gate is model download + runtime perf (measured in Phase 0).
    public static var isAvailable: Bool { true }

    private let modelName: String
    private let language: String?
    private var pipe: WhisperKit?

    /// - Parameters:
    ///   - model: WhisperKit model name, e.g. "large-v3".
    ///   - language: forced source language (default "ko"). Critical: without it
    ///     Whisper auto-detects and will TRANSLATE Korean speech into English.
    ///     Pass nil only to test auto-detection. English IT terms still pass
    ///     through inside a Korean ("ko") transcription.
    public init(model: String = "large-v3", language: String? = "ko") {
        self.modelName = model
        self.language = language
    }

    private func loadedPipe() async throws -> WhisperKit {
        if let pipe { return pipe }
        do {
            let config = WhisperKitConfig(model: modelName)
            let p = try await WhisperKit(config)
            pipe = p
            return p
        } catch {
            throw TranscriptionError.modelLoadFailed("\(modelName): \(error)")
        }
    }

    public func transcribeFile(at url: URL, source: AudioSource) async throws -> [TranscriptSegment] {
        let pipe = try await loadedPipe()
        let options = DecodingOptions(
            task: .transcribe,                 // transcribe in-language, never translate
            language: language,                // force "ko" so Korean stays Korean
            usePrefillPrompt: language != nil, // lock the language token
            detectLanguage: language == nil,
            skipSpecialTokens: true,           // drop <|...|> markers from text
            withoutTimestamps: false
        )
        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        } catch {
            throw TranscriptionError.audioReadFailed("\(url.lastPathComponent): \(error)")
        }
        return results.flatMap { result in
            result.segments.map { seg in
                TranscriptSegment(
                    text: Self.cleanText(seg.text),
                    start: TimeInterval(seg.start),
                    end: TimeInterval(seg.end),
                    isConfirmed: true,
                    source: source
                )
            }
        }
    }

    /// Strip any residual Whisper special tokens (`<|...|>`) and trim.
    static func cleanText(_ raw: String) -> String {
        var s = raw
        if let regex = try? NSRegularExpression(pattern: "<\\|[^>]*\\|>") {
            s = regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
