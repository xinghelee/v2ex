import Foundation
import FoundationModels
import SwiftUI

/// A user-triggered summary for long V2EX discussions.
///
/// Apple Intelligence runs on-device. When unavailable, users may opt into an
/// external provider. Successful summaries are cached by a stable discussion
/// signature so reopening a thread does not spend another model run or API call.
@MainActor
final class TopicSummaryViewModel: ObservableObject {
    @Published private(set) var summary: String?
    @Published private(set) var isGenerating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var summaryProvider: String?

    private struct CachedSummary: Codable {
        let signature: String
        let text: String
        let generatedAt: Date
        let provider: String?
    }

    private let topicID: Int
    private var loadedSignature: String?

    init(topicID: Int) {
        self.topicID = topicID
    }

    var isOnDeviceModelAvailable: Bool {
        guard #available(iOS 27.0, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }

    var availabilityMessage: String? {
        guard #available(iOS 27.0, *) else {
            return "设备端摘要需要 iOS 27，也可以配置自定义 AI API"
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "需要支持 Apple Intelligence 的设备"
            case .appleIntelligenceNotEnabled:
                return "请先在系统设置中开启 Apple Intelligence"
            case .modelNotReady:
                return "设备端模型仍在准备，请稍后再试"
            @unknown default:
                return "设备端模型暂时不可用"
            }
        }
    }

    func load(signature: String) {
        guard loadedSignature != signature else { return }
        loadedSignature = signature
        errorMessage = nil

        guard let cached = DiskStore.load(CachedSummary.self, from: cacheURL),
              cached.signature == signature else {
            summary = nil
            summaryProvider = nil
            return
        }
        summary = cached.text
        summaryProvider = cached.provider ?? "设备端"
    }

    func generate(
        source: String,
        signature: String,
        cloudConfiguration: AIServerConfiguration?
    ) async {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let result: (text: String, provider: String)
            if #available(iOS 27.0, *), isOnDeviceModelAvailable {
                result = (try await generateOnDevice(source: source), "设备端")
            } else if let cloudConfiguration {
                result = (
                    try await AISummaryClient.shared.summarize(
                        source: source,
                        configuration: cloudConfiguration
                    ),
                    cloudConfiguration.providerName
                )
            } else {
                errorMessage = availabilityMessage ?? "请先配置 AI API"
                return
            }

            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                errorMessage = "没有生成有效摘要，请稍后重试"
                return
            }
            summary = text
            summaryProvider = result.provider
            loadedSignature = signature
            DiskStore.save(
                CachedSummary(
                    signature: signature,
                    text: text,
                    generatedAt: Date(),
                    provider: result.provider
                ),
                to: cacheURL
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @available(iOS 27.0, *)
    private func generateOnDevice(source: String) async throws -> String {
        let model = SystemLanguageModel.default
        let instructions = Instructions(
            """
            你是论坛阅读助手。只根据用户提供的帖子和回复总结，不补充外部事实，不猜测作者意图。
            使用简体中文，保持中立、准确、紧凑。保留关键数字、结论与明显分歧。
            输出纯文本，控制在 350 字以内，结构为：核心内容、主要观点、讨论分歧。
            如果没有明显分歧，明确写“暂无明显分歧”。
            """
        )
        let session = LanguageModelSession(model: model, dynamicInstructions: instructions)

        let response = try await session.respond(
            to: "请总结下面这段 V2EX 讨论：\n\n\(source)",
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 500)
        )
        return response.content
    }

    private var cacheURL: URL {
        DiskStore.cacheDirectory(named: "TopicSummaries")
            .appendingPathComponent("\(topicID).json")
    }
}

struct TopicAISummaryCard: View {
    let topicID: Int
    let source: String
    let signature: String

    @EnvironmentObject private var aiConfiguration: AIConfigurationStore
    @StateObject private var model: TopicSummaryViewModel

    init(topicID: Int, source: String, signature: String) {
        self.topicID = topicID
        self.source = source
        self.signature = signature
        _model = StateObject(wrappedValue: TopicSummaryViewModel(topicID: topicID))
    }

    var body: some View {
        CardSection(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Theme.accent)
                    Text("讨论摘要")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(providerLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.accentSoft, in: Capsule())
                }

                if let summary = model.summary {
                    Text(summary)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.body)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Label("AI 生成，可能不准确", systemImage: "exclamationmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Button("重新生成") { generate() }
                            .font(.system(size: 12, weight: .medium))
                            .disabled(model.isGenerating)
                    }
                } else if model.isGenerating {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.isOnDeviceModelAvailable
                            ? "正在设备上阅读这段讨论…"
                            : "正在通过 \(aiConfiguration.providerName ?? "AI API") 生成…")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                } else if model.isOnDeviceModelAvailable {
                    Text("用设备端模型提炼核心内容、主要观点与讨论分歧。帖子内容不会上传。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(3)

                    generateButton(title: "生成摘要")
                } else if aiConfiguration.isConfigured {
                    Text("Apple Intelligence 在当前设备或地区不可用。生成时会把本帖正文和部分回复发送给 \(aiConfiguration.providerName ?? "你配置的 AI 服务")。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(3)

                    generateButton(title: "通过 \(aiConfiguration.providerName ?? "AI API") 生成")
                } else {
                    if let unavailable = model.availabilityMessage {
                        Label(unavailable, systemImage: "apple.intelligence")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    }
                    NavigationLink(value: Route.aiConfiguration) {
                        Label("配置自定义 AI API", systemImage: "key")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
        }
        .task(id: signature) { model.load(signature: signature) }
    }

    private var providerLabel: String {
        model.summaryProvider
            ?? (model.isOnDeviceModelAvailable
                ? "设备端"
                : aiConfiguration.providerName ?? "未配置")
    }

    private func generate() {
        let cloud = aiConfiguration.configuration
        Task {
            await model.generate(
                source: source,
                signature: signature,
                cloudConfiguration: cloud
            )
        }
    }

    private func generateButton(title: String) -> some View {
        Button(action: generate) {
            Label(title, systemImage: "sparkles")
                .font(.system(size: 14, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
    }
}
