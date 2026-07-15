import SwiftUI
import Summarization

/// Notion connection setup via OAuth (the path that works for a company
/// workspace which blocks internal integrations but allows OAuth, like Claude).
/// The user creates their own OAuth integration once, pastes client id/secret,
/// and clicks Connect — a browser authorizes and we capture the token.
struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var connecting = false

    var body: some View {
        Form {
            Section("1. Notion OAuth 통합 만들기") {
                Text("회사 워크스페이스는 내부 토큰을 막아두므로 OAuth로 연결합니다. notion.so/my-integrations 에서 통합을 만들 때 **OAuth**를 선택하고, 아래 Redirect URI를 그대로 등록하세요. (만들 수 없으면 개인 워크스페이스에서 만든 뒤 회사 페이지에 권한을 부여하면 됩니다.)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Integration 설정 열기") {
                    if let url = URL(string: "https://www.notion.so/my-integrations") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                LabeledContent("Redirect URI") {
                    HStack {
                        Text(settings.redirectURI).font(.system(.caption, design: .monospaced))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(settings.redirectURI, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("2. 자격 증명") {
                TextField("OAuth client ID", text: $settings.clientID)
                    .textFieldStyle(.roundedBorder)
                SecureField("OAuth client secret", text: $settings.clientSecret)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(connecting ? "연결 중…" : "Notion 연결") {
                        connecting = true
                        Task { await settings.connectViaOAuth(); connecting = false }
                    }
                    .disabled(connecting)
                    if !settings.token.isEmpty {
                        Label("토큰 있음", systemImage: "key.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            }

            Section("3. 대상 페이지") {
                Text("전사를 넣을 페이지를 OAuth 인증 시 선택하거나, 페이지 → ••• → 연결에서 이 통합을 추가하고 링크를 붙여넣으세요.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Notion 페이지 링크", text: $settings.pageURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("연결 테스트") { Task { await settings.verify() } }
                    statusView
                }
            }

            Section("4. 종료 시 LLM 요약 (선택)") {
                Toggle("녹음 종료 시 요약·정리해서 페이지에 추가", isOn: $settings.summaryEnabled)
                    .onChange(of: settings.summaryEnabled) { _, _ in settings.saveLLM() }

                if settings.summaryEnabled {
                    Picker("제공자", selection: $settings.llmProviderID) {
                        ForEach(LLMClient.presets, id: \.id) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    .onChange(of: settings.llmProviderID) { _, _ in settings.saveLLM() }

                    Text(settings.llmProvider.privacyNote)
                        .font(.caption).foregroundStyle(.secondary)

                    if settings.llmProvider.needsKey {
                        SecureField("API 키", text: $settings.llmKey)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { settings.saveLLM() }
                    }
                    TextField("모델 (비우면 기본: \(settings.llmProvider.defaultModel))", text: $settings.llmModel)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { settings.saveLLM() }
                    Button("저장") { settings.saveLLM() }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }

    @ViewBuilder
    private var statusView: some View {
        switch settings.verifyState {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .ok(let page):
            Label("연결됨: \(page)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
