import Foundation

/// Extracts a Notion page ID from a pasted URL (or a bare ID).
///
/// Notion IDs are 128-bit UUIDs rendered as 32 hex chars, dashed or undashed.
/// A page URL looks like `https://www.notion.so/Workspace/Title-<32hex>`, with
/// optional query params (`?v=<32hex>` is a *database view* ID — never the page,
/// `?pvs=4`, etc). Strategy: drop the query, take the LAST 32-hex run in the
/// path (the title slug never contains one), normalize to dashed 8-4-4-4-12.
public enum PageIDParser {
    /// Returns a dashed UUID string, or nil if no Notion ID is present.
    public static func pageID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Strip query + fragment.
        let path = trimmed
            .split(separator: "?", maxSplits: 1).first.map(String.init)?
            .split(separator: "#", maxSplits: 1).first.map(String.init) ?? trimmed

        // Prefer an already-dashed UUID anywhere in the path.
        if let dashed = firstMatch(in: path, pattern:
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}") {
            return dashed.lowercased()
        }

        // Otherwise take the LAST undashed 32-hex run in the path.
        let hexRuns = allMatches(in: path, pattern: "[0-9a-fA-F]{32}")
        guard let last = hexRuns.last else { return nil }
        return dash(last).lowercased()
    }

    static func dash(_ hex32: String) -> String {
        let h = Array(hex32)
        func s(_ r: Range<Int>) -> String { String(h[r]) }
        return "\(s(0..<8))-\(s(8..<12))-\(s(12..<16))-\(s(16..<20))-\(s(20..<32))"
    }

    private static func firstMatch(in s: String, pattern: String) -> String? {
        allMatches(in: s, pattern: pattern).first
    }

    private static func allMatches(in s: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        return regex.matches(in: s, range: range).compactMap {
            Range($0.range, in: s).map { String(s[$0]) }
        }
    }
}
