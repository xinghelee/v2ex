import Foundation

// MARK: - Models

/// A Hacker News item. One type covers stories, comments and everything else —
/// that is how the Firebase API models it, and pretending otherwise would mean
/// decoding the same JSON into several shapes.
struct HNItem: Codable, Identifiable, Hashable {
    let id: Int
    var type: String?
    var title: String?
    var text: String?
    var url: String?
    var by: String?
    var score: Int?
    var descendants: Int?
    var time: Int?
    var kids: [Int]?
    var parent: Int?
    var deleted: Bool?
    var dead: Bool?

    var date: Date? {
        time.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Host only — a full URL is noise in a list row, the source is the signal.
    var domain: String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var isVisible: Bool { deleted != true && dead != true }

    var hnURL: URL { URL(string: "https://news.ycombinator.com/item?id=\(id)")! }
}

/// A comment plus its depth, flattened for display.
struct HNComment: Identifiable, Hashable {
    let item: HNItem
    let depth: Int
    var id: Int { item.id }
}

// MARK: - Client

/// Hacker News' official Firebase API: public, read-only, no key.
///
/// The awkward part is that it has no batch endpoint — a list of stories is one
/// request for the id list plus one request per item. Hence the bounded
/// concurrency below; firing 30 requests at once is what makes third-party HN
/// clients feel janky on cellular.
actor HNClient {
    static let shared = HNClient()

    private let base = "https://hacker-news.firebaseio.com/v0"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 32 << 20)
        session = URLSession(configuration: configuration)
    }

    enum Feed: String, CaseIterable {
        case top = "topstories"
        case best = "beststories"
        case new = "newstories"
    }

    func stories(_ feed: Feed = .top, limit: Int = 30) async throws -> [HNItem] {
        let ids: [Int] = try await get("/\(feed.rawValue).json")
        return await items(ids: Array(ids.prefix(limit)))
    }

    func item(id: Int) async throws -> HNItem {
        try await get("/item/\(id).json")
    }

    static func log(_ message: String) { print("[hn] \(message)") }

    /// Fetches in order, six at a time. Order matters — the feed's ranking is
    /// the whole point — so results are re-sorted back into the id sequence.
    func items(ids: [Int]) async -> [HNItem] {
        var byID: [Int: HNItem] = [:]
        await withTaskGroup(of: (Int, HNItem?).self) { group in
            var pending = ids.makeIterator()
            var inFlight = 0

            func addNext() {
                guard let id = pending.next() else { return }
                inFlight += 1
                group.addTask { [weak self] in
                    (id, try? await self?.item(id: id))
                }
            }
            for _ in 0..<min(6, ids.count) { addNext() }
            while inFlight > 0, let (id, item) = await group.next() {
                inFlight -= 1
                if let item, item.isVisible { byID[id] = item }
                addNext()
            }
        }
        return ids.compactMap { byID[$0] }
    }

    /// Top-level comments and one level of replies, flattened with depth.
    ///
    /// Deliberately not the full tree: HN threads nest a dozen levels deep and
    /// fetching them all is hundreds of requests for text nobody scrolls to.
    func comments(of story: HNItem, topLevelLimit: Int = 20, repliesPerComment: Int = 3) async -> [HNComment] {
        guard let kids = story.kids, !kids.isEmpty else { return [] }
        Self.log("comments: story=\(story.id) kids=\(kids.count) fetching roots…")
        let roots = await items(ids: Array(kids.prefix(topLevelLimit)))
        Self.log("comments: roots=\(roots.count)")

        // Every reply in one batch, then grouped back onto its parent.
        //
        // The first version fetched each root's replies inside the loop, which
        // is 20 sequential round-trips against an API that has no batch
        // endpoint — that alone made this screen take seconds to appear.
        let replyIDs = roots.flatMap { ($0.kids ?? []).prefix(repliesPerComment) }
        let replies = replyIDs.isEmpty ? [] : await items(ids: Array(replyIDs))
        Self.log("comments: replies=\(replies.count) done")
        let repliesByParent = Dictionary(grouping: replies) { $0.parent ?? -1 }

        return roots.flatMap { root -> [HNComment] in
            [HNComment(item: root, depth: 0)]
                + (repliesByParent[root.id] ?? []).map { HNComment(item: $0, depth: 1) }
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await session.data(from: URL(string: base + path)!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw V2EXError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
