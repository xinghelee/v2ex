import Foundation

@MainActor
final class TopicDetailViewModel: ObservableObject {
    enum ReplyFilter: String, CaseIterable, Identifiable {
        case byFloor, authorOnly
        var id: String { rawValue }

        var title: String {
            switch self {
            case .byFloor: return "按楼层"
            case .authorOnly: return "只看楼主"
            }
        }
    }

    @Published private(set) var topic: V2Topic?
    @Published private(set) var replies: [ThreadedReply] = []
    @Published private(set) var appends: [TopicAppend] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var repliesErrorMessage: String?
    @Published private(set) var loadedFromOffline = false
    @Published private(set) var topicViews: Int?
    @Published private(set) var contentBlocks: [ContentBlock] = []
    /// PRO members seen on the web page. Scraped, not cached to disk — a
    /// subscription can lapse, and a stale badge is worse than none.
    @Published private(set) var proMembers: Set<String> = []
    @Published var filter: ReplyFilter = .byFloor

    private var rawReplies: [V2Reply] = []
    private var appendBlocksByIndex: [Int: [ContentBlock]] = [:]

    var visibleReplies: [ThreadedReply] {
        switch filter {
        case .byFloor: return replies
        case .authorOnly: return replies.filter(\.isAuthor)
        }
    }

    func contentBlocks(for append: TopicAppend) -> [ContentBlock] {
        appendBlocksByIndex[append.index] ?? []
    }

    /// Raw payload for the offline snapshot.
    var offlinePayload: (V2Topic, [V2Reply])? {
        guard let topic else { return nil }
        return (topic, rawReplies)
    }

    /// Avoid adding an AI card to one-line questions with little discussion.
    func shouldOfferSummary(visibleReplyCount: Int) -> Bool {
        guard let topic else { return false }
        let body = HTMLText.plain(topic.contentRendered ?? topic.content ?? "")
        return body.count >= 600 || visibleReplyCount >= 5 || !appends.isEmpty
    }

    /// Bounded plain text sent to the on-device model when the user requests a
    /// summary. Keep both the opening and the newest replies on very long
    /// threads so the result captures the premise as well as the outcome.
    /// `visibleReplies` has already passed through ModerationStore, preventing
    /// blocked or reported content from resurfacing inside a generated summary.
    func summarySource(from visibleReplies: [ThreadedReply]) -> String {
        guard let topic else { return "" }
        var sections = ["标题：\(topic.title)"]

        let body = HTMLText.plain(topic.contentRendered ?? topic.content ?? "")
        if !body.isEmpty { sections.append("正文：\(Self.clipped(body, limit: 4_000))") }

        for append in appends {
            let text = HTMLText.plain(append.content)
            if !text.isEmpty {
                sections.append("楼主补充 \(append.index)：\(Self.clipped(text, limit: 1_000))")
            }
        }

        let selected: [ThreadedReply]
        if visibleReplies.count <= 32 {
            selected = visibleReplies
        } else {
            selected = Array(visibleReplies.prefix(16)) + Array(visibleReplies.suffix(16))
        }
        let repliesText = selected.map { item in
            let reply = item.reply
            let text = HTMLText.plain(reply.contentRendered ?? reply.content)
            return "#\(item.floor) \(reply.member?.username ?? "匿名")：\(Self.clipped(text, limit: 360))"
        }
        if !repliesText.isEmpty { sections.append("回复：\n" + repliesText.joined(separator: "\n")) }

        return Self.clipped(sections.joined(separator: "\n\n"), limit: 12_000)
    }

    /// Stable across launches, unlike Swift's randomized `Hasher` output.
    func summarySignature(for source: String, visibleReplyCount: Int) -> String {
        guard let topic else { return "topic-unknown" }
        return [
            String(topic.id),
            String(topic.lastTouched ?? topic.created ?? 0),
            String(visibleReplyCount),
            String(appends.count),
            String(Self.stableChecksum(source), radix: 16),
        ].joined(separator: "-")
    }

    private static func stableChecksum(_ text: String) -> UInt64 {
        text.utf8.reduce(1_469_598_103_934_665_603) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    func load(
        id: Int,
        token: String,
        cookie: String,
        cache: TopicDetailCacheStore,
        offline: OfflineStore
    ) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        repliesErrorMessage = nil
        defer { isLoading = false }

        // Hydrate once before the first suspension so the detail view replaces
        // its loading card with cached content immediately. Prefer the newest
        // automatic or explicitly saved snapshot.
        if topic == nil {
            let cached = cache.snapshot(for: id)
            let saved = offline.bundle(for: id)
            if let cached, saved.map({ cached.savedAt >= $0.savedAt }) ?? true {
                apply(
                    topic: cached.topic,
                    replies: cached.replies,
                    appends: cached.appends,
                    topicViews: cached.topicViews,
                    loadedFromOffline: false
                )
            } else if let saved {
                apply(
                    topic: saved.topic,
                    replies: saved.replies,
                    appends: [],
                    topicViews: nil,
                    loadedFromOffline: true
                )
            }
        }

        let fetchedTopic: V2Topic
        do {
            fetchedTopic = try await V2EXClient.shared.topic(id: id, token: token)
            if topic != fetchedTopic { setTopic(fetchedTopic) }
            loadedFromOffline = false
        } catch {
            if topic == nil {
                errorMessage = (error as? V2EXError)?.errorDescription ?? error.localizedDescription
            }
            return
        }

        // The webpage request runs alongside the replies requests. Cached
        // extras remain visible until this completes.
        async let fetchedExtras = try? await V2EXClient.shared.topicPageExtras(id: id, cookie: cookie)

        // Replies are a separate request — a failure here must not masquerade
        // as "no replies" on a thread that clearly has some.
        do {
            let fetchedReplies: [V2Reply]
            if !token.isEmpty {
                // API 2.0 is the maintained surface — v1's replies endpoint
                // returns stale/empty data for recent threads, so don't gate
                // it behind the 100-reply long-thread heuristic.
                // 热门帖分页并行拉取（各页独立），再按 id 恢复时间顺序。
                let total = fetchedTopic.replies
                // v2 replies 每页固定 20 条（实测 p=1 返回 20 条），不是 100 条。
                // 按 100 算页数会把 >20 回复的帖子的最新评论丢在未请求的页里。
                // 20 页 × 20 条 = 400 条封顶，覆盖绝大多数帖子。
                let pageCount = min(20, max(1, Int(ceil(Double(total) / 20.0))))
                var collected: [V2Reply] = []
                try await withThrowingTaskGroup(of: [V2Reply].self) { group in
                    for page in 1...pageCount {
                        group.addTask {
                            try await V2EXClient.shared.topicRepliesPaged(id: id, page: page, token: token)
                        }
                    }
                    for try await batch in group {
                        collected.append(contentsOf: batch)
                    }
                }
                var repliesByID: [Int: V2Reply] = [:]
                for reply in collected { repliesByID[reply.id] = reply }
                fetchedReplies = repliesByID.values.sorted { $0.id < $1.id }
            } else {
                fetchedReplies = try await V2EXClient.shared.replies(topicID: id)
            }

            // An old API response can be empty or partial for recent threads.
            // Keep a more complete cached reply list instead of regressing it.
            let responseLooksIncomplete = !rawReplies.isEmpty
                && fetchedReplies.count < rawReplies.count
                && fetchedTopic.replies >= rawReplies.count
            if !responseLooksIncomplete, fetchedReplies != rawReplies {
                setReplies(fetchedReplies, authorName: fetchedTopic.authorName)
            }
        } catch {
            repliesErrorMessage = (error as? V2EXError)?.errorDescription ?? error.localizedDescription
        }

        // Persist API data as soon as it is complete; the webpage extras can
        // legitimately take longer or time out independently.
        saveCache(to: cache)

        // 浏览数与附言都来自同一个话题页 —— 一次网页抓取解析两者，
        // 避免热门帖串行发两个网页请求拖慢首屏。
        if let extras = await fetchedExtras {
            var changed = false
            if let views = extras.views, views != topicViews {
                topicViews = views
                changed = true
            }
            if !extras.appends.isEmpty, extras.appends != appends {
                setAppends(extras.appends)
                changed = true
            }
            if extras.proMembers != proMembers { proMembers = extras.proMembers }
            if changed { saveCache(to: cache) }
        }
    }

    private func apply(
        topic: V2Topic,
        replies: [V2Reply],
        appends: [TopicAppend],
        topicViews: Int?,
        loadedFromOffline: Bool
    ) {
        setTopic(topic)
        setReplies(replies, authorName: topic.authorName)
        setAppends(appends)
        self.topicViews = topicViews
        self.loadedFromOffline = loadedFromOffline
    }

    private func setReplies(_ replies: [V2Reply], authorName: String) {
        var seen = Set<Int>()
        let uniqueReplies = replies.filter { seen.insert($0.id).inserted }
        rawReplies = uniqueReplies
        self.replies = Self.thread(uniqueReplies, authorName: authorName)
    }

    private func setAppends(_ appends: [TopicAppend]) {
        appendBlocksByIndex = Dictionary(
            uniqueKeysWithValues: appends.map { append in
                (append.index, HTMLText.blocks(from: append.content))
            }
        )
        self.appends = appends
    }

    private func saveCache(to cache: TopicDetailCacheStore) {
        guard let topic else { return }
        cache.save(
            topic: topic,
            replies: rawReplies,
            appends: appends,
            topicViews: topicViews
        )
    }

    private func setTopic(_ topic: V2Topic) {
        let blocks: [ContentBlock]
        if let rendered = topic.contentRendered, !rendered.isEmpty {
            blocks = HTMLText.blocks(from: rendered)
        } else if let content = topic.content, !content.isEmpty {
            blocks = content
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { .paragraph(AttributedString($0)) }
        } else {
            blocks = []
        }
        contentBlocks = blocks
        self.topic = topic
    }

    // MARK: Quote threading

    /// V2EX has no reply-to field: a quote is expressed in the body as
    /// `@someone` (optionally `#12`). Resolve those mentions against the
    /// already-numbered replies so the design's fold-quote block can be drawn.
    static func thread(_ replies: [V2Reply], authorName: String) -> [ThreadedReply] {
        var floorsByAuthor: [String: [Int]] = [:]
        var repliesByFloor: [Int: V2Reply] = [:]

        var result: [ThreadedReply] = []
        result.reserveCapacity(replies.count)

        for (index, reply) in replies.enumerated() {
            let floor = index + 1
            repliesByFloor[floor] = reply

            let quoted = resolveQuote(
                in: reply,
                floorsByAuthor: floorsByAuthor,
                repliesByFloor: repliesByFloor
            )
            let body = bodyWithoutQuotePrefix(
                reply.contentRendered ?? reply.content,
                hasQuote: quoted != nil
            )

            result.append(ThreadedReply(
                reply: reply,
                floor: floor,
                quoted: quoted,
                isAuthor: !authorName.isEmpty && reply.authorName == authorName,
                contentBlocks: HTMLText.blocks(from: body)
            ))

            floorsByAuthor[reply.authorName, default: []].append(floor)
        }
        return result
    }

    private static func resolveQuote(
        in reply: V2Reply,
        floorsByAuthor: [String: [Int]],
        repliesByFloor: [Int: V2Reply]
    ) -> ThreadedReply.QuotedReply? {
        let text = reply.content
        guard let atIndex = text.firstIndex(of: "@") else { return nil }

        // Only treat a mention as a quote when it opens the reply.
        let prefix = text[text.startIndex..<atIndex]
        guard prefix.allSatisfy({ $0.isWhitespace || $0 == ">" }) else { return nil }

        var cursor = text.index(after: atIndex)
        var username = ""
        while cursor < text.endIndex {
            let character = text[cursor]
            guard character.isLetter || character.isNumber || character == "_" || character == "-" else { break }
            username.append(character)
            cursor = text.index(after: cursor)
        }
        guard username.count >= 2 else { return nil }

        // Optional explicit floor: "@user #12".
        var explicitFloor: Int?
        var probe = cursor
        while probe < text.endIndex, text[probe] == " " { probe = text.index(after: probe) }
        if probe < text.endIndex, text[probe] == "#" {
            var digits = ""
            var digitCursor = text.index(after: probe)
            while digitCursor < text.endIndex, text[digitCursor].isNumber {
                digits.append(text[digitCursor])
                digitCursor = text.index(after: digitCursor)
            }
            explicitFloor = Int(digits)
        }

        // Fall back to the mentioned user's most recent floor above this one.
        let floor = explicitFloor ?? floorsByAuthor[username]?.last
        guard let floor, let quoted = repliesByFloor[floor] else {
            return ThreadedReply.QuotedReply(username: username, floor: explicitFloor, excerpt: "")
        }

        let excerpt = HTMLText.plain(quoted.contentRendered ?? quoted.content)
        return ThreadedReply.QuotedReply(
            username: username,
            floor: floor,
            excerpt: excerpt.count > 40 ? String(excerpt.prefix(40)) + "…" : excerpt
        )
    }

    /// Body with the leading `@user #n` stripped — it's shown in the quote block.
    static func bodyWithoutQuotePrefix(_ reply: ThreadedReply) -> String {
        let source = reply.reply.contentRendered ?? reply.reply.content
        return bodyWithoutQuotePrefix(source, hasQuote: reply.quoted != nil)
    }

    /// Removes the opening `@someone`(` #12`) now that the quote block shows it,
    /// leaving the rest of the body's markup intact.
    ///
    /// This used to flatten the whole body with `HTMLText.plain` first, which
    /// also dissolved every other tag in it: a reply opening with
    /// `@a @b @c 好了` came out as text, so b and c stopped being tappable
    /// links — and so did any URL further down the same reply.
    private static func bodyWithoutQuotePrefix(_ source: String, hasQuote: Bool) -> String {
        guard hasQuote else { return source }

        // The mention is an anchor in rendered HTML and bare text in the raw
        // `content` fallback, so accept either shape.
        let pattern = #"^\s*@\s*(?:<a\b[^>]*>[^<]*</a>|[A-Za-z0-9_-]+)\s*(?:#\d+)?\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              match.range.length > 0
        else { return source }

        let remainder = (source as NSString).replacingCharacters(in: match.range, with: "")
        // A reply that was nothing but the mention keeps its original body
        // rather than rendering as an empty bubble.
        return HTMLText.plain(remainder).isEmpty ? source : remainder
    }
}
