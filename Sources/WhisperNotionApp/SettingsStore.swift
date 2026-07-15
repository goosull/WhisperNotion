import Foundation
import SwiftUI
import NotionSync
import Summarization

/// User-configurable settings: the Notion integration token (Keychain) and the
/// target page URL (UserDefaults). Exposes a verify step that runs the
/// token + page checks so onboarding can confirm the connection before relying
/// on it (autoplan: a 404 means "page not shared", not a generic error).
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let tokenAccount = "notionToken"
    private let secretAccount = "notionClientSecret"
    private let pageURLKey = "notionPageURL"
    private let clientIDKey = "notionClientID"

    /// Notion access token — from OAuth, or a directly-pasted internal token.
    @Published var token: String
    @Published var pageURL: String
    /// OAuth integration credentials (for the company-workspace path).
    @Published var clientID: String
    @Published var clientSecret: String
    @Published var verifyState: VerifyState = .unknown

    /// Page chosen from the record-time picker (id + title), preferred over a
    /// manually pasted link.
    @Published var selectedPageID: String
    @Published var selectedPageTitle: String

    let redirectURI = "http://localhost:8127/callback"

    // LLM summary (Phase 4). Provider preset + model + key (Keychain).
    @Published var llmProviderID: String
    @Published var llmModel: String
    @Published var llmKey: String
    @Published var summaryEnabled: Bool

    enum VerifyState: Equatable {
        case unknown
        case checking
        case ok(page: String)
        case error(String)
    }

    private init() {
        token = KeychainStore.get("notionToken") ?? ""
        clientSecret = KeychainStore.get("notionClientSecret") ?? ""
        pageURL = UserDefaults.standard.string(forKey: "notionPageURL") ?? ""
        clientID = UserDefaults.standard.string(forKey: "notionClientID") ?? ""
        selectedPageID = UserDefaults.standard.string(forKey: "notionSelectedPageID") ?? ""
        selectedPageTitle = UserDefaults.standard.string(forKey: "notionSelectedPageTitle") ?? ""
        llmProviderID = UserDefaults.standard.string(forKey: "llmProviderID") ?? LLMClient.presets.first!.id
        llmModel = UserDefaults.standard.string(forKey: "llmModel") ?? ""
        llmKey = KeychainStore.get("llmKey") ?? ""
        summaryEnabled = UserDefaults.standard.object(forKey: "summaryEnabled") as? Bool ?? false
    }

    var llmProvider: LLMClient.Provider {
        LLMClient.preset(id: llmProviderID) ?? LLMClient.presets[0]
    }

    /// Effective model: user override, else the provider's default.
    var effectiveLLMModel: String {
        llmModel.isEmpty ? llmProvider.defaultModel : llmModel
    }

    /// A client if summary is enabled and credentials are sufficient.
    var llmClient: LLMClient? {
        guard summaryEnabled else { return nil }
        let provider = llmProvider
        if provider.needsKey && llmKey.isEmpty { return nil }
        return LLMClient(baseURL: provider.baseURL, apiKey: llmKey, model: effectiveLLMModel)
    }

    func saveLLM() {
        UserDefaults.standard.set(llmProviderID, forKey: "llmProviderID")
        UserDefaults.standard.set(llmModel, forKey: "llmModel")
        UserDefaults.standard.set(summaryEnabled, forKey: "summaryEnabled")
        if llmKey.isEmpty { KeychainStore.delete("llmKey") }
        else { KeychainStore.set(llmKey, for: "llmKey") }
    }

    var hasToken: Bool { !token.isEmpty }

    /// Selected-page id wins; otherwise parse a manually pasted link.
    var pageID: String? {
        if !selectedPageID.isEmpty { return selectedPageID }
        return PageIDParser.pageID(from: pageURL)
    }

    var isConfigured: Bool { hasToken && pageID != nil }

    func selectPage(id: String, title: String) {
        selectedPageID = id
        selectedPageTitle = title
        UserDefaults.standard.set(id, forKey: "notionSelectedPageID")
        UserDefaults.standard.set(title, forKey: "notionSelectedPageTitle")
    }

    func fetchPages() async throws -> [NotionPageRef] {
        try await NotionClient(token: token).listPages()
    }

    func save() {
        if token.isEmpty { KeychainStore.delete(tokenAccount) }
        else { KeychainStore.set(token, for: tokenAccount) }
        if clientSecret.isEmpty { KeychainStore.delete(secretAccount) }
        else { KeychainStore.set(clientSecret, for: secretAccount) }
        UserDefaults.standard.set(pageURL, forKey: pageURLKey)
        UserDefaults.standard.set(clientID, forKey: clientIDKey)
    }

    /// Run the OAuth flow (browser → loopback → token) and store the result.
    func connectViaOAuth() async {
        save()
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            verifyState = .error("client ID와 secret을 입력하세요")
            return
        }
        verifyState = .checking
        do {
            let token = try await NotionOAuth().authorize(clientID: clientID, clientSecret: clientSecret)
            self.token = token
            save()
            // Immediately confirm page access if a link is set.
            if pageID != nil {
                await verify()
            } else {
                verifyState = .ok(page: "연결됨 (페이지 링크를 입력하세요)")
            }
        } catch {
            verifyState = .error(error.localizedDescription)
        }
    }

    /// Validate the token AND that the page is shared with the integration.
    func verify() async {
        save()
        guard !token.isEmpty else { verifyState = .error("토큰을 입력하세요"); return }
        guard let pageID else { verifyState = .error("올바른 Notion 페이지 링크가 아닙니다"); return }
        verifyState = .checking
        let client = NotionClient(token: token)
        do {
            _ = try await client.verifyToken()
        } catch {
            verifyState = .error("토큰이 유효하지 않습니다. 새 Internal Integration Secret을 붙여넣으세요.")
            return
        }
        do {
            let title = try await client.verifyPage(pageID: pageID)
            verifyState = .ok(page: title)
        } catch NotionError.pageNotShared {
            verifyState = .error("이 페이지가 integration에 연결되지 않았습니다.\nNotion에서 페이지 → ••• → 연결 → WhisperNotion 추가 후 다시 시도하세요.")
        } catch {
            verifyState = .error("페이지 확인 실패: \(error)")
        }
    }
}
