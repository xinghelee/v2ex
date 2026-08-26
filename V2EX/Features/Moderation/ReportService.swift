import Foundation

/// 举报回传。
///
/// App 本身没有后端 —— 内容在 V2EX 的服务器上。这里把举报送到开发者自己的
/// 收件端点，由开发者在 24 小时内核实并向 V2EX 站方上报；用户侧的隐藏在
/// `ModerationStore` 里已经先一步生效，不依赖这次网络请求成功。
enum ReportService {
    /// 收件端点。Cloudflare Worker，源码与部署说明见 `docs/report-worker/`。
    ///
    /// 用的是自有域而不是默认的 `*.workers.dev` —— 后者在中国大陆不可达，而
    /// V2EX 用户主体在大陆，用默认域等于把他们的举报永久卡在本机 outbox 里。
    ///
    /// 置空则举报只在本机生效并留在 outbox，填回 URL 后下次启动自动补发。
    static let endpointString = "https://reports.xinghelee.com/report"

    /// 用户支持邮箱。Apple 1.2 要求 UGC App 在 App 内提供可达的联系方式。
    static let supportEmail = "hi@xinghelee.com"

    /// 隐私政策。Apple 5.1.1(i) 要求它同时在 App Store Connect 和 App 内可达。
    static let privacyPolicyURL = URL(string: "https://xinghelee.github.io/v2ex/privacy.html")!

    /// 使用条款的网页版。App 内有完整的原生页面，这个给需要外部链接的场合。
    static let termsURL = URL(string: "https://xinghelee.github.io/v2ex/terms.html")!

    static var endpoint: URL? {
        guard !endpointString.isEmpty else { return nil }
        return URL(string: endpointString)
    }

    /// 字段上限，必须与 `docs/report-worker/worker.js` 的白名单一致 —— 服务端
    /// 超长直接返 400，而 outbox 会无限重试同一份 payload，等于这条举报永远
    /// 送不出去。截断在客户端做，坏数据就不会上路。
    static let noteLimit = 1000
    static let excerptLimit = 500

    private struct Payload: Encodable {
        let id: String
        let kind: String
        let targetType: String
        let targetID: String
        let topicID: Int?
        let author: String
        let excerpt: String
        let reason: String
        let reasonTitle: String
        let note: String
        let createdAt: String
        let url: String?
        let appVersion: String
        let platform: String
    }

    /// 返回是否送达。失败不抛错 —— 调用方要的就是「这条能不能从 outbox 里
    /// 划掉」，重试策略在 store 那边。
    static func send(_ report: ContentReport) async -> Bool {
        guard let endpoint else { return false }

        let payload = Payload(
            id: report.id.uuidString,
            kind: report.kind.rawValue,
            targetType: report.targetType.rawValue,
            targetID: report.targetID,
            topicID: report.topicID,
            author: report.author,
            excerpt: String(report.excerpt.prefix(Self.excerptLimit)),
            reason: report.reason.rawValue,
            reasonTitle: report.reason.title,
            note: String(report.note.prefix(Self.noteLimit)),
            createdAt: ISO8601DateFormatter().string(from: report.createdAt),
            url: report.webURL?.absoluteString,
            appVersion: Self.appVersion,
            platform: "iOS"
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try? JSONEncoder().encode(payload)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// 端点没配好或长期失败时的兜底：把举报内容整理成邮件正文，用户可以
    /// 一键发给开发者。举报永远要有一条走得通的路。
    static func mailtoURL(for report: ContentReport) -> URL? {
        let subject = "V2EX 举报 · \(report.summary)"
        let body = """
        举报编号：\(report.id.uuidString)
        对象：\(report.summary)
        作者：@\(report.author)
        理由：\(report.reason.title)
        补充说明：\(report.note.isEmpty ? "（无）" : report.note)
        链接：\(report.webURL?.absoluteString ?? "（无）")
        时间：\(report.createdAt.formatted())
        App 版本：\(appVersion)

        内容摘录：
        \(report.excerpt.isEmpty ? "（无）" : report.excerpt)
        """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }
}
