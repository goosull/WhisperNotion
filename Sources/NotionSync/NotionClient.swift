import Foundation

/// A page the integration can write to.
public struct NotionPageRef: Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public enum NotionError: Error, Sendable, Equatable {
    case badToken                 // 401
    case pageNotShared            // 404 — page not connected to the integration
    case rateLimited(retryAfter: Double)  // 429
    case http(status: Int, body: String)
    case transport(String)
    case invalidPageID
}

/// Thin Notion REST client for the calls we need: validate the token, confirm a
/// page is reachable, and append block children. Pins the API version.
public struct NotionClient: Sendable {
    public static let apiVersion = "2026-03-11"
    public static let maxBlocksPerRequest = 100

    private let token: String
    private let session: URLSession
    private let base = URL(string: "https://api.notion.com/v1/")!

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw NotionError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NotionError.transport("no HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 401:
            throw NotionError.badToken
        case 404:
            throw NotionError.pageNotShared
        case 429:
            let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
            throw NotionError.rateLimited(retryAfter: retry)
        default:
            throw NotionError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Validate the token; returns the integration/bot name.
    @discardableResult
    public func verifyToken() async throws -> String {
        let (data, _) = try await send(request("GET", "users/me"))
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["name"] as? String) ?? "integration"
    }

    /// Confirm the page is reachable by this integration; returns its title.
    /// A 404 here almost always means the page isn't shared with the integration.
    @discardableResult
    public func verifyPage(pageID: String) async throws -> String {
        let (data, _) = try await send(request("GET", "pages/\(pageID)"))
        return Self.pageTitle(from: data) ?? "page"
    }

    /// Pages this integration can see (granted during OAuth / sharing). Used to
    /// let the user pick a target page instead of pasting a link.
    public func listPages(limit: Int = 25) async throws -> [NotionPageRef] {
        let body = try JSONSerialization.data(withJSONObject: [
            "filter": ["property": "object", "value": "page"],
            "page_size": limit,
        ])
        let (data, _) = try await send(request("POST", "search", body: body))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let id = r["id"] as? String else { return nil }
            return NotionPageRef(id: id, title: Self.searchResultTitle(r) ?? "(제목 없음)")
        }
    }

    static func searchResultTitle(_ result: [String: Any]) -> String? {
        if let props = result["properties"] as? [String: Any] {
            for (_, value) in props {
                if let v = value as? [String: Any], (v["type"] as? String) == "title",
                   let arr = v["title"] as? [[String: Any]] {
                    let t = arr.compactMap { $0["plain_text"] as? String }.joined()
                    if !t.isEmpty { return t }
                }
            }
        }
        return nil
    }

    /// Append up to 100 blocks to a page/block.
    public func appendChildren(pageID: String, blocks: [NotionBlock]) async throws {
        guard !pageID.isEmpty else { throw NotionError.invalidPageID }
        precondition(blocks.count <= Self.maxBlocksPerRequest, "batch >100 blocks")
        let payload = ChildrenPayload(children: blocks)
        let body = try JSONEncoder().encode(payload)
        _ = try await send(request("PATCH", "blocks/\(pageID)/children", body: body))
    }

    private struct ChildrenPayload: Encodable {
        let children: [NotionBlock]
    }

    static func pageTitle(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = obj["properties"] as? [String: Any] else { return nil }
        for (_, value) in props {
            if let v = value as? [String: Any], (v["type"] as? String) == "title",
               let titleArr = v["title"] as? [[String: Any]] {
                let text = titleArr.compactMap { $0["plain_text"] as? String }.joined()
                if !text.isEmpty { return text }
            }
        }
        return nil
    }
}
