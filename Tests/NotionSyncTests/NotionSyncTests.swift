import XCTest
@testable import NotionSync

final class PageIDParserTests: XCTestCase {
    func testUndashedURLWithTitleSlug() {
        let url = "https://www.notion.so/My-Meeting-Notes-01ff8594fa8a4fb192cf017f8fdbf8d4"
        XCTAssertEqual(PageIDParser.pageID(from: url),
                       "01ff8594-fa8a-4fb1-92cf-017f8fdbf8d4")
    }

    func testBareUndashedID() {
        XCTAssertEqual(PageIDParser.pageID(from: "01ff8594fa8a4fb192cf017f8fdbf8d4"),
                       "01ff8594-fa8a-4fb1-92cf-017f8fdbf8d4")
    }

    func testAlreadyDashed() {
        let id = "01ff8594-fa8a-4fb1-92cf-017f8fdbf8d4"
        XCTAssertEqual(PageIDParser.pageID(from: id), id)
    }

    func testDatabaseViewQueryIsIgnored() {
        // ?v=<32hex> is the view id — must take the PATH id, not the query id.
        let url = "https://www.notion.so/workspace/01ff8594fa8a4fb192cf017f8fdbf8d4?v=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        XCTAssertEqual(PageIDParser.pageID(from: url),
                       "01ff8594-fa8a-4fb1-92cf-017f8fdbf8d4")
    }

    func testTrailingPvsParam() {
        let url = "https://www.notion.so/Title-01ff8594fa8a4fb192cf017f8fdbf8d4?pvs=4"
        XCTAssertEqual(PageIDParser.pageID(from: url),
                       "01ff8594-fa8a-4fb1-92cf-017f8fdbf8d4")
    }

    func testInvalidReturnsNil() {
        XCTAssertNil(PageIDParser.pageID(from: "https://example.com/not-a-notion-page"))
        XCTAssertNil(PageIDParser.pageID(from: ""))
    }
}

final class BlockBuilderTests: XCTestCase {
    func testShortTextSingleRun() {
        let block = BlockBuilder.paragraph("안녕하세요 deploy 했어요")
        XCTAssertEqual(block.runs.count, 1)
        XCTAssertEqual(block.kind, .paragraph)
    }

    func testExactly2000IsSingleRun() {
        let text = String(repeating: "가", count: 2000)
        XCTAssertEqual(BlockBuilder.runs(text).count, 1)
    }

    func testOver2000Splits() {
        let text = String(repeating: "가", count: 2001)
        let runs = BlockBuilder.runs(text)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].count, 2000)
        XCTAssertEqual(runs[1].count, 1)
    }

    func testKoreanCountsByGrapheme() {
        // 4500 Korean chars → 3 runs of 2000/2000/500
        let text = String(repeating: "한", count: 4500)
        let runs = BlockBuilder.runs(text)
        XCTAssertEqual(runs.map(\.count), [2000, 2000, 500])
    }

    func testTranscriptDropsEmptyLines() {
        let blocks = BlockBuilder.transcript(lines: ["[나] 안녕", "", "[나] 잘 가"])
        XCTAssertEqual(blocks.count, 2)
    }

    func testSummarySkipsEmptySections() {
        let blocks = BlockBuilder.summary(title: "요약", sections: [
            ("핵심 결정", ["A를 한다"]),
            ("액션", [])  // skipped
        ])
        // heading(요약) + heading(핵심 결정) + 1 bullet = 3
        XCTAssertEqual(blocks.count, 3)
    }

    func testBlockEncodesToNotionShape() throws {
        let block = BlockBuilder.paragraph("hi")
        let data = try JSONEncoder().encode(block)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["object"] as? String, "block")
        XCTAssertEqual(json["type"] as? String, "paragraph")
        let para = try XCTUnwrap(json["paragraph"] as? [String: Any])
        let rich = try XCTUnwrap(para["rich_text"] as? [[String: Any]])
        XCTAssertEqual(rich.count, 1)
        XCTAssertEqual(rich[0]["type"] as? String, "text")
        let textObj = try XCTUnwrap(rich[0]["text"] as? [String: Any])
        XCTAssertEqual(textObj["content"] as? String, "hi")
    }
}
