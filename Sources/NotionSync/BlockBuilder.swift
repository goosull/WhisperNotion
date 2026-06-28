import Foundation

/// Turns transcript text and structured summaries into Notion blocks, enforcing
/// the per-run 2000-character limit by splitting long text on grapheme
/// boundaries across multiple rich-text runs within one block.
public enum BlockBuilder {
    public static let maxRunLength = 2000

    /// Split a string into ≤2000-character runs (grapheme-safe).
    static func runs(_ text: String) -> [String] {
        guard text.count > maxRunLength else { return [text] }
        var result: [String] = []
        var current = ""
        current.reserveCapacity(maxRunLength)
        for ch in text {
            current.append(ch)
            if current.count == maxRunLength {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func paragraph(_ text: String) -> NotionBlock {
        NotionBlock(kind: .paragraph, runs: runs(text))
    }

    public static func heading(_ text: String) -> NotionBlock {
        NotionBlock(kind: .heading2, runs: runs(text))
    }

    public static func bullet(_ text: String) -> NotionBlock {
        NotionBlock(kind: .bullet, runs: runs(text))
    }

    /// One paragraph per transcript line. Each line is already speaker-labelled
    /// by the caller (e.g. "[나] …").
    public static func transcript(lines: [String]) -> [NotionBlock] {
        lines.filter { !$0.isEmpty }.map { paragraph($0) }
    }

    /// A structured meeting summary: a heading, then sections of bullets.
    public static func summary(title: String, sections: [(heading: String, bullets: [String])]) -> [NotionBlock] {
        var blocks: [NotionBlock] = [heading(title)]
        for section in sections {
            guard !section.bullets.isEmpty else { continue }
            blocks.append(heading(section.heading))
            blocks.append(contentsOf: section.bullets.map { bullet($0) })
        }
        return blocks
    }
}
