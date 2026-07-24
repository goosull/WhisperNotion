import Foundation
import AVFoundation
import TranscriptionKit

/// Captures the default input device (microphone) via AVAudioEngine and emits
/// 16 kHz mono Float32 frames (`AudioFormatSpec`) — the canonical format every
/// `TranscriptionBackend` accepts.
///
/// Phase 0 note: the tap callback resamples inline. AVAudioEngine taps run on a
/// dedicated render thread (not the Core Audio IOProc), so light work is
/// tolerable here; when the system-audio Core Audio process tap lands (Phase 2),
/// that path must use a lock-free ring with no work on the RT thread.
public final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let onSamples: ([Float]) -> Void
    private(set) public var isRunning = false

    public init?(onSamples: @escaping ([Float]) -> Void) {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormatSpec.sampleRate,
            channels: AVAudioChannelCount(AudioFormatSpec.channelCount),
            interleaved: false
        ) else { return nil }
        self.targetFormat = fmt
        self.onSamples = onSamples
    }

    /// Mono tap format at the hardware sample rate. Voice processing silently
    /// switches the input node to a multichannel format (3/5/7/9ch depending on
    /// environment) and AVAudioConverter's multichannel→mono downmix outputs
    /// pure silence — tapping in an explicit mono format makes AVAudioEngine's
    /// built-in converter do the downmix correctly instead. The sample rate must
    /// stay the hardware rate: a mismatch makes installTap raise an uncatchable
    /// NSException. Never hardcode a channel count here.
    static func tapFormat(for hardwareFormat: AVAudioFormat) -> AVAudioFormat? {
        guard hardwareFormat.sampleRate > 0 else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareFormat.sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    /// The tap format and the AVAudioConverter's input format must be the SAME
    /// mono format — the two are a coupled pair, not independent choices. If they
    /// diverge (e.g. tap emits mono but the converter is still configured for the
    /// multichannel hardware format), `AVAudioConverter.convert` returns `.error`
    /// and every frame is dropped: the same silent-mic symptom as tapping in the
    /// raw multichannel format. Deriving both from one call makes that impossible
    /// and makes the wiring unit-testable without a live audio device.
    static func formatPlan(for hardwareFormat: AVAudioFormat)
        -> (tap: AVAudioFormat, converterFrom: AVAudioFormat)? {
        guard let mono = tapFormat(for: hardwareFormat) else { return nil }
        return (tap: mono, converterFrom: mono)
    }

    public func start() throws {
        let input = engine.inputNode
        // Acoustic echo cancellation: removes the system output (speaker audio)
        // from the mic, so testing/working on SPEAKERS doesn't bleed the other
        // party's voice into the microphone track. Best-effort — some setups reject it.
        try? input.setVoiceProcessingEnabled(true)
        // AEC otherwise auto-ducks (quiets) what the user is listening to.
        // Disable that so playback volume stays normal while AEC runs.
        let ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false,
            duckingLevel: .min
        )
        input.voiceProcessingOtherAudioDuckingConfiguration = ducking

        // Everything past enabling voice processing runs in a transaction: any
        // throw leaves the input node exactly as clean as before start() ran.
        // Without this, a failed engine.start() leaves an installed tap behind,
        // and stop() won't remove it (it early-returns on !isRunning), so a
        // retry hits installTap-on-an-already-tapped-bus → uncatchable NSException.
        do {
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0 else {
                throw TranscriptionError.audioReadFailed("no input device / mic permission denied")
            }
            // Never fall back to inputFormat here: if voice processing switched it to
            // multichannel, tapping/converting in that format outputs pure silence.
            // Fail loud instead of silently re-entering the bug.
            guard let plan = MicCapture.formatPlan(for: inputFormat) else {
                throw TranscriptionError.audioReadFailed("could not derive mono tap format")
            }
            // Tap and converter are configured from the SAME mono format (plan.tap ==
            // plan.converterFrom). The engine's tap does the multichannel→mono downmix
            // correctly; the converter is left with only a mono→mono resample to 16 kHz.
            guard let converter = AVAudioConverter(from: plan.converterFrom, to: targetFormat) else {
                throw TranscriptionError.audioReadFailed("audio converter setup failed")
            }
            self.converter = converter

            input.installTap(onBus: 0, bufferSize: 4096, format: plan.tap) { [weak self] buffer, _ in
                self?.handle(buffer)
            }
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            // removeTap on an un-tapped bus is a no-op; disabling VPIO that never
            // enabled is harmless. Leaves the instance safe to retry or discard.
            input.removeTap(onBus: 0)
            try? input.setVoiceProcessingEnabled(false)
            converter = nil
            throw error
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true
            inStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let ch = out.floatChannelData, out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        onSamples(samples)
    }
}

/// Reads an audio file and yields it as 16 kHz mono Float32 chunks, pacing the
/// callback to wall-clock so it simulates a live mic. Lets Phase 0 verify the
/// streaming transcription pipeline deterministically, with no mic-permission
/// prompt and a known-good recording.
public enum FileStreamer {
    public static func stream(
        url: URL,
        chunkSeconds: Double = 0.5,
        realtimePaced: Bool = true,
        onSamples: ([Float]) -> Void
    ) throws {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormatSpec.sampleRate,
            channels: AVAudioChannelCount(AudioFormatSpec.channelCount),
            interleaved: false
        ), let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw TranscriptionError.audioReadFailed("converter setup")
        }

        let inChunk = AVAudioFrameCount(file.processingFormat.sampleRate * chunkSeconds)
        let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inChunk)!

        while true {
            try file.read(into: readBuffer, frameCount: inChunk)
            if readBuffer.frameLength == 0 { break }

            let ratio = target.sampleRate / file.processingFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(readBuffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { break }
            var fed = false
            var error: NSError?
            _ = converter.convert(to: out, error: &error) { _, inStatus in
                if fed { inStatus.pointee = .noDataNow; return nil }
                fed = true
                inStatus.pointee = .haveData
                return readBuffer
            }
            if let ch = out.floatChannelData, out.frameLength > 0 {
                onSamples(Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))))
            }
            if realtimePaced {
                Thread.sleep(forTimeInterval: chunkSeconds)
            }
        }
    }
}
