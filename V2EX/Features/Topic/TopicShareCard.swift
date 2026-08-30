import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// MARK: - Card data

/// A flat snapshot of everything the card draws. `ImageRenderer` walks the view
/// outside the app's environment and cannot wait on anything asynchronous, so
/// the avatar arrives here as an already-decoded image rather than a URL.
struct TopicShareCardData {
    let title: String
    let author: String
    let nodeTitle: String
    let timeLabel: String
    let excerpt: String
    /// True when the body was longer than the cap — the card then says so
    /// instead of ending mid-sentence with no explanation.
    let isTruncated: Bool
    /// Discussion summary generated for the share card. When present it
    /// replaces the raw excerpt — for a long thread that's the more useful
    /// thing to hand someone in chat.
    let aiSummary: String?
    let replies: Int
    let url: URL
    let avatar: UIImage?

    init(topic: V2Topic, avatar: UIImage?, aiSummary: String? = nil) {
        title = topic.title
        author = topic.authorName
        nodeTitle = topic.nodeTitle
        timeLabel = RelativeTime.string(from: topic.activityDate)
        let body = Self.excerpt(from: topic.content ?? "")
        excerpt = body.text
        isTruncated = body.truncated
        self.aiSummary = aiSummary
        replies = topic.replies
        url = topic.webURL
        self.avatar = avatar
    }

    /// The card grows to fit the body rather than clipping it at a fixed height,
    /// so ordinary posts share in full. The cap only exists because the output is
    /// an image: past roughly this length the PNG gets tall enough that chat
    /// clients thumbnail it into illegibility, which serves the reader worse than
    /// an honest "scan for the rest".
    private static func excerpt(from content: String, limit: Int = 1_000) -> (text: String, truncated: Bool) {
        var text = content
        // Fenced code blocks and images survive as markers, not as raw syntax.
        text = text.replacingOccurrences(
            of: "```[\\s\\S]*?```", with: "「代码」", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "「图片」", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression
        )
        text = text.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: [.regularExpression])
        text = text.replacingOccurrences(of: "[*_`>]", with: "", options: .regularExpression)
        // Collapse blank-line runs to a single break, and horizontal runs to one space.
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.count > limit else { return (text, false) }
        // Back off to the last sentence break so the cut lands somewhere natural.
        let head = text.prefix(limit)
        let breaks: Set<Character> = ["。", "！", "？", "\n", ".", "!", "?"]
        let cut = head.lastIndex(where: { breaks.contains($0) })
        let kept = cut.map { head[...$0] } ?? head
        return (kept.trimmingCharacters(in: .whitespacesAndNewlines) + "…", true)
    }
}

// MARK: - The card

/// The shareable card itself. Rendered off-screen at 3× by `ImageRenderer`, so
/// everything in here must draw synchronously — no `AsyncImage`, no `.task`.
struct TopicShareCard: View {
    let data: TopicShareCardData

    /// Point width of the rendered card; 3× gives a 1020px image, which is
    /// enough for any chat app to show without resampling artefacts.
    static let width: CGFloat = 340

    private let inset: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            accentStrip
            content
        }
        .frame(width: Self.width)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: Theme.Metric.hairline)
        }
    }

    private var accentStrip: some View {
        LinearGradient(
            colors: [Theme.accent, Theme.accentDeep],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 4)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            title
            author
            if let summary = data.aiSummary {
                summaryBlock(summary)
            } else if !data.excerpt.isEmpty {
                excerptText
            }
            divider
            footer
        }
        .padding(inset)
    }

    private var header: some View {
        HStack(alignment: .center) {
            if !data.nodeTitle.isEmpty {
                Text(data.nodeTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accentSoft, in: Capsule())
            }
            Spacer(minLength: 8)
            Text("V2EX")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .kerning(1.2)
                .foregroundStyle(Theme.faint)
        }
    }

    private var title: some View {
        Text(data.title)
            .font(.system(size: 21, weight: .bold))
            .kerning(-0.5)
            .lineSpacing(4)
            .foregroundStyle(Theme.ink)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }

    private var author: some View {
        HStack(spacing: 9) {
            ShareAvatar(text: data.author, image: data.avatar, size: 30)
            Text(data.author)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.body)
                .lineLimit(1)
            if !data.timeLabel.isEmpty {
                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
                Text(data.timeLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// The summary is the point of sharing a long thread: it condenses the
    /// discussion to what someone in chat actually wants. Rendered synchronously
    /// like everything else on the card.
    private func summaryBlock(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                Text("AI 摘要")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.accentSoft, in: Capsule())

            Text(TopicSummaryMarkdown.attributed(summary))
                .font(.system(size: 14))
                .lineSpacing(5)
                .foregroundStyle(Theme.body)
                .lineLimit(10)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Text("AI 生成，可能不准确")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
    }

    private var excerptText: some View {
        VStack(alignment: .leading, spacing: 8) {
            // No line limit: the card is sized by its content, so an ordinary
            // post shares whole rather than being clipped to a fixed window.
            Text(data.excerpt)
                .font(.system(size: 14))
                .lineSpacing(5)
                .foregroundStyle(Theme.body)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            if data.isTruncated {
                Text("正文较长，已截断")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.inset, in: Capsule())
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: Theme.Metric.hairline)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            // The QR stays dark-on-white in both schemes; an inverted code is
            // legal but many scanners reject it, and this is the one element
            // whose whole job is to survive being photographed off a screen.
            QRCodeTile(string: data.url.absoluteString, size: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text("扫码阅读全文")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(shortURL)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(data.replies.formatted())
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                Text("条回复")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private var shortURL: String {
        var text = data.url.absoluteString
        for prefix in ["https://", "http://", "www."] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
    }
}

// MARK: - Card pieces

/// `IdentitySquare` loads its avatar asynchronously, which renders blank under
/// `ImageRenderer`. This is the same tile drawn from an image already in hand.
private struct ShareAvatar: View {
    let text: String
    let image: UIImage?
    let size: CGFloat

    private var initials: String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        if first.unicodeScalars.first.map({ $0.value > 0x2E80 }) == true {
            return String(first)
        }
        return String(trimmed.prefix(2)).lowercased()
    }

    var body: some View {
        let radius = size * 0.29

        ZStack {
            LinearGradient(
                colors: [Theme.accent.opacity(0.92), Theme.accent],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct QRCodeTile: View {
    let string: String
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white)
            if let code = Self.generate(string) {
                Image(uiImage: code)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(3)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: Theme.Metric.hairline)
        }
    }

    private static let context = CIContext()

    private static func generate(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Upscale on the CI side: the generator emits one pixel per module, and
        // nearest-neighbour growth keeps the edges square instead of blurred.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Rendering

@MainActor
enum TopicShareCardRenderer {
    static func image(for data: TopicShareCardData, colorScheme: ColorScheme) -> UIImage? {
        let renderer = ImageRenderer(
            content: TopicShareCard(data: data)
                .environment(\.colorScheme, colorScheme)
                // The card draws its own rounded corners, so the bitmap needs a
                // transparent margin — without it the corners clip to a square.
                .padding(10)
        )
        renderer.scale = 3
        renderer.isOpaque = false
        return renderer.uiImage
    }

    /// Warms the author avatar so the card never renders with a bare initials
    /// tile when the image was one request away.
    static func avatar(for url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if let cached = RemoteImageMemoryCache.image(for: url) { return cached }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = UIImage(data: data) else { return nil }
        RemoteImageMemoryCache.insert(image, for: url)
        return image
    }
}

// MARK: - 分享链接 + AI 摘要

/// 分享链接，可选附带一段 AI 生成的讨论摘要。摘要由用户主动生成，
/// 与话题页的 AI 卡片共用缓存 —— 生成过一次就不会重复调用模型。
struct TopicShareLinkSheet: View {
    let topic: V2Topic
    let summarySource: String
    let summarySignature: String
    let offersSummary: Bool

    @EnvironmentObject private var aiConfiguration: AIConfigurationStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var summaryModel: TopicSummaryViewModel

    init(
        topic: V2Topic,
        summarySource: String = "",
        summarySignature: String = "",
        offersSummary: Bool = false
    ) {
        self.topic = topic
        self.summarySource = summarySource
        self.summarySignature = summarySignature
        self.offersSummary = offersSummary
        _summaryModel = StateObject(wrappedValue: TopicSummaryViewModel(topicID: topic.id))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        linkRow
                        summarySection
                    }
                    .padding(.top, 8)
                }
                .scrollIndicators(.hidden)

                shareButton
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, Theme.Metric.screenPadding)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("分享链接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .task(id: summarySignature) { summaryModel.load(signature: summarySignature) }
    }

    private var linkRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(Theme.accent)
            Text(topic.webURL.absoluteString)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Theme.body)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var summarySection: some View {
        if let summary = summaryModel.summary {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Theme.accent)
                    Text("AI 摘要")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Button("重新生成") { generate() }
                        .font(.system(size: 12, weight: .medium))
                        .disabled(summaryModel.isGenerating)
                }

                Text(TopicSummaryMarkdown.attributed(summary))
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Text("AI 生成，可能不准确")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else if summaryModel.isGenerating {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(summaryModel.isOnDeviceModelAvailable
                    ? "正在设备上阅读这段讨论…"
                    : "正在生成摘要…")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            Button(action: generate) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("生成 AI 摘要")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(availabilityHint)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canGenerate)
        }
    }

    private var availabilityHint: String {
        if summaryModel.isOnDeviceModelAvailable {
            return "在设备上完成，帖子内容不会上传"
        } else if aiConfiguration.isConfigured {
            return "通过 \(aiConfiguration.providerName ?? "AI API") 生成"
        } else {
            return "需要支持 Apple Intelligence 的设备或自定义 AI API"
        }
    }

    private var canGenerate: Bool {
        summaryModel.isOnDeviceModelAvailable || aiConfiguration.isConfigured
    }

    private func generate() {
        Task {
            await summaryModel.generate(
                source: summarySource,
                signature: summarySignature,
                cloudConfiguration: aiConfiguration.configuration
            )
        }
    }

    private var shareText: String {
        let link = topic.webURL.absoluteString
        guard let summary = summaryModel.summary, !summary.isEmpty else { return link }
        return """
        AI 摘要 · \(topic.title)

        \(summary)

        原文：\(link)
        """
    }

    private var shareButton: some View {
        ShareLink(item: shareText) {
            Label(
                summaryModel.summary == nil ? "分享链接" : "分享链接与摘要",
                systemImage: "square.and.arrow.up"
            )
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Theme.accent, in: Capsule())
        }
    }
}

// MARK: - Sheet

/// Preview + share. Rendering happens once on appear; the sheet shows the live
/// SwiftUI card until the bitmap is ready so there is no empty first frame.
struct TopicShareCardSheet: View {
    let topic: V2Topic
    /// Discussion text the summary model reads; empty when the thread is too
    /// short to warrant one.
    let summarySource: String
    /// Cache key for the summary; shared with the in-thread AI card so an
    /// already-generated summary shows up here without another model run.
    let summarySignature: String
    /// Whether this thread qualifies for a summary at all.
    let offersSummary: Bool

    @EnvironmentObject private var aiConfiguration: AIConfigurationStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var data: TopicShareCardData?
    @State private var rendered: UIImage?
    @StateObject private var summaryModel: TopicSummaryViewModel

    init(
        topic: V2Topic,
        summarySource: String = "",
        summarySignature: String = "",
        offersSummary: Bool = false
    ) {
        self.topic = topic
        self.summarySource = summarySource
        self.summarySignature = summarySignature
        self.offersSummary = offersSummary
        _summaryModel = StateObject(wrappedValue: TopicSummaryViewModel(topicID: topic.id))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()

                VStack(spacing: 16) {
                    // A long post makes a tall card; scrolling keeps it legible
                    // instead of shrinking the whole thing to fit the screen.
                    ScrollView {
                        preview.padding(.vertical, 12)
                    }
                    .scrollIndicators(.hidden)

                    if offersSummary && summaryModel.isGenerating {
                        Label("正在生成 AI 摘要…", systemImage: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    }

                    shareButton
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .navigationTitle("分享卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .task {
            let avatar = await TopicShareCardRenderer.avatar(for: topic.member?.avatarURL)
            let card = TopicShareCardData(topic: topic, avatar: avatar)
            data = card
            rendered = TopicShareCardRenderer.image(for: card, colorScheme: colorScheme)

            // Auto-generate the summary when the thread qualifies. Cache is
            // shared with the in-thread AI card, so an existing summary lands
            // instantly; otherwise the model runs while the user looks at the
            // card, and the card swaps in the summary when it's ready.
            guard offersSummary, !summarySource.isEmpty else { return }
            summaryModel.load(signature: summarySignature)
            if summaryModel.summary == nil {
                await summaryModel.generate(
                    source: summarySource,
                    signature: summarySignature,
                    cloudConfiguration: aiConfiguration.configuration
                )
            }
            guard let summary = summaryModel.summary, !summary.isEmpty else { return }
            let updated = TopicShareCardData(topic: topic, avatar: avatar, aiSummary: summary)
            data = updated
            rendered = TopicShareCardRenderer.image(for: updated, colorScheme: colorScheme)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let rendered {
            Image(uiImage: rendered)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: TopicShareCard.width)
        } else if let data {
            TopicShareCard(data: data)
        } else {
            ProgressView().tint(Theme.muted)
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if let rendered {
            let image = Image(uiImage: rendered)
            ShareLink(
                item: image,
                preview: SharePreview(topic.title, image: image)
            ) {
                Label("分享卡片", systemImage: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.accent, in: Capsule())
            }
        }
    }
}
