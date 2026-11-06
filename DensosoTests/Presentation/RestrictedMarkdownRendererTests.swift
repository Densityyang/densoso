import XCTest
@testable import Densoso

final class RestrictedMarkdownRendererTests: XCTestCase {
    func testAllowsInlineEmphasisCodeListsAndHTTPSLinks() {
        let document = RestrictedMarkdownRenderer.parse(
            "**重点**、*说明*、`code` 和 [安全链接](https://example.com)。\n\n- 第一项\n- 第二项"
        )

        XCTAssertFalse(document.usedPlainTextFallback)
        XCTAssertEqual(document.blocks.count, 2)
        guard case .list(let items, let ordered) = document.blocks[1] else {
            return XCTFail("Expected list")
        }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items, ["第一项", "第二项"])
    }

    func testStripsNonHTTPSLinksWithoutKeepingDestination() {
        let document = RestrictedMarkdownRenderer.parse("[危险](http://example.com)")
        guard case .paragraph(let text) = document.blocks.first else {
            return XCTFail("Expected paragraph")
        }
        XCTAssertEqual(text, "危险")
        XCTAssertFalse(text.contains("http://"))
    }

    func testHTMLAndImagesFallBackToPlainTextWithoutRawMarkers() {
        for source in ["<script>alert(1)</script>**安全**", "![remote](https://example.com/a.png)"] {
            let document = RestrictedMarkdownRenderer.parse(source)
            XCTAssertTrue(document.usedPlainTextFallback)
            guard case .paragraph(let text) = document.blocks.first else {
                return XCTFail("Expected fallback paragraph")
            }
            XCTAssertFalse(text.contains("<script>"))
            XCTAssertFalse(text.contains("**"))
            XCTAssertFalse(text.contains("https://"))
        }
    }

    func testUnbalancedMarkdownFallsBackWithoutRawAsterisks() {
        let document = RestrictedMarkdownRenderer.parse("这是 **未闭合")
        XCTAssertTrue(document.usedPlainTextFallback)
        guard case .paragraph(let text) = document.blocks.first else {
            return XCTFail("Expected paragraph")
        }
        XCTAssertEqual(text, "这是 未闭合")
    }

    func testAsteriskListIsNotMistakenForUnbalancedItalic() {
        let document = RestrictedMarkdownRenderer.parse("* 第一项\n* 第二项")

        XCTAssertFalse(document.usedPlainTextFallback)
        guard case .list(let items, let ordered) = document.blocks.first else {
            return XCTFail("Expected unordered list")
        }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items, ["第一项", "第二项"])
    }

    func testIntrawordUnderscorePreservesPlainContent() {
        let document = RestrictedMarkdownRenderer.parse("使用 snake_case 字段。")

        XCTAssertFalse(document.usedPlainTextFallback)
        guard case .paragraph(let text) = document.blocks.first else {
            return XCTFail("Expected paragraph")
        }
        XCTAssertEqual(text, "使用 snake_case 字段。")
    }
}
