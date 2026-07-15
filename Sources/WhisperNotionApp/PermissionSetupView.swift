import SwiftUI
import AppKit
import AVFoundation
import AudioCapture

/// The app's preflight permission state. System prompts are only triggered by
/// explicit buttons in this view, never by launching the app.
@MainActor
final class PermissionStore: ObservableObject {
    static let shared = PermissionStore()

    enum Status: Equatable {
        case notDetermined
        case granted
        case denied
        case unavailable
    }

    enum Permission: CaseIterable {
        case microphone
        case systemAudio
    }

    @Published private(set) var microphone: Status = .notDetermined
    @Published private(set) var systemAudio: Status
    @Published private(set) var requestingMicrophone = false
    @Published private(set) var requestingSystemAudio = false

    private let systemAudioGrantedKey = "systemAudioPermissionGranted"

    private init() {
        systemAudio = UserDefaults.standard.bool(forKey: systemAudioGrantedKey)
            ? .granted : .notDetermined
        refresh()
    }

    func refresh() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            microphone = .granted
        case .denied:
            microphone = .denied
        case .undetermined:
            microphone = .notDetermined
        @unknown default:
            microphone = .unavailable
        }
    }

    var microphoneGranted: Bool { microphone == .granted }
    var systemAudioGranted: Bool { systemAudio == .granted }

    func requestMicrophone() {
        guard !requestingMicrophone else { return }
        requestingMicrophone = true
        AVAudioApplication.requestRecordPermission { [weak self] _ in
            Task { @MainActor in
                self?.requestingMicrophone = false
                self?.refresh()
            }
        }
    }

    /// Core Audio displays its system-audio consent prompt the first time a
    /// process tap is started. Start and immediately stop a private tap so the
    /// user can explicitly grant this permission from Settings first.
    func requestSystemAudio(completion: ((Bool) -> Void)? = nil) {
        guard !requestingSystemAudio else { return }
        requestingSystemAudio = true
        Task { @MainActor in
            do {
                try SystemAudioTap.requestPermission()
                systemAudio = .granted
                UserDefaults.standard.set(true, forKey: systemAudioGrantedKey)
                completion?(true)
            } catch {
                systemAudio = .denied
                completion?(false)
            }
            requestingSystemAudio = false
        }
    }

    func openSystemSettings(for permission: Permission) {
        let anchor: String
        switch permission {
        case .microphone:
            anchor = "Privacy_Microphone"
        case .systemAudio:
            anchor = "Privacy_ScreenCapture"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A calm, explicit preflight that explains why each protected resource is
/// needed before macOS shows its own permission UI.
struct PermissionSetupView: View {
    @ObservedObject private var permissions = PermissionStore.shared
    @ObservedObject private var recorder = RecorderViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform.and.mic")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("녹음 준비")
                        .font(.headline)
                    Text("녹음에 필요한 권한을 여기서 확인합니다. 앱을 켜는 것만으로는 아무 권한도 요청하지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            permissionRow(
                icon: "mic.fill",
                title: "내 목소리",
                detail: "회의에서 내가 말한 내용을 받아씁니다. 녹음에 필수입니다.",
                status: permissions.microphone,
                permission: .microphone
            )

            permissionRow(
                icon: "speaker.wave.2.fill",
                title: "상대방 목소리",
                detail: "화상회의에서 나오는 소리를 [상대]로 기록합니다. 선택 사항입니다.",
                status: permissions.systemAudio,
                permission: .systemAudio
            )

            Toggle("상대방 목소리도 기록", isOn: systemAudioBinding)
                .disabled(permissions.requestingSystemAudio)
                .toggleStyle(.switch)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text("음성 변환은 macOS의 기기 내 SpeechAnalyzer를 사용하므로 별도의 음성 인식 권한이나 서버 전송 권한을 요청하지 않습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .task { permissions.refresh() }
    }

    private var systemAudioBinding: Binding<Bool> {
        Binding(
            get: { recorder.captureSystemAudio },
            set: { enabled in
                guard enabled else {
                    recorder.setCaptureSystemAudio(false)
                    return
                }
                if permissions.systemAudioGranted {
                    recorder.setCaptureSystemAudio(true)
                } else {
                    permissions.requestSystemAudio { granted in
                        recorder.setCaptureSystemAudio(granted)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        detail: String,
        status: PermissionStore.Status,
        permission: PermissionStore.Permission
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                statusLabel(status)
                if status != .granted && status != .unavailable {
                    Button(actionTitle(for: status)) {
                        request(permission: permission, status: status)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func statusLabel(_ status: PermissionStore.Status) -> some View {
        Group {
            switch status {
            case .granted:
                Label("허용됨", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Label("꺼짐", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.orange)
            case .notDetermined:
                Label("설정 필요", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            case .unavailable:
                Label("사용 불가", systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func actionTitle(for status: PermissionStore.Status) -> String {
        status == .denied ? "시스템 설정 열기" : "권한 요청"
    }

    private func request(permission: PermissionStore.Permission, status: PermissionStore.Status) {
        if status == .denied {
            permissions.openSystemSettings(for: permission)
            return
        }
        switch permission {
        case .microphone:
            permissions.requestMicrophone()
        case .systemAudio:
            permissions.requestSystemAudio()
        }
    }
}
