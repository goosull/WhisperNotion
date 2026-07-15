import XCTest
@testable import Summarization

final class SummaryParserTests: XCTestCase {
    func testParsesStandardFormat() {
        let md = """
        ## 요약
        - 기아와 두산의 경기
        - 4회까지 무실점
        ## 핵심 결정
        - 다음 회의는 금요일
        ## 액션 아이템
        - 승원: 보고서 작성
        """
        let s = SummaryParser.parse(md)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[0].heading, "요약")
        XCTAssertEqual(s[0].bullets, ["기아와 두산의 경기", "4회까지 무실점"])
        XCTAssertEqual(s[2].bullets, ["승원: 보고서 작성"])
    }

    func testHandlesNumberedAndStarBullets() {
        let md = """
        # 요약
        1. 첫째
        2) 둘째
        * 셋째
        • 넷째
        """
        let s = SummaryParser.parse(md)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].bullets, ["첫째", "둘째", "셋째", "넷째"])
    }

    func testBulletsBeforeHeadingGetDefault() {
        let s = SummaryParser.parse("- 머리말 없는 항목")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].heading, "요약")
    }

    func testDropsEmptySections() {
        let md = """
        ## 요약
        - 내용
        ## 핵심 결정
        ## 액션 아이템
        - 할 일
        """
        let s = SummaryParser.parse(md)
        // 핵심 결정 has no bullets → dropped
        XCTAssertEqual(s.map(\.heading), ["요약", "액션 아이템"])
    }

    func testIgnoresProse() {
        let md = """
        다음은 요약입니다.
        ## 요약
        - 핵심
        감사합니다.
        """
        let s = SummaryParser.parse(md)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].bullets, ["핵심"])
    }

    func testPresetsHaveOllamaCloudDefault() {
        XCTAssertEqual(LLMClient.presets.first?.id, "ollama-cloud")
        XCTAssertNotNil(LLMClient.preset(id: "local-ollama"))
    }
}
