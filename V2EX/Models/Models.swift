import Foundation

// MARK: - Node

struct V2Node: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let title: String
    var titleAlternative: String?
    var header: String?
    var footer: String?
    var url: String?
    var topics: Int?
    var stars: Int?
    var avatarLarge: String?
    var avatarNormal: String?
    var parentNodeName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, title, header, footer, url, topics, stars
        case titleAlternative = "title_alternative"
        case avatarLarge = "avatar_large"
        case avatarNormal = "avatar_normal"
        case parentNodeName = "parent_node_name"
    }

    var path: String { "/go/\(name)" }

    var avatarURL: URL? {
        // V2EX serves protocol-relative URLs in some fields.
        guard let raw = avatarNormal ?? avatarLarge, !raw.isEmpty else { return nil }
        return URL(string: raw.hasPrefix("//") ? "https:" + raw : raw)
    }

    /// Placeholder used before a node's real record is fetched.
    static func stub(name: String, title: String? = nil) -> V2Node {
        V2Node(id: 0, name: name, title: title ?? name)
    }
}

// MARK: - Member

struct V2Member: Codable, Identifiable, Hashable {
    /// API 2.0 notification payloads only include `username` — id is absent
    /// there, so it must be optional or the whole list fails to decode.
    var id: Int?
    let username: String
    var url: String?
    var website: String?
    var bio: String?
    var tagline: String?
    var location: String?
    var github: String?
    var created: Int?
    /// API 2.0 member objects carry `avatar`; API 1.0 uses the `_large`/`_normal`
    /// pair. Map all three so avatars resolve on both surfaces.
    var avatar: String?
    var avatarLarge: String?
    var avatarNormal: String?

    enum CodingKeys: String, CodingKey {
        case id, username, url, website, bio, tagline, location, github, created, avatar
        case avatarLarge = "avatar_large"
        case avatarNormal = "avatar_normal"
    }

    /// API 2.0's `avatar` is already a full URL at a good size; API 1.0's
    /// `avatar_large` (73px) is preferred over `avatar_normal` (48px) — a 34pt
    /// tile on a 3× screen needs ~102px, so the normal asset visibly softens.
    var avatarURL: URL? {
        guard let raw = avatar ?? avatarLarge ?? avatarNormal, !raw.isEmpty else { return nil }
        return URL(string: raw.hasPrefix("//") ? "https:" + raw : raw)
    }

    var joinedDays: Int? {
        guard let created else { return nil }
        let seconds = Date().timeIntervalSince1970 - TimeInterval(created)
        return max(0, Int(seconds / 86_400))
    }
}

// MARK: - Topic

struct V2Topic: Codable, Identifiable, Hashable {
    let id: Int
    var title: String
    var content: String?
    var contentRendered: String?
    var url: String?
    var replies: Int
    var created: Int?
    var lastTouched: Int?
    var lastReplyBy: String?
    var node: V2Node?
    var member: V2Member?

    enum CodingKeys: String, CodingKey {
        case id, title, content, url, replies, created, node, member
        case contentRendered = "content_rendered"
        case lastTouched = "last_touched"
        case lastReplyBy = "last_reply_by"
    }

    var webURL: URL { URL(string: url ?? "https://www.v2ex.com/t/\(id)")! }
    var authorName: String { member?.username ?? "" }
    var nodeTitle: String { node?.title ?? node?.name ?? "" }

    /// Posted to V2EX's own `promotions` node — i.e. the site itself has already
    /// declared this commercial. Distinct from `HomeViewModel.isPromotion`, which
    /// guesses at ad copy by keyword to hide spam that hides in ordinary nodes;
    /// this one is authoritative, so it marks rather than hides.
    var isPromotionNode: Bool { node?.name == "promotions" }

    /// Timestamp the list rows sort and display on — last activity, like the site.
    var activityDate: Date? {
        guard let stamp = lastTouched ?? created else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(stamp))
    }

    /// One-line preview under a featured card.
    var excerpt: String {
        let text = (content ?? "").replacingOccurrences(of: "\n", with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Reply

/// 楼主 APPEND（补充内容）。API 1.0/2.0 都不返回，只能从网页 HTML 抓。
/// 新版 V2EX 显示为 "Supplement N · 相对时间"（旧版是 topic_append）。
struct TopicAppend: Codable, Hashable {
    let index: Int          // Supplement 序号（1-based）
    let timeLabel: String   // 相对时间，如 "2 小时 8 分钟前"
    let content: String
}

struct V2Reply: Codable, Identifiable, Hashable {
    let id: Int
    var content: String
    var contentRendered: String?
    var created: Int?
    var topicId: Int?
    var memberId: Int?
    var member: V2Member?

    enum CodingKeys: String, CodingKey {
        case id, content, created, member
        case contentRendered = "content_rendered"
        case topicId = "topic_id"
        case memberId = "member_id"
    }

    var authorName: String { member?.username ?? "" }
    var date: Date? { created.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

/// A reply plus everything the topic view needs to draw it: its floor number
/// and the reply it quotes, if any.
struct ThreadedReply: Identifiable, Hashable {
    let reply: V2Reply
    let floor: Int
    var quoted: QuotedReply?
    var isAuthor: Bool
    let contentBlocks: [ContentBlock]

    var id: Int { reply.id }

    struct QuotedReply: Hashable {
        let username: String
        let floor: Int?
        let excerpt: String
    }
}

// MARK: - Notification (API 2.0)

struct V2Notification: Codable, Identifiable, Hashable {
    let id: Int
    var memberId: Int?
    var forMemberId: Int?
    var text: String?
    var payload: String?
    var payloadRendered: String?
    var created: Int?
    var member: V2Member?

    enum CodingKeys: String, CodingKey {
        case id, text, payload, created, member
        case memberId = "member_id"
        case forMemberId = "for_member_id"
        case payloadRendered = "payload_rendered"
    }

    var date: Date? { created.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var authorName: String { member?.username ?? "" }

    /// `text` arrives as HTML like `<a href="/member/x">x</a> 在 <a …>标题</a> 里回复了你`.
    /// Split it into the verb ("回复了你") and the topic title for the design's
    /// two-line layout.
    var parsed: (action: String, topicTitle: String?, topicID: Int?) {
        let plain = HTMLText.plain(text ?? "")
        let title = HTMLText.firstLinkText(in: text ?? "", matching: "/t/")
        let topicID = HTMLText.firstTopicID(in: text ?? "")
        var action = plain
        if !authorName.isEmpty, action.hasPrefix(authorName) {
            action = String(action.dropFirst(authorName.count))
        }
        if let title, let range = action.range(of: title) {
            action.removeSubrange(range)
        }
        action = action
            .replacingOccurrences(of: "在 ", with: "")
            .replacingOccurrences(of: " 里", with: "")
            .replacingOccurrences(of: "的", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (action.isEmpty ? "有新动态" : action, title, topicID)
    }

    /// Best text for the notification row: server-rendered HTML first, raw
    /// payload second — unless the payload is a JSON string (V2EX does this
    /// for some notification kinds), in which case the readable text is
    /// decoded out of it instead of showing the raw JSON.
    var displayPayload: String? {
        if let rendered = payloadRendered, !rendered.isEmpty { return rendered }
        guard let payload, !payload.isEmpty else { return nil }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return payload }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return payload
        }
        let text = Self.readableText(from: object)
        return text.isEmpty ? payload : text
    }

    /// Recursively pulls readable strings out of an unknown JSON shape,
    /// preferring known V2EX payload keys and then the longest string leaf.
    private static func readableText(from value: Any) -> String {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                if let data = trimmed.data(using: .utf8),
                   let nested = try? JSONSerialization.jsonObject(with: data) {
                    return readableText(from: nested)
                }
            }
            return string
        }
        if let dict = value as? [String: Any] {
            for key in ["content", "text", "title", "reply", "topic_title"] {
                if let s = dict[key] as? String, !s.isEmpty { return s }
            }
            var best = ""
            for (_, child) in dict {
                let s = readableText(from: child)
                if s.count > best.count { best = s }
            }
            return best
        }
        if let array = value as? [Any] {
            return array.map { readableText(from: $0) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return ""
    }

    /// Notification kind drives the scope filter chips.
    var kind: Kind {
        let plain = HTMLText.plain(text ?? "")
        if plain.contains("感谢") { return .thanks }
        if plain.contains("提到了你") || plain.contains("@") { return .mention }
        if plain.contains("收藏") { return .favorite }
        return .reply
    }

    enum Kind: String, CaseIterable {
        case reply, mention, thanks, favorite
    }
}

// MARK: - Search (sov2ex)

struct SearchHit: Identifiable, Hashable {
    let id: Int
    let title: String
    let content: String
    let node: String
    let member: String
    let replies: Int
    let created: String
    /// Segments carrying the `<em>` highlight ranges the design paints yellow.
    let titleSegments: [HighlightSegment]
    let contentSegments: [HighlightSegment]
}

struct HighlightSegment: Hashable {
    let text: String
    let isMatch: Bool
}
