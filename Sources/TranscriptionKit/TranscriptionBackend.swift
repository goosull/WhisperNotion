import Foundation

/// Pluggable STT engine (autoplan UC2 decision: abstract the backend so the app
/// is not married to WhisperKit, and an Apple SpeechAnalyzer or buy+glue backend
/// can be swapped in without touching capture, UI, or Notion code).
///
/// Two surfaces:
///  - `transcribeFile` — offline batch, used by the Phase -1 quality gate.
///  - streaming (`reset` / `appendSamples` / `segments`) — used live by the app.
///
/// Implementations must accept 16 kHz mono Float32 (`AudioFormatSpec`); callers
/// resample before feeding. Speaker labelling is the caller's job via `source`.
public protocol TranscriptionBackend: AnyObject, Sendable {
    /// Stable identifier for settings + logs (e.g. "whisperkit", "apple-speech").
    static var identifier: String { get }

    /// Whether this backend can run on the current OS/hardware right now.
    static var isAvailable: Bool { get }

    /// Offline transcription of an audio file. Backend resamples as needed.
    /// `source` tags every returned segment. Used by Phase -1 validation.
    func transcribeFile(at url: URL, source: AudioSource) async throws -> [TranscriptSegment]

    /// Begin a fresh streaming session for `source`.
    func startStream(source: AudioSource) async throws

    /// Feed 16 kHz mono Float32 samples for an already-started source.
    func appendSamples(_ samples: [Float], source: AudioSource) async

    /// Confirmed (and optionally partial) segments as they are produced.
    var segments: AsyncStream<TranscriptSegment> { get }

    /// End all streaming sessions and release resources.
    func finish() async
}

public extension TranscriptionBackend {
    /// Default: streaming unsupported. Backends that only do batch (Phase -1)
    /// can rely on this; the app-facing backends override it.
    func startStream(source: AudioSource) async throws {
        throw TranscriptionError.notImplemented("\(Self.identifier) streaming")
    }
    func appendSamples(_ samples: [Float], source: AudioSource) async {}
    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { $0.finish() }
    }
    func finish() async {}
}
