import Foundation

/// Which physical source a chunk of audio came from. Speaker identity is
/// derived from the source (mic = me, system = them), never from content.
/// Labels stay internal (`mic`/`system`) until confidence/UX testing earns the
/// user-facing `[나]`/`[상대]` mapping (autoplan decision #10).
public enum AudioSource: String, Sendable, Codable {
    case microphone
    case system

    /// Internal, always-safe label.
    public var internalLabel: String {
        switch self {
        case .microphone: return "mic"
        case .system: return "system"
        }
    }
}

/// One unit of transcribed speech.
public struct TranscriptSegment: Sendable, Codable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    /// `false` while the backend may still revise this text (live partial).
    public let isConfirmed: Bool
    public let source: AudioSource

    public init(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        isConfirmed: Bool,
        source: AudioSource
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.isConfirmed = isConfirmed
        self.source = source
    }
}

/// Audio expected by every backend: 16 kHz, mono, Float32 PCM in [-1, 1].
public struct AudioFormatSpec: Sendable {
    public static let sampleRate: Double = 16_000
    public static let channelCount: Int = 1
}

public enum TranscriptionError: Error, Sendable {
    case backendUnavailable(String)
    case modelLoadFailed(String)
    case audioReadFailed(String)
    case notImplemented(String)
}
