import Foundation
import SwiftUI
import TranscriptionKit
import AudioCapture

/// Drives a live recording session: starts the Apple streaming backend, pumps
/// the microphone into it, and publishes finalized segments + the current
/// interim line for the UI. Single shared instance so the menu-bar menu and the
/// floating transcript panel observe the same state.
@MainActor
final class RecorderViewModel: ObservableObject {
    static let shared = RecorderViewModel()

    @Published private(set) var finalized: [TranscriptSegment] = []
    @Published private(set) var interim: String = ""
    @Published private(set) var isRecording = false
    @Published private(set) var statusMessage: String = "준비됨"

    private var backend: AppleSpeechBackend?
    private var mic: MicCapture?
    private var consumeTask: Task<Void, Never>?

    private init() {}

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        guard #available(macOS 26.0, *), AppleSpeechBackend.isAvailable else {
            statusMessage = "이 기기에서 음성 인식을 쓸 수 없습니다 (macOS 26 필요)"
            return
        }
        finalized.removeAll()
        interim = ""
        statusMessage = "음성 모델 준비 중…"

        let backend = AppleSpeechBackend(locale: "ko-KR")
        self.backend = backend

        consumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await backend.startStream(source: .microphone)
            } catch {
                await MainActor.run {
                    self.statusMessage = "시작 실패: \(error)"
                    self.isRecording = false
                }
                return
            }

            await MainActor.run {
                let mic = MicCapture(onSamples: { [weak backend] samples in
                    backend?.feedSamples(samples)
                })
                do {
                    try mic?.start()
                    self.mic = mic
                    self.isRecording = true
                    self.statusMessage = "녹음 중 — 말씀하세요"
                } catch {
                    self.statusMessage = "마이크 시작 실패: \(error)\n시스템 설정 → 개인정보 보호 → 마이크에서 허용하세요"
                    self.isRecording = false
                }
            }

            for await segment in backend.segments {
                await MainActor.run { self.apply(segment) }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        mic?.stop()
        mic = nil
        let backend = self.backend
        Task { await backend?.finish() }
        isRecording = false
        interim = ""
        statusMessage = "정지됨 — \(finalized.count)개 구절"
    }

    private func apply(_ segment: TranscriptSegment) {
        if segment.isConfirmed {
            finalized.append(segment)
            interim = ""
        } else {
            interim = segment.text
        }
    }

    /// Plain-text dump of the whole session (finalized + current interim).
    var transcriptText: String {
        var lines = finalized.map { speakerLabel($0.source) + $0.text }
        if !interim.isEmpty { lines.append(speakerLabel(.microphone) + interim) }
        return lines.joined(separator: "\n")
    }

    private func speakerLabel(_ source: AudioSource) -> String {
        // UI-facing labels; today mic-only (Phase 2 adds system → [상대]).
        source == .microphone ? "[나] " : "[상대] "
    }
}
