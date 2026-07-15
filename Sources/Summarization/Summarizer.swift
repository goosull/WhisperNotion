import Foundation

/// A section of the meeting summary (a heading + bullet points).
public struct SummarySection: Sendable, Equatable {
    public let heading: String
    public let bullets: [String]
    public init(heading: String, bullets: [String]) {
        self.heading = heading
        self.bullets = bullets
    }
}

/// Turns a raw transcript into a structured Korean summary via the LLM.
/// Output is parsed leniently (free models don't reliably emit strict JSON), so
/// a heading/bullets markdown shape is requested and parsed.
public struct Summarizer: Sendable {
    private let client: LLMClient
    public init(client: LLMClient) { self.client = client }

    private static let system = """
    당신은 한국어 회의록 정리 도우미입니다. 주어진 전사를 읽고 간결하게 정리하세요.
    반드시 아래 형식의 마크다운으로만 답하세요. 군더더기 설명 없이 항목만 작성합니다.

    ## 요약
    - (3~6개 핵심 요약)
    ## 핵심 결정
    - (결정된 사항, 없으면 "- 없음")
    ## 액션 아이템
    - (담당/할 일, 없으면 "- 없음")

    전사에 영어가 섞여 있어도 한국어로 정리합니다.
    """

    public func summarize(transcript: String) async throws -> [SummarySection] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Single-shot. Very long transcripts are truncated from the FRONT so the
        // most recent context survives; map-reduce chunking is a later refinement.
        let maxChars = 24_000
        let input = trimmed.count > maxChars ? String(trimmed.suffix(maxChars)) : trimmed
        let raw = try await client.complete(system: Self.system, user: input)
        return SummaryParser.parse(raw)
    }
}

/// Parses the LLM's markdown-ish output into sections. Tolerant of `#`/`##`
/// headings and `-`/`*`/`•`/numbered bullets, and of stray prose.
public enum SummaryParser {
    public static func parse(_ text: String) -> [SummarySection] {
        var sections: [SummarySection] = []
        var heading: String?
        var bullets: [String] = []

        func flush() {
            if let h = heading {
                sections.append(SummarySection(heading: h, bullets: bullets))
            }
            bullets = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let h = headingText(line) {
                flush()
                heading = h
            } else if let b = bulletText(line) {
                if heading == nil { heading = "요약" }   // bullets before any heading
                if !b.isEmpty { bullets.append(b) }
            }
            // Non-heading, non-bullet prose is ignored.
        }
        flush()
        return sections.filter { !$0.bullets.isEmpty }
    }

    static func headingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        return line.drop(while: { $0 == "#" })
            .trimmingCharacters(in: .whitespaces)
            .nilIfEmpty
    }

    static func bulletText(_ line: String) -> String? {
        for prefix in ["- ", "* ", "• ", "· "] {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        // numbered: "1. ..." / "1) ..."
        if let first = line.first, first.isNumber {
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }) {
                let after = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
                if !after.isEmpty { return after }
            }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
