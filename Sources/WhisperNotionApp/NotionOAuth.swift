import Foundation
import AppKit
import Network

/// Notion OAuth (authorization-code) flow for a native app. Notion's REST OAuth
/// has no PKCE, so this is a confidential-client flow: the user creates their
/// own OAuth integration (client id + secret) and we exchange the code using
/// HTTP Basic auth. Fine for a single-user personal tool — the secret lives in
/// the local Keychain. This is the only API path to a company workspace that
/// blocks internal integrations but allows OAuth connections.
@MainActor
final class NotionOAuth {
    enum OAuthError: LocalizedError {
        case listenerFailed(String)
        case cancelled
        case noCode(String)
        case exchangeFailed(String)
        var errorDescription: String? {
            switch self {
            case .listenerFailed(let m): return "리디렉트 서버 시작 실패: \(m)"
            case .cancelled: return "인증이 취소되었습니다"
            case .noCode(let m): return "인증 코드를 받지 못했습니다: \(m)"
            case .exchangeFailed(let m): return "토큰 교환 실패: \(m)"
            }
        }
    }

    /// Fixed loopback port — the user registers this exact redirect URI in their
    /// Notion OAuth integration.
    let port: UInt16 = 8127
    var redirectURI: String { "http://localhost:\(port)/callback" }

    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?

    /// Run the full flow and return a Notion access token.
    func authorize(clientID: String, clientSecret: String) async throws -> String {
        let code = try await obtainCode(clientID: clientID)
        return try await exchange(code: code, clientID: clientID, clientSecret: clientSecret)
    }

    // MARK: Step 1 — browser auth → loopback captures the code

    private func obtainCode(clientID: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.continuation = cont
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated { self?.handle(connection) }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated {
                        switch state {
                        case .ready:
                            self?.openBrowser(clientID: clientID)
                        case .failed(let error):
                            self?.finish(.failure(OAuthError.listenerFailed(error.localizedDescription)))
                        default:
                            break
                        }
                    }
                }
                listener.start(queue: .main)
            } catch {
                cont.resume(throwing: OAuthError.listenerFailed(error.localizedDescription))
                self.continuation = nil
            }
        }
    }

    private func openBrowser(clientID: String) {
        var comps = URLComponents(string: "https://api.notion.com/v1/oauth/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "owner", value: "user"),
            .init(name: "redirect_uri", value: redirectURI),
        ]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let code = Self.parseCode(fromRequestLine: request)
            let bodyText = code != nil
                ? "WhisperNotion 연결 완료. 이 창을 닫아도 됩니다."
                : "인증 코드를 찾지 못했습니다."
            let body = Data(bodyText.utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
            MainActor.assumeIsolated {
                guard let self else { return }
                if let code {
                    self.finish(.success(code))
                } else {
                    self.finish(.failure(OAuthError.noCode(String(request.prefix(120)))))
                }
            }
        }
    }

    nonisolated static func parseCode(fromRequestLine request: String) -> String? {
        // First line: "GET /callback?code=abc&state=xyz HTTP/1.1"
        guard let firstLine = request.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1])
        guard let comps = URLComponents(string: "http://localhost" + path) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "code" })?.value
    }

    private func finish(_ result: Result<String, Error>) {
        listener?.cancel()
        listener = nil
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }

    // MARK: Step 2 — exchange code for an access token

    private func exchange(code: String, clientID: String, clientSecret: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("2026-03-11", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OAuthError.exchangeFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String else {
            throw OAuthError.exchangeFailed("응답에 access_token 없음")
        }
        return token
    }
}
