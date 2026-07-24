import AVFoundation
import XCTest
@testable import AudioCapture

/// Regression tests for the VPIO multichannel bug: enabling voice processing
/// silently switches the input node to a multichannel format (3/5/7/9ch by
/// environment), and AVAudioConverter's multichannel→mono downmix outputs
/// pure silence. The fix taps in an explicit mono format at the hardware
/// sample rate; these tests pin that derivation.
final class MicCaptureFormatTests: XCTestCase {
    private func format(channels: AVAudioChannelCount, sampleRate: Double) -> AVAudioFormat {
        // The convenience initializer only builds mono/stereo; VPIO's real
        // multichannel formats come from Core Audio, so mirror that via ASBD.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        if channels <= 2 {
            return AVAudioFormat(streamDescription: &asbd)!
        }
        let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        )!
        return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)!
    }

    func testMultichannelInputsCollapseToMonoAtHardwareRate() {
        for channels: AVAudioChannelCount in [9, 5, 3] {
            for sampleRate in [48_000.0, 44_100.0] {
                let tap = MicCapture.tapFormat(for: format(channels: channels, sampleRate: sampleRate))
                XCTAssertNotNil(tap, "\(channels)ch @ \(sampleRate)")
                XCTAssertEqual(tap?.channelCount, 1, "\(channels)ch @ \(sampleRate)")
                // Sample rate MUST match the hardware format — a mismatch makes
                // installTap raise an uncatchable NSException.
                XCTAssertEqual(tap?.sampleRate, sampleRate, "\(channels)ch @ \(sampleRate)")
                XCTAssertEqual(tap?.commonFormat, .pcmFormatFloat32)
                XCTAssertFalse(tap?.isInterleaved ?? true)
            }
        }
    }

    func testMonoInputStaysMonoAtSameRate() {
        let tap = MicCapture.tapFormat(for: format(channels: 1, sampleRate: 16_000))
        XCTAssertEqual(tap?.channelCount, 1)
        XCTAssertEqual(tap?.sampleRate, 16_000)
    }

    /// The wiring regression test. `tapFormat` passing is NOT enough — the bug was
    /// that `start()` never used it and left the converter on the multichannel input
    /// format. `formatPlan` is what `start()` actually calls, and it MUST return the
    /// same mono format for both the tap and the converter input. If the two ever
    /// diverge (converter left on multichannel), AVAudioConverter.convert returns
    /// .error and the mic goes silent — the exact original bug via a different path.
    func testFormatPlanReturnsMatchingMonoTapAndConverterInput() {
        for channels: AVAudioChannelCount in [9, 5, 3, 2, 1] {
            for sampleRate in [48_000.0, 44_100.0] {
                let hw = format(channels: channels, sampleRate: sampleRate)
                let plan = MicCapture.formatPlan(for: hw)
                XCTAssertNotNil(plan, "\(channels)ch @ \(sampleRate)")
                // Tap must be mono at the hardware rate.
                XCTAssertEqual(plan?.tap.channelCount, 1, "\(channels)ch @ \(sampleRate)")
                XCTAssertEqual(plan?.tap.sampleRate, sampleRate, "\(channels)ch @ \(sampleRate)")
                // Converter input must equal the tap format, NOT the multichannel input.
                XCTAssertEqual(plan?.converterFrom, plan?.tap, "\(channels)ch @ \(sampleRate)")
                XCTAssertEqual(plan?.converterFrom.channelCount, 1, "\(channels)ch @ \(sampleRate)")
                // The real regression: converter input must never be the raw hardware
                // channel count for a multichannel device (that path outputs silence).
                if channels > 1 {
                    XCTAssertNotEqual(plan?.converterFrom.channelCount, channels,
                                      "\(channels)ch @ \(sampleRate) — converter left on multichannel input")
                }
            }
        }
    }

    func testFormatPlanReturnsNilOnDegenerateInput() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard let degenerate = AVAudioFormat(streamDescription: &asbd) else { return }
        XCTAssertNil(MicCapture.formatPlan(for: degenerate))
    }

    func testDegenerateSampleRateReturnsNilInsteadOfCrashing() {
        // AVAudioFormat can't be constructed with SR 0, so exercise the public
        // contract via a stream description that AVFoundation does accept.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard let degenerate = AVAudioFormat(streamDescription: &asbd) else {
            // AVFoundation refused to build the degenerate format at all —
            // upstream guard (sampleRate > 0) already covers this path.
            return
        }
        XCTAssertNil(MicCapture.tapFormat(for: degenerate))
    }
}
