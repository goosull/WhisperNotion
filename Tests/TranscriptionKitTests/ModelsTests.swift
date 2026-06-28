import XCTest
@testable import TranscriptionKit

final class ModelsTests: XCTestCase {
    func testAudioSourceInternalLabels() {
        XCTAssertEqual(AudioSource.microphone.internalLabel, "mic")
        XCTAssertEqual(AudioSource.system.internalLabel, "system")
    }

    func testAudioSourceRoundTrips() {
        XCTAssertEqual(AudioSource(rawValue: "microphone"), .microphone)
        XCTAssertEqual(AudioSource(rawValue: "system"), .system)
        XCTAssertNil(AudioSource(rawValue: "nope"))
    }

    func testSegmentIsCodable() throws {
        let seg = TranscriptSegment(text: "안녕하세요 deploy 했어요",
                                    start: 0, end: 1.5,
                                    isConfirmed: true, source: .microphone)
        let data = try JSONEncoder().encode(seg)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        XCTAssertEqual(seg, decoded)
    }

    func testAudioFormatSpec() {
        XCTAssertEqual(AudioFormatSpec.sampleRate, 16_000)
        XCTAssertEqual(AudioFormatSpec.channelCount, 1)
    }

    func testWhisperKitBackendAvailable() {
        XCTAssertTrue(WhisperKitBackend.isAvailable)
        XCTAssertEqual(WhisperKitBackend.identifier, "whisperkit")
    }
}
