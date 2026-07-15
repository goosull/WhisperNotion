import Foundation
import CoreAudio
import AVFoundation
import TranscriptionKit

/// Captures all system output audio (the "other side" of a call) via a Core
/// Audio process tap (macOS 14.2+) and emits 16 kHz mono Float32 frames.
///
/// Unlike ScreenCaptureKit, a process tap needs only audio-capture consent
/// (`NSAudioCaptureUsageDescription`) — no Screen Recording grant. We build a
/// private aggregate device wrapping a global mono tap and read it with an
/// IOProc, then resample to our canonical format.
public final class SystemAudioTap: @unchecked Sendable {
    private let onSamples: ([Float]) -> Void
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat
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

    /// Explicitly trigger the macOS system-audio consent flow without starting
    /// a recording session. The UI uses this after explaining the permission.
    public static func requestPermission() throws {
        guard let tap = SystemAudioTap(onSamples: { _ in }) else {
            throw TranscriptionError.audioReadFailed("system audio tap 초기화 실패")
        }
        try tap.start()
        tap.stop()
    }

    public func start() throws {
        // 1. Mono global tap (all processes, exclude none). Private = not shown
        //    to other apps.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw TranscriptionError.audioReadFailed("process tap 생성 실패 (\(status)) — 오디오 캡처 권한 확인")
        }
        tapID = tap

        // 2. Read the tap's stream format.
        tapFormat = try readTapFormat(tap)
        converter = tapFormat.flatMap { AVAudioConverter(from: $0, to: targetFormat) }

        // 3. Private aggregate device wrapping the tap.
        let aggUID = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WhisperNotion System Tap",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard status == noErr, agg != kAudioObjectUnknown else {
            cleanup()
            throw TranscriptionError.audioReadFailed("aggregate device 생성 실패 (\(status))")
        }
        aggregateID = agg

        // 4. IOProc — pull tap audio, resample, emit.
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) {
            [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
        guard status == noErr, procID != nil else {
            cleanup()
            throw TranscriptionError.audioReadFailed("IOProc 생성 실패 (\(status))")
        }

        status = AudioDeviceStart(agg, procID)
        guard status == noErr else {
            cleanup()
            throw TranscriptionError.audioReadFailed("aggregate 시작 실패 (\(status))")
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        cleanup()
        isRunning = false
    }

    private func cleanup() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func readTapFormat(_ tap: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TranscriptionError.audioReadFailed("tap 포맷 읽기 실패 (\(status))")
        }
        return format
    }

    private func handle(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let converter, let tapFormat else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard let first = abl.first, let mData = first.mData else { return }

        let frameCount = first.mDataByteSize / UInt32(MemoryLayout<Float>.size)
        guard frameCount > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frameCount) else { return }
        inBuffer.frameLength = frameCount
        if let dst = inBuffer.floatChannelData {
            memcpy(dst[0], mData, Int(first.mDataByteSize))
        }

        let ratio = targetFormat.sampleRate / tapFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true
            inStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error, let ch = out.floatChannelData, out.frameLength > 0 else { return }
        onSamples(Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))))
    }
}
