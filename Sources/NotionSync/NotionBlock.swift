import Foundation

/// A minimal Notion block that encodes to the REST shape, e.g.
/// `{"object":"block","type":"paragraph","paragraph":{"rich_text":[…]}}`.
/// Only the few block types we emit (paragraph, heading_2, bulleted_list_item)
/// are modelled. Long text is split across multiple rich-text runs so no single
/// run exceeds Notion's 2000-character limit.
public struct NotionBlock: Encodable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case paragraph
        case heading2 = "heading_2"
        case bullet = "bulleted_list_item"
    }

    public let kind: Kind
    public let runs: [String]

    public init(kind: Kind, runs: [String]) {
        self.kind = kind
        self.runs = runs
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct RichText: Encodable {
        let content: String
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: DynamicKey.self)
            try c.encode("text", forKey: DynamicKey("type"))
            var textC = c.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("text"))
            try textC.encode(content, forKey: DynamicKey("content"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode("block", forKey: DynamicKey("object"))
        try c.encode(kind.rawValue, forKey: DynamicKey("type"))
        var inner = c.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(kind.rawValue))
        try inner.encode(runs.map(RichText.init(content:)), forKey: DynamicKey("rich_text"))
    }
}
