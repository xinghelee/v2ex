import XCTest
@testable import V2EX

@MainActor
final class ContentLinkRoutingTests: XCTestCase {
    func testV2EXTopicLinksResolveToNativeTopic() throws {
        for value in [
            "https://www.v2ex.com/t/123456",
            "https://v2ex.com/t/123456",
            "http://v2ex.com/t/123456",
            "https://WWW.V2EX.COM/t/123456?p=2#reply42",
            "https://www.v2ex.com/t/123456/",
            "https://www.v2ex.com/t/123456.html",
            "https://www.v2ex.com:443/t/123456"
        ] {
            XCTAssertEqual(RootView.linkedTopic(in: try XCTUnwrap(URL(string: value))), 123456, value)
        }
    }

    func testExternalAndNonTopicLinksRemainWebLinks() throws {
        for value in [
            "https://example.com/t/123456",
            "https://www.v2ex.com.evil.example/t/123456",
            "https://v2ex.com@evil.example/t/123456",
            "https://user@v2ex.com/t/123456",
            "https://v2ex.com:8443/t/123456",
            "ftp://v2ex.com/t/123456",
            "https://www.v2ex.com/go/programmer",
            "https://www.v2ex.com/member/someone",
            "https://www.v2ex.com/t/123456/edit",
            "https://www.v2ex.com/t/0",
            "https://www.v2ex.com/t/-1",
            "https://www.v2ex.com/t/abc",
            "https://www.v2ex.com/t/999999999999999999999999999999",
            "https://www.v2ex.com/t/123456.png"
        ] {
            XCTAssertNil(RootView.linkedTopic(in: try XCTUnwrap(URL(string: value))), value)
        }
    }

    func testRelativeAndProtocolRelativeHTMLLinksResolveToNativeTopic() throws {
        for href in ["/t/123456#reply3", "//v2ex.com/t/123456?p=2", "https://www.v2ex.com/t/123456"] {
            let text = HTMLText.inline("<a href=\"\(href)\">另一个帖子</a>")
            let links = text.runs.compactMap(\.link)
            XCTAssertEqual(links.count, 1)
            XCTAssertEqual(RootView.linkedTopic(in: try XCTUnwrap(links.first)), 123456)
            XCTAssertEqual(String(text.characters), "另一个帖子")
        }
    }

    func testBodyQuoteAndReplyListKeepLinkTargets() throws {
        let blocks = HTMLText.blocks(from: """
        <p>原帖：<a href="/t/123456">链接</a></p>
        <blockquote><a href="/t/234567">引用</a></blockquote>
        <ul><li><a href="/t/345678">回复里的列表链接</a></li></ul>
        """)
        let ids = blocks.flatMap { block -> [Int] in
            let texts: [AttributedString]
            switch block {
            case .paragraph(let text), .quote(let text): texts = [text]
            case .list(let items): texts = items
            default: texts = []
            }
            return texts.flatMap { text in text.runs.compactMap { $0.link.flatMap(RootView.linkedTopic) } }
        }
        XCTAssertEqual(ids, [123456, 234567, 345678])
    }
}
