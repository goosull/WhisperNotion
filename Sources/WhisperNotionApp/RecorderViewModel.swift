import Foundation
import SwiftUI
import TranscriptionKit
import AudioCapture
import NotionSync

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
    @Published private(set) var notionSync: String = ""

    private var backend: AppleSpeechBackend?
    private var mic: MicCapture?
    private var consumeTask: Task<Void, Never>?
    private var queue: AppendQueue?
    private var healthPoll: Task<Void, Never>?
    private var skipNotionOnce = false

    private init() {}

    func toggle() { isRecording ? stop() : start() }

    /// Record without writing to Notion (the page picker's "Notion 없이 녹음").
    func startLocalOnly() {
        skipNotionOnce = true
        start()
    }

    func start() {
        guard !isRecording else { return }
        guard #available(macOS 26.0, *), AppleSpeechBackend.isAvailable else {
            statusMessage = "이 기기에서 음성 인식을 쓸 수 없습니다 (macOS 26 필요)"
            return
        }

        let settings = SettingsStore.shared
        let wantNotion = settings.hasToken && !skipNotionOnce
        // Notion connected but no page chosen yet → ask first.
        if wantNotion && settings.pageID == nil {
            NotificationCenter.default.post(name: .openWhisperNotionPagePicker, object: nil)
            return
        }

        finalized.removeAll()
        interim = ""
        statusMessage = "음성 모델 준비 중…"

        setupNotion(enabled: wantNotion)
        skipNotionOnce = false

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
        let queue = self.queue
        isRecording = false
        interim = ""
        statusMessage = "정지됨 — \(finalized.count)개 구절"
        healthPoll?.cancel()
        Task {
            await backend?.finish()
            if let queue {
                self.notionSync = "Notion에 남은 내용 전송 중…"
                await queue.flush()
                self.notionSync = "Notion 동기화 완료"
            }
        }
    }

    private func apply(_ segment: TranscriptSegment) {
        if segment.isConfirmed {
            finalized.append(segment)
            interim = ""
            // Stream finalized lines to Notion live.
            if let queue {
                let line = speakerLabel(segment.source) + segment.text
                Task { await queue.enqueue([BlockBuilder.paragraph(line)]) }
            }
        } else {
            interim = segment.text
        }
    }

    /// Build the Notion append queue if the user has configured a token + page,
    /// and verify access so a misconfigured page surfaces immediately.
    private func setupNotion(enabled: Bool) {
        let settings = SettingsStore.shared
        guard enabled, settings.isConfigured, let pageID = settings.pageID else {
            queue = nil
            notionSync = settings.hasToken ? "Notion 없이 녹음 중" : "Notion 미설정 (설정에서 연결하세요)"
            return
        }
        let client = NotionClient(token: settings.token)
        let queue = AppendQueue(client: client, pageID: pageID)
        self.queue = queue
        notionSync = "Notion 연결 확인 중…"
        Task {
            do {
                let title = try await client.verifyPage(pageID: pageID)
                self.notionSync = "Notion 연결됨: \(title)"
            } catch NotionError.pageNotShared {
                self.notionSync = "⚠ 페이지가 integration에 연결되지 않음 (전사는 로컬 유지)"
                self.queue = nil
            } catch {
                self.notionSync = "⚠ Notion 확인 실패 (전사는 로컬 유지)"
                self.queue = nil
            }
        }
        // Poll queue health for the UI.
        healthPoll = Task {
            while !Task.isCancelled {
                if let q = self.queue {
                    let h = await q.health
                    self.notionSync = Self.describe(h)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func describe(_ h: AppendQueue.Health) -> String {
        switch h {
        case .idle: return "Notion 동기화됨"
        case .syncing(let n): return "Notion 동기화 중… \(n)개 대기"
        case .retrying(let after): return String(format: "Notion 재시도 중 (%.0f초)", after)
        case .failed(let m): return "Notion 오류: \(m)"
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
