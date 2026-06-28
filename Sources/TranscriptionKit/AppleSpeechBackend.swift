import Foundation
import AVFoundation
import Speech

/// Apple on-device STT via the macOS 26 SpeechAnalyzer / SpeechTranscriber API
/// (autoplan UC2 spike: a native alternative to WhisperKit, no 1.5GB HuggingFace
/// download, OS-managed locale assets). Only usable on macOS 26+, so the app's
/// 14.4 floor still ships WhisperKit; this lets us compare quality on the same
/// audio when running on a 26+ machine.
@available(macOS 26.0, *)
public final class AppleSpeechBackend: TranscriptionBackend, @unchecked Sendable {
    public static let identifier = "apple-speech"
    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    private let localeID: String

    /// - Parameter locale: BCP-47 locale, e.g. "ko-KR". Korean is primary;
    ///   English IT terms ride along inside the Korean stream.
    public init(locale: String = "ko-KR") {
        self.localeID = locale
    }

    public func transcribeFile(at url: URL, source: AudioSource) async throws -> [TranscriptSegment] {
        let locale = Locale(identifier: localeID)

        // `.transcription` = final (non-volatile) results with time ranges.
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // Ensure the locale's on-device model is installed (downloads once).
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.modelLoadFailed("apple-speech \(localeID) asset: \(error)")
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.audioReadFailed("\(url.lastPathComponent): \(error)")
        }

        // Drain results concurrently while the analyzer pushes the file through.
        let collector = Task { () throws -> [TranscriptSegment] in
            var out: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(TranscriptSegment(
                    text: text,
                    start: result.range.start.seconds,
                    end: result.range.end.seconds,
                    isConfirmed: true,
                    source: source
                ))
            }
            return out
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw TranscriptionError.audioReadFailed("apple-speech analyze: \(error)")
        }

        return try await collector.value
    }
}
