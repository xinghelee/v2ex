import Foundation
import os

enum V2EXError: LocalizedError {
    case badStatus(Int)
    case needsToken
    case rateLimited(resetAt: Date?)
    case decoding(String)
    case webLogin(String)
    case sessionExpired
    case replyFailed(String)
    case postFailed(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "服务器返回 \(code)"
        case .needsToken: return "这个功能需要在设置里填入 Personal Access Token"
        case .rateLimited(let reset):
            guard let reset else { return "请求过于频繁，请稍后再试" }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "已达到 API 频率上限，\(formatter.string(from: reset)) 后恢复"
        case .decoding(let detail): return "解析失败：\(detail)"
        case .webLogin(let reason): return "登录失败：\(reason)"
        case .sessionExpired: return "网页会话已过期，请重新登录"
        case .replyFailed(let detail): return "回复失败：\(detail)"
        case .postFailed(let detail): return detail
        }
    }
}

/// API 2.0 wraps every payload in `{success, message, result}`.
private struct V2Envelope<Value: Decodable>: Decodable {
    let success: Bool?
    let message: String?
    let result: Value?
}

/// Talks to three surfaces:
/// * V2EX API 1.0 — public, no auth, powers everything read-only.
/// * V2EX API 2.0 — needs a Personal Access Token; notifications, own profile,
///   paginated node topics.
/// * sov2ex — the community full-text index, since V2EX exposes no search API.
actor V2EXClient {
    static let shared = V2EXClient()

    private let session: URLSession
    private let responseCache: URLCache
    /// Browser-identifying session for the web forms (login/reply) — v2ex.com
    /// serves different markup to the API User-Agent.
    private let webSession: URLSession
    private let decoder: JSONDecoder

    /// Remaining quota reported by API 2.0, surfaced in settings.
    private(set) var rateLimitRemaining: Int?
    private(set) var rateLimitReset: Date?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .useProtocolCachePolicy
        let responseCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        configuration.urlCache = responseCache
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = [
            "User-Agent": "V2EX-SwiftUI/1.0 (iOS)",
            "Accept": "application/json",
        ]
        session = URLSession(configuration: configuration)
        self.responseCache = responseCache

        let webConfiguration = URLSessionConfiguration.ephemeral
        webConfiguration.timeoutIntervalForRequest = 20
        // 对齐真实浏览器（CDP 抓包的完整 iPhone Safari UA）。
        webConfiguration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
        ]
        webSession = URLSession(configuration: webConfiguration)

        decoder = JSONDecoder()
    }

    func cacheUsage() -> Int {
        responseCache.currentMemoryUsage + responseCache.currentDiskUsage
    }

    func clearCache() {
        responseCache.removeAllCachedResponses()
    }

    // MARK: - API 1.0 (public)

    func latestTopics() async throws -> [V2Topic] {
        try await getV1("/api/topics/latest.json")
    }

    /// `/api/topics/hot.json` 的服务端返回上限。
    private static let hotAPILimit = 10

    /// 「最热」。官方 `/api/topics/hot.json` 服务端硬性只返回 10 条且没有分页
    /// 参数，网页版 `?tab=hot` 同一时刻有 30+ 条——用户对着网页看会觉得 App
    /// 少了一大截。所以优先抓网页（未登录也能拿全），解析结果确实比 API 上限
    /// 多才采用；被改版打残时静默退回 API，最热永远不会空。
    func hotTopics() async throws -> [V2Topic] {
        if let scraped = try? await hotTopicsFromWeb(), scraped.count > Self.hotAPILimit {
            return scraped
        }
        return try await getV1("/api/topics/hot.json")
    }

    private func hotTopicsFromWeb() async throws -> [V2Topic] {
        let html = try await webHTML(path: "/?tab=hot")
        let rows = Self.topicRows(from: html)
        Self.log("hotTopicsFromWeb: rows=\(rows.count) len=\(html.count)")
        return rows
    }

    /// 解析网页首页/节点页的话题行。实测结构（未登录）：
    /// ```
    /// <div class="cell item"><table><tr>
    ///   <td><a href="/member/foo"><img src="…_normal.png" class="avatar" …/></a></td>
    ///   <td><span class="small fade"><a class="node" href="/go/career">职场话题</a>
    ///       &nbsp;•&nbsp; <strong><a href="/member/foo">foo</a></strong></span>
    ///     <span class="item_title"><a href="/t/123#reply22" class="topic-link">标题</a></span>
    ///     <span class="small fade">2 mins ago &nbsp;•&nbsp; Lastly replied by …</span></td>
    ///   <td><a href="/t/123#reply22" class="count_livid">22</a></td>
    /// </tr></table></div>
    /// ```
    /// 逐 cell 切块再取字段：同一块里作者和「最后回复者」用的是同一种
    /// `<strong><a href="/member/…">` 标记，只有按出现顺序取第一个才不会认错人。
    /// 正文网页列表不提供，`content` 留空——只影响首条大卡片的摘要行。
    private static func topicRows(from html: String) -> [V2Topic] {
        var topics: [V2Topic] = []
        var seen = Set<Int>()

        for block in html.components(separatedBy: #"<div class="cell item">"#).dropFirst() {
            guard let title = matches(
                in: block,
                pattern: #"<a href="/t/(\d+)(?:#[^"]*)?"[^>]*class="[^"]*topic-link[^"]*"[^>]*>([\s\S]*?)</a>"#,
                groupCount: 2
            ).first, let id = Int(title[1]), seen.insert(id).inserted else { continue }

            let node = matches(
                in: block,
                pattern: #"<a class="node" href="/go/([^"]+)">([^<]*)</a>"#,
                groupCount: 2
            ).first
            let author = htmlField(block, pattern: #"<strong><a href="/member/([^"]+)">"#)
            let avatar = htmlField(block, pattern: #"<img src="([^"]+)"[^>]*class="avatar""#)
            let replies = htmlField(block, pattern: #"class="count_[a-z]+"[^>]*>(\d+)"#).flatMap(Int.init)
            let touched = htmlField(block, pattern: #"<span class="small fade">([^<]+?)(?:&nbsp;|</span>)"#)
                .flatMap(timestamp(fromRelative:))

            topics.append(V2Topic(
                id: id,
                title: HTMLText.plain(title[2]),
                content: nil,
                contentRendered: nil,
                url: "https://www.v2ex.com/t/\(id)",
                replies: replies ?? 0,
                created: nil,
                lastTouched: touched,
                lastReplyBy: nil,
                node: node.map { V2Node.stub(name: $0[1], title: HTMLText.plain($0[2])) },
                member: author.map {
                    var member = V2Member(username: $0)
                    member.avatarLarge = upscaledAvatar(avatar)
                    member.avatarNormal = avatar
                    return member
                }
            ))
        }
        return topics
    }

    /// 列表 HTML 给的是 24/48px 的小头像，行内 22pt 方块在 3× 屏上要 ~66px 才不糊。
    /// V2EX 自托管头像换 `_large` 变体（73px），gravatar 直接调 `s=` 尺寸参数。
    private static func upscaledAvatar(_ url: String?) -> String? {
        url?
            .replacingOccurrences(of: "_normal.", with: "_large.")
            .replacingOccurrences(of: "?s=24", with: "?s=73")
    }

    /// 网页列表只有相对时间文案，而行上的时间和排序要的是时间戳。未登录取到的
    /// 是英文（"Just Now" / "2 mins ago" / "8h 56m ago" / "3 days ago"），登录态
    /// 是中文，两套都认；认不出就返回 nil，行上不显示时间而不是显示一个错的。
    private static func timestamp(fromRelative label: String) -> Int? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Int(Date().timeIntervalSince1970)
        if text.hasPrefix("just now") || text.hasPrefix("刚刚") { return now }

        let units: [String: Int] = [
            "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1, "秒": 1,
            "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60, "分": 60, "分钟": 60,
            "h": 3_600, "hour": 3_600, "hours": 3_600, "时": 3_600, "小时": 3_600,
            "d": 86_400, "day": 86_400, "days": 86_400, "天": 86_400, "日": 86_400,
            "week": 604_800, "weeks": 604_800, "周": 604_800,
            "mo": 2_592_000, "month": 2_592_000, "months": 2_592_000, "月": 2_592_000, "个月": 2_592_000,
            "year": 31_536_000, "years": 31_536_000, "年": 31_536_000,
        ]
        // "8h 56m ago" 是复合的，所有片段累加才是完整间隔。
        let parts = matches(
            in: text,
            pattern: #"(\d+)\s*(seconds?|secs?|minutes?|mins?|hours?|days?|weeks?|months?|mo|years?|小时|分钟|个月|[smhd秒分时天日周月年])"#,
            groupCount: 2
        )
        guard !parts.isEmpty else { return nil }

        let elapsed = parts.reduce(0) { total, part in
            total + (Int(part[1]) ?? 0) * (units[part[2]] ?? 0)
        }
        guard elapsed > 0 else { return nil }
        return now - elapsed
    }

    func topics(inNode name: String) async throws -> [V2Topic] {
        try await getV1("/api/topics/show.json", query: ["node_name": name])
    }

    func topics(byMember username: String) async throws -> [V2Topic] {
        try await getV1("/api/topics/show.json", query: ["username": username])
    }

    /// 话题详情：有 token 优先 API 2.0（维护中的接口，数据新鲜），
    /// 2.0 失败或无 token 回退 1.0。
    func topic(id: Int, token: String = "") async throws -> V2Topic {
        if !token.isEmpty, let v2 = try? await topicV2(id: id, token: token) {
            return v2
        }
        return try await topicV1(id: id)
    }

    private func topicV1(id: Int) async throws -> V2Topic {
        // v1 returns a single-element array here.
        let results: [V2Topic] = try await getV1("/api/topics/show.json", query: ["id": String(id)])
        guard let topic = results.first else { throw V2EXError.decoding("话题不存在或已删除") }
        return topic
    }

    func replies(topicID: Int) async throws -> [V2Reply] {
        try await getV1("/api/replies/show.json", query: ["topic_id": String(topicID)])
    }

    func allNodes() async throws -> [V2Node] {
        try await getV1("/api/nodes/all.json")
    }

    func node(name: String) async throws -> V2Node {
        try await getV1("/api/nodes/show.json", query: ["name": name])
    }

    func member(username: String) async throws -> V2Member {
        try await getV1("/api/members/show.json", query: ["username": username])
    }

    // MARK: - API 2.0 (token)

    /// Node topics with pagination — only API 2.0 offers `p`.
    func nodeTopicsPaged(name: String, page: Int, token: String) async throws -> [V2Topic] {
        try await getV2("/api/v2/nodes/\(name)/topics", query: ["p": String(page)], token: token)
    }

    /// Single topic via API 2.0 — v1's endpoints are unmaintained and return
    /// stale data for recent threads.
    private func topicV2(id: Int, token: String) async throws -> V2Topic {
        try await getV2("/api/v2/topics/\(id)", query: [:], token: token)
    }

    func topicRepliesPaged(id: Int, page: Int, token: String) async throws -> [V2Reply] {
        try await getV2("/api/v2/topics/\(id)/replies", query: ["p": String(page)], token: token)
    }

    func notifications(page: Int, token: String) async throws -> [V2Notification] {
        try await getV2("/api/v2/notifications", query: ["p": String(page)], token: token)
    }

    func deleteNotification(id: Int, token: String) async throws {
        var request = try makeRequest(path: "/api/v2/notifications/\(id)", query: [:])
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await perform(request)
    }

    func currentMember(token: String) async throws -> V2Member {
        try await getV2("/api/v2/member", query: [:], token: token)
    }

    struct TokenInfo: Codable {
        let token: String?
        let scope: String?
        let expiration: Int?
        let goodForDays: Int?
        let totalUsed: Int?
        let lastUsed: Int?
        let created: Int?

        enum CodingKeys: String, CodingKey {
            case token, scope, expiration, created
            case goodForDays = "good_for_days"
            case totalUsed = "total_used"
            case lastUsed = "last_used"
        }
    }

    func tokenInfo(token: String) async throws -> TokenInfo {
        try await getV2("/api/v2/token", query: [:], token: token)
    }

    // MARK: - Search (sov2ex)

    func search(query: String, from: Int = 0, size: Int = 20, sort: String = "sumup") async throws -> [SearchHit] {
        guard var components = URLComponents(string: "https://www.sov2ex.com/api/search") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "sort", value: sort),
        ]
        guard let url = components.url else { return [] }

        let (data, response) = try await session.data(from: url)
        try validate(response)

        struct Envelope: Decodable {
            struct Hit: Decodable {
                struct Source: Decodable {
                    let id: Int
                    let title: String
                    let content: String
                    let node: Int
                    let member: String
                    let replies: Int
                    let created: String
                }
                struct Highlight: Decodable {
                    let title: [String]?
                    let content: [String]?
                }
                let _source: Source
                let highlight: Highlight?
            }
            let hits: [Hit]
        }

        let envelope = try decoder.decode(Envelope.self, from: data)
        return envelope.hits.map { hit in
            let source = hit._source
            let titleHTML = hit.highlight?.title?.first ?? source.title
            let contentHTML = hit.highlight?.content?.first ?? String(source.content.prefix(120))
            return SearchHit(
                id: source.id,
                title: source.title,
                content: source.content,
                node: String(source.node),
                member: source.member,
                replies: source.replies,
                created: source.created,
                titleSegments: Self.segments(from: titleHTML),
                contentSegments: Self.segments(from: contentHTML)
            )
        }
    }

    /// Splits sov2ex's `<em>`-marked HTML into plain/highlighted runs.
    nonisolated static func segments(from html: String) -> [HighlightSegment] {
        var segments: [HighlightSegment] = []
        var remainder = Substring(html)

        while let open = remainder.range(of: "<em>") {
            let before = String(remainder[remainder.startIndex..<open.lowerBound])
            if !before.isEmpty { segments.append(.init(text: HTMLText.decode(before), isMatch: false)) }
            remainder = remainder[open.upperBound...]

            guard let close = remainder.range(of: "</em>") else { break }
            let match = String(remainder[remainder.startIndex..<close.lowerBound])
            if !match.isEmpty { segments.append(.init(text: HTMLText.decode(match), isMatch: true)) }
            remainder = remainder[close.upperBound...]
        }
        if !remainder.isEmpty {
            segments.append(.init(text: HTMLText.decode(String(remainder)), isMatch: false))
        }
        return segments
    }

    // MARK: - Web scraping (view counts)

    /// V2EX's APIs don't expose view counts — the topic page is the only
    /// source. Parses `N views` (en) / `N 次点击` (zh) out of the HTML.
    /// Failure is silent: callers treat nil as "unknown".
    func topicViews(id: Int) async -> Int? {
        guard let url = URL(string: "https://www.v2ex.com/t/\(id)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await session.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return nil }
        guard let range = html.range(
            of: #"([\d,]+)\s*(?:views|次点击)"#,
            options: .regularExpression
        ) else { return nil }
        return Int(String(html[range]).filter(\.isNumber))
    }

    // MARK: - Plumbing

    private func getV1<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let request = try makeRequest(path: path, query: query)
        let data = try await perform(request)
        return try decode(T.self, from: data)
    }

    private func getV2<T: Decodable>(_ path: String, query: [String: String], token: String) async throws -> T {
        guard !token.isEmpty else { throw V2EXError.needsToken }
        var request = try makeRequest(path: path, query: query)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request)

        let envelope = try decode(V2Envelope<T>.self, from: data)
        guard let result = envelope.result else {
            throw V2EXError.decoding(envelope.message ?? "接口没有返回内容")
        }
        return result
    }

    private func makeRequest(path: String, query: [String: String]) throws -> URLRequest {
        var components = URLComponents(string: "https://www.v2ex.com" + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw V2EXError.decoding("URL 构造失败") }
        var request = URLRequest(url: url)
        // v1 接口经 Cloudflare 缓存 `max-age=432000`（5 天），且 CF 忽略
        // no-cache 请求头 —— 默认 URL 拿到的评论可能滞后数小时甚至 5 天。
        // 追加随机查询参数强制回源（cf-cache-status: MISS），每次拿实时数据；
        // 随机 URL 同时让本地 URLCache 天然失效，双重保证数据新鲜。
        var busted = components
        busted.queryItems = (busted.queryItems ?? []) + [
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000)))
        ]
        if let fresh = busted.url { request.url = fresh }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }

        if let remaining = http.value(forHTTPHeaderField: "X-Rate-Limit-Remaining") {
            rateLimitRemaining = Int(remaining)
        }
        if let reset = http.value(forHTTPHeaderField: "X-Rate-Limit-Reset"), let stamp = TimeInterval(reset) {
            rateLimitReset = Date(timeIntervalSince1970: stamp)
        }

        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw V2EXError.needsToken
        case 429: throw V2EXError.rateLimited(resetAt: rateLimitReset)
        default: throw V2EXError.badStatus(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let preview = String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw V2EXError.decoding("\(error.localizedDescription) \(preview)")
        }
    }
}

// MARK: - Web session (browser login & replies)

/// V2EX 的写操作（发帖/回复）只有网页表单，API 1.0/2.0 都没有。这套方法模拟
/// 网页端：解析每次渲染都变化的随机表单字段、过验证码登录、用会话 cookie
/// 提交回复。cookie 由 `V2EXSessionStore` 保管。
extension V2EXClient {
    /// Web-form diagnostics, viewable with `log stream --predicate 'subsystem == "com.vibe.v2ex"'`.
    private static let webLog = Logger(subsystem: "com.vibe.v2ex", category: "web")

    /// Log to OSLog and stdout (stdout is capturable via
    /// `devicectl device process launch --console`).
    private static func log(_ message: String) {
        webLog.info("\(message)")
        print("[v2ex-web] \(message)")
    }

    struct SignInChallenge {
        let usernameField: String
        let passwordField: String
        let captchaField: String
        let once: String
        let next: String
    }

    /// GET /signin，解析随机字段名、验证码字段与 once。
    /// V2EX 偶尔会返回非标准页面（限流/验证页），解析失败时自动重试。
    func signInChallenge() async throws -> SignInChallenge {
        for attempt in 1...3 {
            let html = try await webHTML(path: "/signin")
            if let challenge = Self.parseSignInChallenge(from: html) {
                Self.log("signInChallenge: once=\(challenge.once) pageLen=\(html.count) attempt=\(attempt)")
                return challenge
            }
            Self.log("signInChallenge: parse failed (attempt \(attempt)/3), html len=\(html.count) prefix=\(String(html.prefix(300)))")
            if attempt < 3 {
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
        throw V2EXError.webLogin("无法解析登录表单，可能被临时风控，请稍后重试")
    }

    private static func parseSignInChallenge(from html: String) -> SignInChallenge? {
        guard let usernameField = Self.htmlField(html, pattern: #"<input type="text" class="sl" name="([^"]+)""#),
              let passwordField = Self.htmlField(html, pattern: #"<input type="password" class="sl" name="([^"]+)""#),
              let captchaField = Self.htmlField(html, pattern: #"/_captcha[\s\S]*?<input type="text" class="sl" name="([^"]+)""#),
              let once = Self.extractOnce(from: html)
        else { return nil }
        return SignInChallenge(
            usernameField: usernameField,
            passwordField: passwordField,
            captchaField: captchaField,
            once: once,
            next: Self.htmlField(html, pattern: #"name="next" value="([^"]+)""#) ?? "/"
        )
    }

    /// 页面里 `once`（CSRF token）的提取：属性顺序不定、中间可能隔其他属性，
    /// 所以用宽松匹配，最后兜底 JS 变量 `once = "..."` 的格式。
    private static func extractOnce(from html: String) -> String? {
        let patterns = [
            #"<input[^>]*\bname="once"[^>]*\bvalue="([^"]+)""#,
            #"<input[^>]*\bvalue="([^"]+)"[^>]*\bname="once""#,
            #"once = "([^"]+)""#,
            #"once=(\d+)""#,
            #"'once':\s*'(\d+)'"#,
            #"name="once" value="([^"]+)""#,
            #"value="([^"]+)" name="once""#,
        ]
        for pattern in patterns {
            if let value = htmlField(html, pattern: pattern) { return value }
        }
        return nil
    }

    /// 登录结果：cookie 先于 2FA 拿到（两步验证是同一会话的延续）。
    struct SignInResult {
        let cookie: String
        let username: String
        let needsTwoFactor: Bool
    }

    /// GET /_captcha —— 登录表单的验证码图片。验证码与 once 绑定，
    /// URL 必须带 `?once=`，否则服务器校验时对不上。
    func captchaImage(once: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://www.v2ex.com/_captcha?once=\(once)")!)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await webSession.data(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            Self.log("captchaImage: HTTP \(http?.statusCode ?? -1)")
            throw V2EXError.webLogin("验证码获取失败")
        }
        Self.log("captchaImage: HTTP 200, \(data.count) bytes")
        return data
    }

    /// POST /signin。成功返回 cookie + 用户名；账号开了两步验证时
    /// `needsTwoFactor` 为 true（会话已建立，还需 POST /2fa）。
    /// 成功与否靠页面里是否出现用户头像判断（登录后 V2EX 渲染头像导航）。
    func signIn(challenge: SignInChallenge, username: String, password: String, captcha: String) async throws -> SignInResult {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: challenge.usernameField, value: username),
            URLQueryItem(name: challenge.passwordField, value: password),
            URLQueryItem(name: challenge.captchaField, value: captcha),
            URLQueryItem(name: "once", value: challenge.once),
            URLQueryItem(name: "next", value: challenge.next),
        ]
        var request = URLRequest(url: URL(string: "https://www.v2ex.com/signin")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // 对齐真实浏览器（CDP 抓包）：Referer + Origin 必须匹配。
        request.setValue("https://www.v2ex.com/signin", forHTTPHeaderField: "Referer")
        request.setValue("https://www.v2ex.com", forHTTPHeaderField: "Origin")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await webSession.data(for: request)
        let http = response as? HTTPURLResponse
        let html = String(data: data, encoding: .utf8) ?? ""
        let finalURL = http?.url?.absoluteString ?? "?"

        // 成功：页面出现用户头像。
        if let avatar = Self.htmlField(html, pattern: #"<img[^>]*class="avatar mobile"[^>]*alt="([^"]+)""#) {
            let cookie = try extractCookies()
            let needs2FA = finalURL.contains("2fa")
            Self.log("signIn ok: user=\(avatar) twoFactor=\(needs2FA) cookie=\(cookie.count) chars url=\(finalURL)")
            return SignInResult(cookie: cookie, username: avatar, needsTwoFactor: needs2FA)
        }
        // 失败：problem 错误块。
        if let problem = Self.htmlField(html, pattern: #"<div id="problem"[^>]*>([\s\S]*?)</div>"#) {
            Self.log("signIn failed: problem=\(HTMLText.plain(problem))")
            throw V2EXError.webLogin(HTMLText.plain(problem))
        }
        Self.log("signIn failed: no avatar, status=\(http?.statusCode ?? -1) url=\(finalURL) htmlLen=\(html.count)")
        throw V2EXError.webLogin("登录失败：请检查用户名、密码或验证码")
    }

    /// GET /2fa 页面取 once —— 两步验证第二步提交需要。
    func twoFactorOnce(cookie: String) async throws -> String {
        let html = try await webHTML(path: "/2fa", cookie: cookie)
        guard let once = Self.extractOnce(from: html) else {
            Self.log("twoFactorOnce: no once in /2fa, len=\(html.count) prefix=\(String(html.prefix(300)))")
            throw V2EXError.sessionExpired
        }
        Self.log("twoFactorOnce: ok once=\(once)")
        return once
    }

    /// POST /2fa 提交 TOTP 码。验证通过时返回**更新后的完整会话 cookie**
    /// （V2EX 在 2FA 通过后刷新会话，必须用新 cookie 发后续请求），
    /// 失败返回 nil。
    func signInTwoFactor(code: String, once: String, cookie: String) async throws -> String? {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "once", value: once),
        ]
        var request = URLRequest(url: URL(string: "https://www.v2ex.com/2fa")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        // 对齐真实浏览器（CDP 抓包）：2FA 的 Referer 是 /2fa，且带 Origin。
        request.setValue("https://www.v2ex.com/2fa", forHTTPHeaderField: "Referer")
        request.setValue("https://www.v2ex.com", forHTTPHeaderField: "Origin")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await webSession.data(for: request)
        let http = response as? HTTPURLResponse
        let finalURL = http?.url?.absoluteString ?? "?"
        let ok = http?.statusCode == 200 && !finalURL.contains("2fa")
        let body = String(data: data, encoding: .utf8) ?? ""
        Self.log("signInTwoFactor: code=\(code) once=\(once) cookieLen=\(cookie.count) status=\(http?.statusCode ?? -1) url=\(finalURL) ok=\(ok)")
        guard ok else {
            // 2FA 的错误提示不在 problem 块里 —— 打完整 body 定位真实原因。
            let title = Self.htmlField(body, pattern: #"<title>([^<]*)</title>"#) ?? ""
            Self.log("signInTwoFactor rejected: title=\(title) bodyLen=\(body.count)")
            return nil
        }
        return try extractCookies()
    }

    /// 用 cookie GET /settings 验证会话是否仍有效（200 且停在 /settings = 已登录）。
    func verifySession(cookie: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://www.v2ex.com/settings")!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (_, response) = try? await webSession.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url?.path == "/settings" else { return false }
        return true
    }

    /// POST /t/{id} —— V2EX 网页回复表单的端点（非 /api/topics/...）。
    /// 成功 = 302 回话题页（URLSession 跟随 → 200 页面含新回复）；
    /// 失败 = 200 提示页（冷却/风控），必须检查内容再下结论。
    func reply(topicID: Int, content: String, cookie: String) async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw V2EXError.replyFailed("回复内容不能为空") }

        let once = try await replyOnce(topicID: topicID, cookie: cookie)
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "content", value: trimmed),
            URLQueryItem(name: "once", value: once),
        ]
        var request = URLRequest(url: URL(string: "https://www.v2ex.com/t/\(topicID)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.v2ex.com/t/\(topicID)", forHTTPHeaderField: "Referer")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await webSession.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 200:
            let body = String(data: data, encoding: .utf8) ?? ""
            // V2EX 有回复冷却：间隔太短时返回 200 提示页（不是 problem div）。
            if body.contains("你上一次回复是在") {
                Self.log("reply rate limited: topic=\(topicID)")
                throw V2EXError.replyFailed("回复过于频繁，V2EX 有回复间隔限制，请稍后再试")
            }
            if let problem = Self.htmlField(body, pattern: #"<div[^>]*class="problem[^"]*"[^>]*>([\s\S]*?)</div>"#) {
                Self.log("reply rejected: topic=\(topicID) problem=\(HTMLText.plain(problem))")
                throw V2EXError.replyFailed(HTMLText.plain(problem))
            }
            // 成功 = 跟随 302 后的话题页包含刚发的回复内容。
            let probe = String(trimmed.prefix(40))
            if !probe.isEmpty, body.contains(probe) {
                Self.log("reply succeeded: topic=\(topicID) bytes=\(data.count)")
                return
            }
            let title = Self.htmlField(body, pattern: #"<title>([^<]*)</title>"#) ?? ""
            Self.log("reply 200 no confirmation: topic=\(topicID) title=\(title) bytes=\(data.count)")
            throw V2EXError.replyFailed("回复未成功，请稍后重试")
        case 403:
            // once 过期 —— 重新取 once 再试一次。
            Self.log("reply once expired, retrying once: topic=\(topicID)")
            var retry = request
            var retryComponents = components
            retryComponents.queryItems = [
                URLQueryItem(name: "content", value: trimmed),
                URLQueryItem(name: "once", value: try await replyOnce(topicID: topicID, cookie: cookie)),
            ]
            retry.httpBody = retryComponents.percentEncodedQuery?.data(using: .utf8)
            let (retryData, retryResponse) = try await webSession.data(for: retry)
            let retryBody = String(data: retryData, encoding: .utf8) ?? ""
            if (retryResponse as? HTTPURLResponse)?.statusCode == 200, retryBody.contains(String(trimmed.prefix(40))), !retryBody.contains("你上一次回复是在") {
                Self.log("reply retry succeeded: topic=\(topicID)")
                return
            }
            // 403 可能是会话失效，也可能只是临时拒绝 —— 验证 cookie 再下结论。
            let sessionOK = await verifySession(cookie: cookie)
            Self.log("reply retry failed: HTTP \((retryResponse as? HTTPURLResponse)?.statusCode ?? -1) sessionOK=\(sessionOK) body=\(retryBody.prefix(300))")
            if sessionOK {
                throw V2EXError.replyFailed("回复被服务器拒绝，请稍后重试")
            }
            throw V2EXError.sessionExpired
        default:
            let message = String(data: data, encoding: .utf8) ?? ""
            Self.log("reply failed: topic=\(topicID) HTTP \(http?.statusCode ?? -1) body=\(message.prefix(200))")
            throw V2EXError.replyFailed(message.isEmpty ? "HTTP \(http?.statusCode ?? -1)" : HTMLText.plain(message))
        }
    }

    /// 一次抓取话题页，同时解析浏览数与附言 —— 两者都来自同一个页面，
    /// 分开请求会浪费一次完整的网页往返（热门帖首屏明显变慢）。
    func topicPageExtras(
        id: Int,
        cookie: String
    ) async throws -> (views: Int?, appends: [TopicAppend], proMembers: Set<String>) {
        var request = URLRequest(url: URL(string: "https://www.v2ex.com/t/\(id)")!)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await webSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw V2EXError.decoding("话题页加载失败：/t/\(id)")
        }
        var views: Int?
        if let range = html.range(of: #"([\d,]+)\s*(?:views|次点击)"#, options: .regularExpression) {
            views = Int(String(html[range]).filter(\.isNumber))
        }
        return (views, Self.extractAppends(from: html), Self.extractProMembers(from: html))
    }

    /// Usernames wearing V2EX's PRO badge on this page.
    ///
    /// Neither API version carries the field, so the web page is the only
    /// source. The markup puts the badge in a container that follows the
    /// author's own link:
    /// `<a href="/member/ybz">ybz</a> … <div class="badges"><div class="badge pro">PRO</div></div>`
    /// so each badge belongs to the nearest `/member/` link before it.
    static func extractProMembers(from html: String) -> Set<String> {
        guard let memberPattern = try? NSRegularExpression(pattern: #"/member/([A-Za-z0-9_-]+)"#),
              let badgePattern = try? NSRegularExpression(pattern: #"<div class="badge pro">"#)
        else { return [] }

        let text = html as NSString
        let whole = NSRange(location: 0, length: text.length)
        let members = memberPattern.matches(in: html, range: whole)
        guard !members.isEmpty else { return [] }

        var found: Set<String> = []
        var cursor = 0
        // Both match lists come back in document order, so a single forward
        // walk pairs every badge with its owner.
        for badge in badgePattern.matches(in: html, range: whole) {
            while cursor + 1 < members.count,
                  members[cursor + 1].range.location < badge.range.location {
                cursor += 1
            }
            let owner = members[cursor]
            guard owner.range.location < badge.range.location, owner.numberOfRanges > 1 else { continue }
            found.insert(text.substring(with: owner.range(at: 1)))
        }
        return found
    }

    /// 抓取楼主 APPEND（追加内容）。API 1.0/2.0 都不返回这个字段，
    /// 只能从网页话题页解析 `<div class="topic_append">` 块。
    /// 注意：V2EX 对未登录访问隐藏 APPEND，需要登录 cookie 才能抓到。
    func topicAppends(id: Int, cookie: String) async throws -> [TopicAppend] {
        var request = URLRequest(url: URL(string: "https://www.v2ex.com/t/\(id)")!)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await webSession.data(for: request)
        let http = response as? HTTPURLResponse
        let html = String(data: data, encoding: .utf8) ?? ""
        let title = Self.htmlField(html, pattern: #"<title>([^<]*)</title>"#) ?? ""
        let finalURL = http?.url?.absoluteString ?? "?"
        let appends = Self.extractAppends(from: html)
        Self.log("topicAppends: topic=\(id) status=\(http?.statusCode ?? -1) url=\(finalURL) title=\(title) found=\(appends.count) supplementHits=\((try? NSRegularExpression(pattern: #"Supplement \d+"#))?.matches(in: html, range: NSRange(html.startIndex..., in: html)).count ?? -1) len=\(html.count)")
        for append in appends {
            Self.log("topicAppends append[\(append.index)] time=\(append.timeLabel) contentLen=\(append.content.count) content=\(String(append.content.prefix(100)))")
        }
        if appends.isEmpty {
            // 诊断：登录态页面的 subtle 块（Supplement 所在区域）内容。
            let subtleCount = html.components(separatedBy: #"class="subtle""#).count - 1
            Self.log("topicAppends: subtle blocks=\(subtleCount)")
            if let r = html.range(of: #"class="subtle""#) {
                let snippet = String(html[r.lowerBound...].prefix(700)).replacingOccurrences(of: "\n", with: " ")
                Self.log("topicAppends first subtle: \(snippet)")
            }
        }
        return appends
    }

    // MARK: - Favorites (web session)

    /// 主题页收藏区：是否已收藏 + 页面 once。
    /// V2EX 收藏是 toggle：未收藏时按钮为「加入收藏」，已收藏时按钮为「取消收藏」。
    struct FavoritePageInfo {
        let favorited: Bool
        let once: String
    }

    /// 从登录态主题页解析收藏状态与 once。
    /// 未收藏 → `/favorite/topic/:id?once=…`「加入收藏」；
    /// 已收藏 → `/unfavorite/topic/:id?once=…`「取消收藏」。
    func favoritePageInfo(topicID: Int, cookie: String) async throws -> FavoritePageInfo {
        let html = try await webHTML(path: "/t/\(topicID)", cookie: cookie)
        let favorited = !html.contains("加入收藏")
        guard let once = Self.htmlField(html, pattern: #"/(?:favorite|unfavorite)/topic/\d+\?once=(\d+)"#) else {
            Self.log("favoritePageInfo: no favorite once, topic=\(topicID) len=\(html.count)")
            throw V2EXError.sessionExpired
        }
        return FavoritePageInfo(favorited: favorited, once: once)
    }

    /// toggle 收藏：GET /favorite（或 /unfavorite）/topic/:id?once=…，302 回主题页。
    /// 返回操作后的新状态（true = 已收藏）。
    func toggleFavorite(topicID: Int, cookie: String) async throws -> Bool {
        let info = try await favoritePageInfo(topicID: topicID, cookie: cookie)
        let action = info.favorited ? "unfavorite" : "favorite"
        guard let url = URL(string: "https://www.v2ex.com/\(action)/topic/\(topicID)?once=\(info.once)") else {
            throw V2EXError.webLogin("收藏链接构造失败")
        }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.v2ex.com/t/\(topicID)", forHTTPHeaderField: "Referer")
        let (_, response) = try await webSession.data(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            Self.log("toggleFavorite: HTTP \(http?.statusCode ?? -1) topic=\(topicID)")
            throw V2EXError.webLogin("收藏操作失败，请稍后重试")
        }
        // favorite/unfavorite 接口返回轻量响应（非主题页），无法从 body 判断
        // 新状态；请求 200 即成功，新状态 = 操作前状态的翻转。
        let newFavorited = !info.favorited
        Self.log("toggleFavorite: topic=\(topicID) old=\(info.favorited) new=\(newFavorited)")
        return newFavorited
    }

    /// 收藏列表：GET /my/topics（登录态，分页拉全）。行结构实测：
    /// `<span class="item_title"><a href="/t/123#reply4" class="topic-link">标题</a></span>`
    /// 回复数在同一行尾部 `<a href="/t/123#reply4" class="count_orange">4</a>`。
    /// 每页 20 条，逐页抓取直到空页或上限（10 页 = 200 条）。
    func favoriteTopics(cookie: String, maxPages: Int = 10) async throws -> [V2Topic] {
        let titlePattern = #"<a href="/t/(\d+)(?:#[^"]*)?"[^>]*class="[^"]*topic-link[^"]*"[^>]*>([\s\S]*?)</a>"#
        let countPattern = #"<a href="/t/(\d+)(?:#[^"]*)?"[^>]*class="(?:count_orange|count_gray)"[^>]*>(\d+)"#

        var all: [V2Topic] = []
        var page = 1
        let pageLimit = min(max(maxPages, 1), 10)
        while page <= pageLimit {
            let path = page == 1 ? "/my/topics" : "/my/topics?p=\(page)"
            let html = try await webHTML(path: path, cookie: cookie)
            guard html.contains("topic-link"), !html.contains("Object Not Found") else {
                if page > 1 { break }  // 后续页不存在，说明已拉完
                Self.log("favoriteTopics: unexpected page len=\(html.count)")
                throw V2EXError.sessionExpired
            }
            let titles = Self.matches(in: html, pattern: titlePattern, groupCount: 2)
            let counts = Self.matches(in: html, pattern: countPattern, groupCount: 2)
            let replyCounts: [Int: Int] = counts.reduce(into: [:]) { result, m in
                if let id = Int(m[1]), let replies = Int(m[2]) { result[id] = replies }
            }
            Self.log("favoriteTopics: page=\(page) rows=\(titles.count)")
            for m in titles {
                guard let id = Int(m[1]) else { continue }
                all.append(V2Topic(
                    id: id,
                    title: HTMLText.plain(m[2]),
                    content: nil,
                    contentRendered: nil,
                    url: "https://www.v2ex.com/t/\(id)",
                    replies: replyCounts[id] ?? 0,
                    created: nil,
                    lastTouched: nil,
                    lastReplyBy: nil,
                    node: nil,
                    member: nil
                ))
            }
            if titles.count < 20 { break }  // 不满一页 = 最后一页
            page += 1
        }
        return all
    }

    /// 网页「我收藏的节点」——API 2.0 没有关注节点接口，从 /my/nodes 抓取。
    /// 节点链接形如 `<a href="/go/programmer">程序员</a>`，href 就是 API 的
    /// 英文 node name。未登录（被重定向到 /signin）时抛 sessionExpired。
    func favoriteNodes(cookie: String) async throws -> [String] {
        let html = try await webHTML(path: "/my/nodes", cookie: cookie)
        guard !html.contains("You need to sign in"), !html.contains("/signin") else {
            Self.log("favoriteNodes: not signed in")
            throw V2EXError.sessionExpired
        }
        let names = Self.matches(in: html, pattern: #"href="/go/([a-zA-Z0-9_-]+)""#, groupCount: 1)
            .map { $0[1] }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        Self.log("favoriteNodes: \(unique.count) nodes")
        return unique
    }

    /// 解析补充内容块。V2EX 改版后的结构：
    /// `<div class="subtle"><span class="fade">Supplement 1 · 2 小时 8 分钟前</span>
    ///  <div class="topic_content">正文…</div></div>`
    /// 旧版结构：`<div class="topic_append">楼主在 <span class="time">…</span> 添加了新内容
    ///  <div class="topic_append_content">正文…</div></div>`
    private static func extractAppends(from html: String) -> [TopicAppend] {
        var result: [TopicAppend] = []

        // 新版附言块。登录态显示「第 1 条附言」，未登录/爬虫显示 "Supplement 1"。
        let supplementPattern = #"<div class="subtle">[\s\S]*?<span class="fade">[^<]*?(\d+)[^<]*?·\s*([^<]+)</span>[\s\S]*?<div class="topic_content">([\s\S]*?)</div>"#
        for match in Self.matches(in: html, pattern: supplementPattern, groupCount: 3) {
            // match[0] 是完整匹配，[1]=序号 [2]=时间 [3]=内容（保留 HTML，链接才能渲染成可点击）。
            let index = Int(match[1]) ?? result.count + 1
            let time = match[2]
                .replacingOccurrences(of: "&nbsp;", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let content = match[3].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            result.append(TopicAppend(index: index, timeLabel: time, content: content))
        }

        // 旧版 topic_append 块（老帖可能还是旧结构）。
        let marker = #"<div class="topic_append">"#
        var searchStart = html.startIndex
        while let blockStart = html.range(of: marker, range: searchStart..<html.endIndex) {
            let block = html[blockStart.upperBound..<html.endIndex]
            guard let contentRange = block.range(of: #"<div class="topic_append_content">"#) else { break }
            let head = block[..<contentRange.lowerBound]
            let content = block[contentRange.upperBound...]
                .prefix(while: { $0 != "<" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let timeStr = Self.htmlField(String(head), pattern: #"<span class="time">([^<]+)</span>"#) ?? ""
            result.append(TopicAppend(index: result.count + 1, timeLabel: timeStr, content: String(content)))
            searchStart = contentRange.upperBound
        }

        return result
    }

    /// 返回正则所有匹配，每组捕获对应一个数组元素。
    private static func matches(in string: String, pattern: String, groupCount: Int) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            guard match.numberOfRanges == groupCount + 1 else { return nil }
            return (0...groupCount).map { i in
                guard let r = Range(match.range(at: i), in: string) else { return "" }
                return String(string[r])
            }
        }
    }

    /// Publishes a new topic and returns its id.
    ///
    /// Neither API version has a write endpoint, so this drives the same web
    /// form the site itself posts: fetch `/write` for the `once` token, then
    /// POST it back with the session cookie — exactly how `reply` works.
    ///
    /// Success is confirmed only by landing on a real `/t/<id>` URL. Sniffing
    /// the response body for the text we just sent (as `reply` does) is too
    /// loose here: a rejection page echoes the draft back into the form, which
    /// would read as success and lose the user's post.
    func createTopic(
        title: String,
        content: String,
        nodeName: String,
        cookie: String,
        username: String
    ) async throws -> Int {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw V2EXError.postFailed("标题不能为空") }
        guard !nodeName.isEmpty else { throw V2EXError.postFailed("请先选择节点") }
        guard !cookie.isEmpty else { throw V2EXError.sessionExpired }

        let formPath = "/write?node=\(nodeName)"
        let form = try await webHTML(path: formPath, cookie: cookie)
        if Self.mentionsCaptcha(form) {
            throw V2EXError.postFailed("V2EX 要求验证码，这一步只能在网页完成")
        }
        guard let once = Self.extractOnce(from: form) else {
            Self.log("createTopic: no once in \(formPath), len=\(form.count)")
            throw V2EXError.sessionExpired
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "title", value: trimmedTitle),
            URLQueryItem(name: "content", value: content),
            URLQueryItem(name: "node_name", value: nodeName),
            URLQueryItem(name: "syntax", value: "markdown"),
            URLQueryItem(name: "once", value: once),
        ]
        var request = URLRequest(url: URL(string: "https://www.v2ex.com/write")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.v2ex.com" + formPath, forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await webSession.data(for: request)
        let http = response as? HTTPURLResponse
        let body = String(data: data, encoding: .utf8) ?? ""

        let finalURL = http?.url?.absoluteString ?? ""
        Self.log("createTopic posted: node=\(nodeName) status=\(http?.statusCode ?? -1) final=\(finalURL) bytes=\(data.count)")

        // Fast path: the redirect landed on the new topic.
        if let id = Self.topicID(inPath: finalURL) {
            Self.log("createTopic succeeded via redirect: id=\(id)")
            return id
        }

        // An explicit rejection is worth reporting verbatim before anything else.
        if let problem = Self.htmlField(body, pattern: #"<div[^>]*class="problem[^"]*"[^>]*>([\s\S]*?)</div>"#) {
            let message = HTMLText.plain(problem)
            Self.log("createTopic rejected: node=\(nodeName) problem=\(message)")
            throw V2EXError.postFailed(message)
        }
        if Self.mentionsCaptcha(body) {
            throw V2EXError.postFailed("V2EX 要求验证码，这一步只能在网页完成")
        }

        // No redirect and no error page. Rather than guess from the HTML, ask
        // the API whether the topic now exists — the first attempt at this
        // reported failure for a post that had in fact gone out, and a false
        // negative is how people end up posting twice.
        if !username.isEmpty, let id = try? await recentTopicID(matching: trimmedTitle, by: username) {
            Self.log("createTopic confirmed via API: id=\(id)")
            return id
        }

        Self.log("createTopic unconfirmed: node=\(nodeName) status=\(http?.statusCode ?? -1)")
        throw V2EXError.postFailed("发布结果未确认。请到网页查看是否已发出，避免重复发送。")
    }

    /// The id of a topic by `username` whose title matches exactly, if V2EX is
    /// already listing it. Used to confirm a publish whose HTTP response gave
    /// nothing away.
    private func recentTopicID(matching title: String, by username: String) async throws -> Int {
        // V2EX indexes a new topic with a short lag, so give it a couple of tries.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            guard let topics = try? await topics(byMember: username) else { continue }
            if let match = topics.first(where: {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == title
            }) {
                return match.id
            }
        }
        throw V2EXError.decoding("未在最近主题中找到刚发布的标题")
    }

    /// The topic id of a `v2ex.com/t/<digits>` URL, and nothing else.
    ///
    /// Anchored at the path root on purpose: this is what decides whether a
    /// post went out. A loose search for `/t/` anywhere in the string would
    /// read some unrelated landing page as success and throw the draft away.
    private static func topicID(inPath url: String) -> Int? {
        guard let components = URLComponents(string: url) else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "t" else { return nil }
        return Int(parts[1])
    }

    private static func mentionsCaptcha(_ html: String) -> Bool {
        html.contains("captcha") || html.contains("验证码")
    }

    private func replyOnce(topicID: Int, cookie: String) async throws -> String {
        let html = try await webHTML(path: "/t/\(topicID)", cookie: cookie)
        guard let once = Self.extractOnce(from: html) else {
            Self.log("replyOnce: no once in /t/\(topicID), len=\(html.count) prefix=\(String(html.prefix(300)))")
            throw V2EXError.sessionExpired
        }
        return once
    }

    private func extractCookies() throws -> String {
        guard let url = URL(string: "https://www.v2ex.com/"),
              let cookies = webSession.configuration.httpCookieStorage?.cookies(for: url),
              !cookies.isEmpty else {
            throw V2EXError.webLogin("未获得会话")
        }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func webHTML(path: String, cookie: String? = nil) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.v2ex.com" + path)!)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await webSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw V2EXError.decoding("网页加载失败：\(path)")
        }
        return html
    }

    private static func htmlField(_ html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else {
            return nil
        }
        return String(html[Range(match.range(at: 1), in: html)!])
    }
}
