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

    // MARK: Streaming state (Phase 0 — progressive live transcription)

    private var streamTranscriber: SpeechTranscriber?
    private var streamAnalyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var segmentsContinuation: AsyncStream<TranscriptSegment>.Continuation?
    private var streamSource: AudioSource = .microphone

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

    // MARK: - Streaming (progressive volatile + finalized)

    public var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.segmentsContinuation = continuation
        }
    }

    public func startStream(source: AudioSource) async throws {
        streamSource = source
        let locale = Locale(identifier: localeID)

        // Progressive preset streams interim (volatile) results that refine as
        // the speaker continues, plus finalized results — exactly the live
        // subtitle behavior we want.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.modelLoadFailed("apple-speech \(localeID) asset: \(error)")
        }
        streamTranscriber = transcriber
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (inputStream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation

        let analyzer = SpeechAnalyzer(inputSequence: inputStream, modules: [transcriber])
        streamAnalyzer = analyzer

        // Bridge transcriber results → our segment stream as they arrive.
        // Progressive results grow word-by-word within one utterance (same
        // range start); when the range start jumps forward a new utterance has
        // begun, which means the previous one is finalized. We emit the live
        // text as interim (isConfirmed: false) and re-emit the prior utterance
        // as confirmed at each boundary, then flush the last one at finish.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            var pendingText = ""
            var pendingStart = 0.0
            var pendingEnd = 0.0
            var pendingRangeStart = -1.0
            // Guard: each utterance (identified by its range start) is confirmed
            // at most once, so a re-finalized result can't append a duplicate.
            var lastConfirmedRangeStart = -2.0
            var lastConfirmedText = ""
            func emitInterim(_ text: String, start: Double, end: Double) {
                self.segmentsContinuation?.yield(TranscriptSegment(
                    text: text, start: start, end: end,
                    isConfirmed: false, source: self.streamSource))
            }
            func confirmPending() {
                guard !pendingText.isEmpty else { return }
                // Already confirmed this utterance, or it's an exact repeat.
                if pendingRangeStart == lastConfirmedRangeStart { return }
                if pendingText == lastConfirmedText { return }
                self.segmentsContinuation?.yield(TranscriptSegment(
                    text: pendingText, start: pendingStart, end: pendingEnd,
                    isConfirmed: true, source: self.streamSource))
                lastConfirmedRangeStart = pendingRangeStart
                lastConfirmedText = pendingText
            }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let rs = result.range.start.seconds
                    // A genuinely new utterance starts at/after the previous
                    // one ended. A result whose start falls INSIDE the pending
                    // utterance's time span is a re-finalization of the same
                    // utterance → just replace its text, don't emit a duplicate.
                    if rs >= pendingEnd - 0.1, !pendingText.isEmpty {
                        confirmPending()
                    }
                    pendingRangeStart = rs
                    pendingText = text
                    pendingStart = rs
                    pendingEnd = result.range.end.seconds
                    emitInterim(text, start: pendingStart, end: pendingEnd)
                }
            } catch {
                // results stream ended (error or finish).
            }
            confirmPending()
            self.segmentsContinuation?.finish()
        }
    }

    public func appendSamples(_ samples: [Float], source: AudioSource) async {
        feedSamples(samples)
    }

    /// Synchronous feed entry — safe to call from an audio tap / capture thread
    /// (`AsyncStream.Continuation.yield` is thread-safe). 16 kHz mono Float32.
    public func feedSamples(_ samples: [Float]) {
        guard let continuation = inputContinuation,
              let target = analyzerFormat,
              let buffer = Self.makeBuffer(from: samples, targetFormat: target) else { return }
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    public func finish() async {
        inputContinuation?.finish()
        if let analyzer = streamAnalyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        resultsTask = nil
        streamAnalyzer = nil
        streamTranscriber = nil
        inputContinuation = nil
    }

    /// Build an `AVAudioPCMBuffer` in the analyzer's preferred format from our
    /// canonical 16 kHz mono Float32 samples (resampling if the analyzer wants
    /// a different rate/layout).
    static func makeBuffer(from samples: [Float], targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormatSpec.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let ch = sourceBuffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                ch[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        // Already the right format → no conversion.
        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount,
           sourceFormat.commonFormat == targetFormat.commonFormat {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true
            inStatus.pointee = .haveData
            return sourceBuffer
        }
        return status == .error ? nil : outBuffer
    }
}
