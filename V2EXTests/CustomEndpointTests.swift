import XCTest
@testable import V2EX

@MainActor
final class CustomEndpointTests: XCTestCase {
    private var savedBase: URL?
    private var savedImageBase: URL?

    override func setUp() {
        super.setUp()
        savedBase = V2EXEndpoint.customBase
        savedImageBase = V2EXEndpoint.customImageBase
        V2EXEndpoint.save(base: nil, imageBase: nil)
    }

    override func tearDown() {
        V2EXEndpoint.save(base: savedBase, imageBase: savedImageBase)
        super.tearDown()
    }

    func testParseOriginNormalizesInput() throws {
        XCTAssertNil(try V2EXEndpoint.parseOrigin("  "))
        XCTAssertEqual(try V2EXEndpoint.parseOrigin(" v2.example.com/ ")?.absoluteString, "https://v2.example.com")
        XCTAssertEqual(try V2EXEndpoint.parseOrigin("HTTP://192.168.1.10:8080")?.absoluteString, "http://192.168.1.10:8080")
        XCTAssertEqual(try V2EXEndpoint.parseOrigin("https://my_proxy.example.com")?.host(), "my_proxy.example.com")
    }

    func testParseOriginRejectsPathsAndForeignSchemes() {
        for value in [
            "https://example.com/v2ex",
            "https://example.com/?a=1",
            "https://example.com#top",
            "ftp://example.com",
            "https://user:pass@example.com",
            "https://exa mple.com"
        ] {
            XCTAssertThrowsError(try V2EXEndpoint.parseOrigin(value), value)
        }
    }

    func testOfficialAddressesAreStoredAsUnset() throws {
        V2EXEndpoint.save(
            base: try V2EXEndpoint.parseOrigin("https://www.v2ex.com"),
            imageBase: try V2EXEndpoint.parseOrigin("cdn.v2ex.com")
        )
        XCTAssertNil(V2EXEndpoint.customBase)
        XCTAssertNil(V2EXEndpoint.customImageBase)
        XCTAssertEqual(V2EXEndpoint.base, V2EXEndpoint.officialBase)
    }

    func testOfficialURLsAreUntouchedWithoutProxy() throws {
        for value in ["https://www.v2ex.com/t/1", "https://cdn.v2ex.com/avatar/1.png"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(V2EXEndpoint.routed(url), url)
        }
    }

    func testRequestsImagesAndBrowserLinksUseTheProxy() throws {
        V2EXEndpoint.save(
            base: try V2EXEndpoint.parseOrigin("http://10.0.0.2:8080"),
            imageBase: try V2EXEndpoint.parseOrigin("img.example.com")
        )
        XCTAssertEqual(V2EXEndpoint.url("/api/site/info.json").absoluteString,
                       "http://10.0.0.2:8080/api/site/info.json")
        XCTAssertEqual(V2EXEndpoint.routed(try XCTUnwrap(URL(string: "https://www.v2ex.com/t/1#reply"))).absoluteString,
                       "http://10.0.0.2:8080/t/1#reply")
        XCTAssertEqual(V2EXEndpoint.routed(try XCTUnwrap(URL(string: "https://v2ex.com/go/apple"))).absoluteString,
                       "http://10.0.0.2:8080/go/apple")
        XCTAssertEqual(V2EXEndpoint.routed(try XCTUnwrap(URL(string: "https://cdn.v2ex.com/avatar/a/b/1_large.png?m=2"))).absoluteString,
                       "https://img.example.com/avatar/a/b/1_large.png?m=2")
        XCTAssertEqual(V2EXEndpoint.routed(try XCTUnwrap(URL(string: "https://i.imgur.com/x.png"))).absoluteString,
                       "https://i.imgur.com/x.png")
    }

    func testProxyLinksOpenNatively() throws {
        V2EXEndpoint.save(base: try V2EXEndpoint.parseOrigin("http://10.0.0.2:8080"), imageBase: nil)
        XCTAssertEqual(RootView.linkedTopic(in: try XCTUnwrap(URL(string: "http://10.0.0.2:8080/t/123456"))), 123456)
        XCTAssertEqual(RootView.linkedTopic(in: try XCTUnwrap(URL(string: "https://www.v2ex.com/t/123456"))), 123456)
        XCTAssertNil(RootView.linkedTopic(in: try XCTUnwrap(URL(string: "http://10.0.0.2:9090/t/123456"))))
        XCTAssertEqual(RootView.mentionedMember(in: try XCTUnwrap(URL(string: "http://10.0.0.2:8080/member/Livid"))), "Livid")
    }

    func testSessionCookiesFollowTheActiveHost() throws {
        XCTAssertTrue(V2EXEndpoint.isSessionCookie(domain: ".v2ex.com"))
        XCTAssertTrue(V2EXEndpoint.isSessionCookie(domain: "www.v2ex.com"))
        XCTAssertFalse(V2EXEndpoint.isSessionCookie(domain: "example.com"))

        V2EXEndpoint.save(base: try V2EXEndpoint.parseOrigin("https://v2.example.com"), imageBase: nil)
        XCTAssertTrue(V2EXEndpoint.isSessionCookie(domain: "v2.example.com"))
        XCTAssertTrue(V2EXEndpoint.isSessionCookie(domain: ".example.com"))
        XCTAssertFalse(V2EXEndpoint.isSessionCookie(domain: "v2ex.com"))
    }
}
