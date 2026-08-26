import Foundation

// MARK: - 举报

enum ReportReason: String, Codable, CaseIterable, Identifiable {
    case spam
    case harassment
    case hate
    case sexual
    case violence
    case illegal
    case privacy
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spam: return "垃圾信息或广告"
        case .harassment: return "骚扰、辱骂或人身攻击"
        case .hate: return "仇恨言论或歧视"
        case .sexual: return "色情或性暗示内容"
        case .violence: return "暴力、血腥或自残"
        case .illegal: return "违法或欺诈内容"
        case .privacy: return "泄露他人隐私"
        case .other: return "其他"
        }
    }
}

/// 一条举报（或屏蔽通知）的存档。
///
/// 举报同时是本机隐藏的凭据：`ModerationStore` 用 `targetID` 决定某条内容
/// 还要不要画出来，所以这份记录删了内容就会回来 —— 只能由用户在「内容与
/// 屏蔽」里主动撤销。
struct ContentReport: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// 用户主动举报一条内容或一个人。
        case report
        /// 用户屏蔽了某人 —— Apple 要求屏蔽同样通知开发者。
        case block
    }

    enum TargetType: String, Codable {
        case topic
        case reply
        case member
    }

    var id: UUID
    var kind: Kind
    var targetType: TargetType
    /// 话题/回复是数字 ID，用户是用户名。
    var targetID: String
    var topicID: Int?
    var author: String
    var excerpt: String
    var reason: ReportReason
    var note: String
    var createdAt: Date
    /// 回传成功的时间。nil 表示还在 outbox 里等重试。
    var deliveredAt: Date?

    var isDelivered: Bool { deliveredAt != nil }

    /// 举报对象在 V2EX 上的位置，方便开发者上报给站方。
    var webURL: URL? {
        switch targetType {
        case .topic:
            return URL(string: "https://www.v2ex.com/t/\(targetID)")
        case .reply:
            guard let topicID else { return nil }
            return URL(string: "https://www.v2ex.com/t/\(topicID)#r_\(targetID)")
        case .member:
            return URL(string: "https://www.v2ex.com/member/\(targetID)")
        }
    }

    var summary: String {
        switch targetType {
        case .topic: return "话题 #\(targetID)"
        case .reply: return "回复 #\(targetID)"
        case .member: return "用户 @\(targetID)"
        }
    }
}

// MARK: - 被举报/屏蔽的目标

/// 举报与屏蔽菜单指向的东西。视图层用它把 UI 和 store 解耦：菜单只负责
/// 说「这是谁的哪条内容」，落库和隐藏都在 store 里。
enum ModerationTarget: Hashable, Identifiable {
    case topic(id: Int, author: String, excerpt: String)
    case reply(id: Int, topicID: Int, author: String, excerpt: String)
    case member(username: String)

    var id: String {
        switch self {
        case .topic(let id, _, _): return "topic-\(id)"
        case .reply(let id, _, _, _): return "reply-\(id)"
        case .member(let name): return "member-\(name)"
        }
    }

    var author: String {
        switch self {
        case .topic(_, let author, _), .reply(_, _, let author, _): return author
        case .member(let name): return name
        }
    }

    var kindTitle: String {
        switch self {
        case .topic: return "这个话题"
        case .reply: return "这条回复"
        case .member: return "这个用户"
        }
    }
}

// MARK: - Store

/// 用户侧内容治理：关键词与用户屏蔽、举报、以及举报后的本机即时隐藏。
///
/// 这是一个第三方客户端 —— 内容在 V2EX 的服务器上，App 删不掉也封不了人。
/// 所以「处理」发生在两端：本机立刻并永久地把内容从所有列表和帖内回复里
/// 移除（用户自己不撤销就不会回来），同时把举报回传给开发者去向站方上报。
@MainActor
final class ModerationStore: ObservableObject {
    @Published private(set) var keywords: [String] = []
    @Published private(set) var usernames: [String] = []
    @Published private(set) var hiddenTopicIDs: Set<Int> = []
    @Published private(set) var hiddenReplyIDs: Set<Int> = []
    @Published private(set) var reports: [ContentReport] = []

    /// 屏蔽列表沿用 BlockStore 时代的键，老用户升级后名单不会丢。
    private let keywordKey = "blockedKeywords"
    private let userKey = "blockedUsernames"
    private let file = DiskStore.url(for: "moderation.json")

    private struct Persisted: Codable {
        var hiddenTopicIDs: [Int]
        var hiddenReplyIDs: [Int]
        var reports: [ContentReport]
    }

    init() {
        keywords = UserDefaults.standard.stringArray(forKey: keywordKey) ?? []
        usernames = UserDefaults.standard.stringArray(forKey: userKey) ?? []
        if let saved = DiskStore.load(Persisted.self, from: file) {
            hiddenTopicIDs = Set(saved.hiddenTopicIDs)
            hiddenReplyIDs = Set(saved.hiddenReplyIDs)
            reports = saved.reports
        }
    }

    /// 「我的」里那一行的计数：屏蔽项加上被举报隐藏的内容。
    var count: Int {
        keywords.count + usernames.count + hiddenTopicIDs.count + hiddenReplyIDs.count
    }

    var pendingReportCount: Int { reports.filter { !$0.isDelivered }.count }

    // MARK: 判定与过滤

    func isBlocked(username: String) -> Bool {
        guard !username.isEmpty else { return false }
        return usernames.contains { $0.caseInsensitiveCompare(username) == .orderedSame }
    }

    func matchesKeyword(_ text: String) -> Bool {
        guard !keywords.isEmpty else { return false }
        return keywords.contains { text.localizedCaseInsensitiveContains($0) }
    }

    func isHidden(_ topic: V2Topic) -> Bool {
        if hiddenTopicIDs.contains(topic.id) { return true }
        if isBlocked(username: topic.authorName) { return true }
        return matchesKeyword(topic.title + " " + (topic.content ?? ""))
    }

    func isHidden(reply: V2Reply) -> Bool {
        if hiddenReplyIDs.contains(reply.id) { return true }
        if isBlocked(username: reply.authorName) { return true }
        return matchesKeyword(reply.content)
    }

    func filter(_ topics: [V2Topic]) -> [V2Topic] {
        guard count > 0 else { return topics }
        return topics.filter { !isHidden($0) }
    }

    /// 帖内回复的过滤。楼层号在过滤前就已经算好，所以隐藏一条不会让后面
    /// 的楼层集体前移 —— #5 被隐藏后 #6 仍然叫 #6，引用关系才对得上。
    func visible(_ items: [ThreadedReply]) -> [ThreadedReply] {
        guard count > 0 else { return items }
        return items.filter { !isHidden(reply: $0.reply) }
    }

    // MARK: 屏蔽

    func addKeyword(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !keywords.contains(trimmed) else { return }
        keywords.append(trimmed)
        UserDefaults.standard.set(keywords, forKey: keywordKey)
    }

    func removeKeyword(_ value: String) {
        keywords.removeAll { $0 == value }
        UserDefaults.standard.set(keywords, forKey: keywordKey)
    }

    /// 从某条内容发起的屏蔽。
    ///
    /// 拒审信的原话是「blocking should also notify the developer **of the
    /// inappropriate content**」—— 光报一个用户名不够，开发者得知道是哪条
    /// 内容触发的才有得核实。所以这条 `.block` 记录指向触发它的话题或回复，
    /// 而不是笼统地指向那个人。
    func block(_ target: ModerationTarget) {
        switch target {
        case .topic(let id, let author, let excerpt):
            block(username: author, context: (.topic, String(id), id, excerpt))
        case .reply(let id, let topicID, let author, let excerpt):
            block(username: author, context: (.reply, String(id), topicID, excerpt))
        case .member(let username):
            block(username: username)
        }
    }

    /// 屏蔽一个人。Apple 的 1.2 要求屏蔽也要通知开发者，所以这里除了把人
    /// 加进名单，还会往 outbox 里放一条 `.block` 记录。
    ///
    /// `context` 为空时（在设置里手输用户名）记录只指向这个人本身。
    func block(
        username: String,
        context: (type: ContentReport.TargetType, id: String, topicID: Int?, excerpt: String)? = nil
    ) {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let isNew = !isBlocked(username: trimmed)
        if isNew {
            usernames.append(trimmed)
            UserDefaults.standard.set(usernames, forKey: userKey)
        }
        guard isNew else { return }
        enqueue(
            ContentReport(
                id: UUID(),
                kind: .block,
                targetType: context?.type ?? .member,
                targetID: context?.id ?? trimmed,
                topicID: context?.topicID,
                author: trimmed,
                excerpt: context?.excerpt ?? "",
                reason: .other,
                note: context == nil ? "用户屏蔽（从屏蔽名单添加）" : "用户屏蔽（由这条内容触发）",
                createdAt: Date(),
                deliveredAt: nil
            )
        )
    }

    func unblock(username: String) {
        usernames.removeAll { $0.caseInsensitiveCompare(username) == .orderedSame }
        UserDefaults.standard.set(usernames, forKey: userKey)
    }

    // MARK: 举报

    /// 举报一条内容。内容在这一刻就从本机消失，回传是后台的事 —— 网络失败
    /// 不能让用户继续看见他刚举报的东西。
    func report(_ target: ModerationTarget, reason: ReportReason, note: String) {
        let report: ContentReport
        switch target {
        case .topic(let id, let author, let excerpt):
            hiddenTopicIDs.insert(id)
            report = ContentReport(
                id: UUID(), kind: .report, targetType: .topic, targetID: String(id),
                topicID: id, author: author, excerpt: excerpt, reason: reason,
                note: note, createdAt: Date(), deliveredAt: nil
            )
        case .reply(let id, let topicID, let author, let excerpt):
            hiddenReplyIDs.insert(id)
            report = ContentReport(
                id: UUID(), kind: .report, targetType: .reply, targetID: String(id),
                topicID: topicID, author: author, excerpt: excerpt, reason: reason,
                note: note, createdAt: Date(), deliveredAt: nil
            )
        case .member(let username):
            report = ContentReport(
                id: UUID(), kind: .report, targetType: .member, targetID: username,
                topicID: nil, author: username, excerpt: "", reason: reason,
                note: note, createdAt: Date(), deliveredAt: nil
            )
        }
        enqueue(report)
    }

    /// 撤销 —— 举报和屏蔽都得给得回去的路，否则误触就没救了。
    func unhideTopic(_ id: Int) {
        hiddenTopicIDs.remove(id)
        reports.removeAll { $0.targetType == .topic && $0.targetID == String(id) }
        persist()
    }

    func unhideReply(_ id: Int) {
        hiddenReplyIDs.remove(id)
        reports.removeAll { $0.targetType == .reply && $0.targetID == String(id) }
        persist()
    }

    // MARK: Outbox

    private func enqueue(_ report: ContentReport) {
        reports.insert(report, at: 0)
        persist()
        Task { await flush() }
    }

    /// 把还没送达的举报重发一遍。启动和回前台各调一次就够 —— 举报量小，
    /// 不值得为它常驻一个重试计时器。
    func flush() async {
        let pending = reports.filter { !$0.isDelivered }
        guard !pending.isEmpty else { return }
        var deliveredIDs: Set<UUID> = []
        for report in pending where await ReportService.send(report) {
            deliveredIDs.insert(report.id)
        }
        guard !deliveredIDs.isEmpty else { return }
        let now = Date()
        for index in reports.indices where deliveredIDs.contains(reports[index].id) {
            reports[index].deliveredAt = now
        }
        persist()
    }

    private func persist() {
        DiskStore.save(
            Persisted(
                hiddenTopicIDs: Array(hiddenTopicIDs),
                hiddenReplyIDs: Array(hiddenReplyIDs),
                reports: reports
            ),
            to: file
        )
    }
}
