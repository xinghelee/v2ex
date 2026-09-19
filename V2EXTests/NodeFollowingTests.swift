import XCTest
@testable import V2EX

final class NodeFollowingTests: XCTestCase {
    private let cookie = "test-node-session"

    private func page(_ following: Bool, nodeID: Int = 300, once: Int = 123) -> String {
        let action = following ? "unfavorite" : "favorite"
        let label = following ? "取消收藏" : "加入收藏"
        return "<a href=\"/\(action)/node/\(nodeID)?once=\(once)\">\(label)</a>"
    }

    private func client(_ steps: [NodeRequestProtocol.Step]) -> V2EXClient {
        NodeRequestProtocol.prepare(steps)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NodeRequestProtocol.self]
        return V2EXClient(webSession: URLSession(configuration: config))
    }

    override func tearDown() {
        XCTAssertEqual(NodeRequestProtocol.remaining, 0, "All expected requests must be sent")
        NodeRequestProtocol.prepare([])
        super.tearDown()
    }

    func testParsesChineseAndEnglishButtons() throws {
        let unfollowed = try XCTUnwrap(NodeFavoritePage(html: page(false)))
        XCTAssertFalse(unfollowed.following)
        XCTAssertEqual(unfollowed.nodeID, "300")
        XCTAssertEqual(unfollowed.actionPath, "/favorite/node/300?once=123")
        let english = "<a class='node' href = '/unfavorite/node/300?once=456'><span>Unfavorite</span></a>"
        XCTAssertTrue(try XCTUnwrap(NodeFavoritePage(html: english)).following)
        XCTAssertNotNil(NodeFavoritePage(html: "<a href='/favorite/node/300?once=456'>Favorite This Node</a>"))
    }

    func testRejectsMissingAmbiguousAndUntrustedButtons() {
        for html in [
            "<a href='/signin'>登录</a>",
            "<p>/favorite/node/300?once=123</p>",
            "<a href='https://evil.example/favorite/node/300?once=123'>加入收藏</a>",
            "<a href='/favorite/topic/300?once=123'>加入收藏</a>",
            "<a href='/favorite/node/300'>加入收藏</a>",
            "<a href='/favorite/node/300?once=123&other=1'>加入收藏</a>",
            "<a href='/favorite/node/300?once=123'>取消收藏</a>",
            page(false) + page(true),
            page(false) + page(false, nodeID: 301)
        ] {
            XCTAssertNil(NodeFavoritePage(html: html), html)
        }
    }

    func testFollowsUsingCurrentPageTokenAndChecksFinalState() async throws {
        let client = client([
            .init(path: "/go/programmer", body: page(false, once: 456)),
            .init(path: "/favorite/node/300?once=456", body: "", referer: "/go/programmer"),
            .init(path: "/go/programmer", body: page(true, once: 789))
        ])
        try await client.setNodeFollowing(name: "programmer", following: true, cookie: cookie)
    }

    func testUnfollowsAndChecksFinalState() async throws {
        let client = client([
            .init(path: "/go/programmer", body: page(true)),
            .init(path: "/unfavorite/node/300?once=123", body: "", referer: "/go/programmer"),
            .init(path: "/go/programmer", body: page(false))
        ])
        try await client.setNodeFollowing(name: "programmer", following: false, cookie: cookie)
    }

    func testAlreadyMatchingStateDoesNotSendMutation() async throws {
        for following in [true, false] {
            let client = client([.init(path: "/go/programmer", body: page(following))])
            try await client.setNodeFollowing(name: "programmer", following: following, cookie: cookie)
            XCTAssertEqual(NodeRequestProtocol.remaining, 0)
        }
    }

    func testHTTP200WithoutChangedStateIsFailure() async {
        let client = client([
            .init(path: "/go/programmer", body: page(false)),
            .init(path: "/favorite/node/300?once=123", body: "denied", referer: "/go/programmer"),
            .init(path: "/go/programmer", body: page(false))
        ])
        do {
            try await client.setNodeFollowing(name: "programmer", following: true, cookie: cookie)
            XCTFail("An unchanged page must not count as success")
        } catch V2EXError.nodeFollowFailed {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testChangedNodeIdentityIsFailure() async {
        let client = client([
            .init(path: "/go/programmer", body: page(false)),
            .init(path: "/favorite/node/300?once=123", body: "", referer: "/go/programmer"),
            .init(path: "/go/programmer", body: page(true, nodeID: 301))
        ])
        do {
            try await client.setNodeFollowing(name: "programmer", following: true, cookie: cookie)
            XCTFail("A different node must not count as success")
        } catch V2EXError.nodeFollowFailed {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testExpiredSessionDoesNotSendMutation() async {
        let client = client([.init(path: "/go/programmer", body: "<a href='/signin'>登录</a>")])
        do {
            try await client.setNodeFollowing(name: "programmer", following: true, cookie: cookie)
            XCTFail("Login page must fail")
        } catch V2EXError.sessionExpired {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testLoginRedirectDuringMutationIsFailure() async {
        let client = client([
            .init(path: "/go/programmer", body: page(false)),
            .init(path: "/favorite/node/300?once=123", body: "", referer: "/go/programmer", finalPath: "/signin")
        ])
        do {
            try await client.setNodeFollowing(name: "programmer", following: true, cookie: cookie)
            XCTFail("Login redirect must fail")
        } catch V2EXError.sessionExpired {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testHTTPErrorDoesNotCountAsSuccess() async {
        let client = client([
            .init(path: "/go/programmer", body: page(true)),
            .init(path: "/unfavorite/node/300?once=123", body: "Forbidden", status: 403, referer: "/go/programmer")
        ])
        do {
            try await client.setNodeFollowing(name: "programmer", following: false, cookie: cookie)
            XCTFail("HTTP error must fail")
        } catch V2EXError.badStatus(let status) { XCTAssertEqual(status, 403) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testMissingSessionAndInvalidNodeNeverSendRequest() async {
        let client = client([])
        do {
            try await client.setNodeFollowing(name: "programmer", following: true, cookie: "")
            XCTFail("Missing session must fail")
        } catch V2EXError.sessionExpired {} catch { XCTFail("Unexpected error: \(error)") }
        do {
            try await client.setNodeFollowing(name: "../settings", following: true, cookie: cookie)
            XCTFail("Invalid name must fail")
        } catch V2EXError.nodeFollowFailed {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

private final class NodeRequestProtocol: URLProtocol, @unchecked Sendable {
    struct Step {
        var path: String
        var body: String
        var status = 200
        var referer: String? = nil
        var finalPath: String? = nil
    }

    private static let lock = NSLock()
    private static var steps: [Step] = []

    static func prepare(_ responses: [Step]) {
        lock.lock()
        defer { lock.unlock() }
        steps = responses
    }

    static var remaining: Int {
        lock.lock()
        defer { lock.unlock() }
        return steps.count
    }

    private static func next() -> Step? {
        lock.lock()
        defer { lock.unlock() }
        return steps.isEmpty ? nil : steps.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let step = Self.next(), let url = request.url else {
            XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        XCTAssertEqual(url.absoluteString, V2EXEndpoint.base + step.path)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "test-node-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), step.referer.map { V2EXEndpoint.base + $0 })
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        let responseURL = step.finalPath.map { V2EXEndpoint.url($0) } ?? url
        let response = HTTPURLResponse(url: responseURL, statusCode: step.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(step.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
