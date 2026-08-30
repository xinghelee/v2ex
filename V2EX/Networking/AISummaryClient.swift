import Foundation

actor AISummaryClient {
    static let shared = AISummaryClient()

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }

        struct APIError: Decodable { let message: String? }
        let choices: [Choice]?
        let error: APIError?
    }

    func summarize(source: String, configuration: AIServerConfiguration) async throws -> String {
        let endpoint = configuration.baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: configuration.model,
                messages: [
                    .init(
                        role: "system",
                        content: """
                        你是论坛阅读助手。只根据用户提供的帖子和回复总结，不补充外部事实，不猜测作者意图。
                        使用简体中文，保持中立、准确、紧凑。保留关键数字、结论与明显分歧。
                        输出纯文本，控制在 350 字以内，结构为：核心内容、主要观点、讨论分歧。
                        如果没有明显分歧，明确写“暂无明显分歧”。
                        """
                    ),
                    .init(role: "user", content: "请总结下面这段 V2EX 讨论：\n\n\(source)"),
                ],
                temperature: 0.2,
                maxTokens: 700
            )
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AISummaryError.invalidResponse
        }
        let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            throw AISummaryError.server(
                decoded?.error?.message ?? "AI 服务返回 \(http.statusCode)"
            )
        }
        guard let text = decoded?.choices?.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw AISummaryError.emptyResponse
        }
        return text
    }
}

enum AISummaryError: LocalizedError {
    case invalidResponse
    case emptyResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "AI 服务响应无效"
        case .emptyResponse: return "AI 服务没有返回摘要"
        case .server(let message): return message
        }
    }
}
