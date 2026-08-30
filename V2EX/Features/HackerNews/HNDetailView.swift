import SwiftUI
import Translation

struct HNDetailView: View {
    let itemID: Int

    @AppStorage("hnTranslate") private var translateBodies = true
    @Environment(\.openURL) private var openURL

    @State private var story: HNItem?
    @State private var comments: [HNComment] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Keyed by item id; the story's own title/text share the story's id.
    @State private var translations: [Int: String] = [:]
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationError: String?
    @State private var isTranslating = false
    @State private var isLoadingComments = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let translationError {
                    Text(translationError)
                        .font(Type.label(11))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, Theme.Metric.headerPadding)
                }
                if let story {
                    storyCard(story)
                    if isLoadingComments || !comments.isEmpty { commentsHeader }
                    if isLoadingComments && comments.isEmpty {
                        // 评论是逐条取的（HN 无批量端点），主帖先出来、评论
                        // 随后到；这里不说话的话会让人以为是没有评论。
                        statusCard("正在加载评论…")
                    } else {
                        commentList
                    }
                } else if isLoading {
                    LoadingCard().padding(.top, 8)
                } else if let errorMessage {
                    EmptyStateCard(
                        icon: "exclamationmark.triangle", title: "打不开这条",
                        message: errorMessage, actionTitle: "在 Hacker News 打开"
                    ) {
                        openURL(URL(string: "https://news.ycombinator.com/item?id=\(itemID)")!)
                    }
                    .padding(.top, 8)
                }
            }
            .readableColumn()
            .padding(.top, 6)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("Hacker News")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        translateBodies.toggle()
                        if translateBodies { requestTranslation() } else { translations = [:] }
                    } label: {
                        Label(translateBodies ? "显示原文" : "翻译为中文", systemImage: "character.bubble")
                    }
                    if let url = story?.url.flatMap(URL.init(string:)) {
                        Button { openURL(url) } label: { Label("打开原文链接", systemImage: "safari") }
                        ShareLink(item: url) { Label("分享链接", systemImage: "link") }
                    }
                    Button {
                        openURL(URL(string: "https://news.ycombinator.com/item?id=\(itemID)")!)
                    } label: {
                        Label("在 Hacker News 打开", systemImage: "bubble.left.and.text.bubble.right")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(Theme.body)
                }
            }
        }
        .task { await load() }
        .translationTask(translationConfig) { session in
            await translate(using: session)
        }
    }

    // MARK: 主帖

    private func storyCard(_ story: HNItem) -> some View {
        CardSection(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text(translations[story.id] ?? story.title ?? "")
                    .font(.system(size: 20, weight: .bold))
                    .kerning(-0.5)
                    .lineSpacing(4)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if translations[story.id] != nil, let original = story.title {
                    Text(original)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    if let by = story.by {
                        IdentitySquare(text: by, size: 26)
                        Text(by)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    Text(RelativeTime.string(from: story.date))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 4)
                    if let score = story.score {
                        Label("\(score)", systemImage: "arrow.up")
                            .font(Type.number(12))
                            .foregroundStyle(Theme.amber)
                    }
                }

                if let url = story.url.flatMap(URL.init(string:)) {
                    Button { openURL(url) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "safari").font(.system(size: 12))
                            Text(story.domain ?? url.absoluteString)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Chevron()
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if let text = story.text, !text.isEmpty {
                    Rectangle().fill(Theme.separator).frame(height: Theme.Metric.hairline)
                    ContentBlocksView(blocks: HTMLText.blocks(from: text))
                }
            }
        }
    }

    private func statusCard(_ text: String) -> some View {
        CardSection(padding: 18) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
        }
    }

    private var commentsHeader: some View {
        HStack(spacing: 8) {
            Text("\(story?.descendants ?? comments.count) 条评论")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if isTranslating {
                ProgressView().controlSize(.mini).tint(Theme.accent)
                Text("翻译中")
                    .font(Type.meta(12))
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
            Text("只显示前两层")
                .font(Type.label(11))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, Theme.Metric.headerPadding)
        .padding(.top, 6)
    }

    private var commentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(comments) { comment in
                commentRow(comment)
                if comment.id != comments.last?.id {
                    RowSeparator(leadingInset: Theme.Metric.cardPadding)
                }
            }
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous))
        .padding(.horizontal, Theme.Metric.screenPadding)
    }

    private func commentRow(_ comment: HNComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(comment.item.by ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(RelativeTime.string(from: comment.item.date))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }

            if comment.item.text != nil {
                Text(commentBody(comment))
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, Theme.Metric.cardPadding)
        .padding(.vertical, 12)
        // 二层回复靠一条竖线和缩进区分，不再往下嵌套。
        .padding(.leading, comment.depth > 0 ? 22 : 0)
        .overlay(alignment: .leading) {
            if comment.depth > 0 {
                Rectangle()
                    .fill(Theme.separator)
                    .frame(width: 2)
                    .padding(.leading, Theme.Metric.cardPadding)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 未翻译时用 HTML 解析保住原文里的 <a>；翻译后标记已不存在，
    /// 只能对译文里的裸 URL 做探测。
    private func commentBody(_ comment: HNComment) -> AttributedString {
        if let translated = translations[comment.id] {
            return HNLinkify.attributed(translated)
        }
        guard let text = comment.item.text else { return AttributedString() }
        return HTMLText.inline(text)
    }

    // MARK: 数据

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            HNClient.log("detail: 取 item \(itemID)")
            let fetched = try await HNClient.shared.item(id: itemID)
            HNClient.log("detail: item 到手 kids=\(fetched.kids?.count ?? 0)")
            story = fetched
            // 标题先译一轮，不必陪着评论一起等。
            if translateBodies { requestTranslation() }
            isLoadingComments = true
            comments = await HNClient.shared.comments(of: fetched)
            isLoadingComments = false
            HNClient.log("detail: 评论 \(comments.count) 条，进入翻译")
            if translateBodies { requestTranslation() }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 首轮建配置，之后必须用 invalidate() 触发重跑。
    /// 新建一个"看起来不同"的实例是不行的：Configuration 按语言对判等，
    /// SwiftUI 会认为没变化而跳过 —— 这正是标题译了、评论没译的原因。
    private func requestTranslation() {
        if translationConfig == nil {
            translationConfig = HNTranslator.configuration()
        } else {
            translationConfig?.invalidate()
        }
    }

    private func translate(using session: TranslationSession) async {
        var pieces: [(id: Int, text: String)] = []
        if let story, let title = story.title, translations[story.id] == nil {
            pieces.append((story.id, title))
        }
        for comment in comments where translations[comment.id] == nil {
            guard let text = comment.item.text else { continue }
            let plain = HTMLText.plain(text)
            guard !plain.isEmpty else { continue }
            pieces.append((comment.id, plain))
        }
        guard !pieces.isEmpty else { return }
        isTranslating = true
        defer { isTranslating = false }
        do {
            // 标题已经排在 pieces 最前，流式返回时它最先到位。
            try await HNTranslator.stream(pieces, using: session) { id, text in
                translations[id] = text
            }
            translationError = nil
        } catch {
            // 详情页原先也把错误吞了，于是「全是英文」既没有解释也没有线索。
            translationError = error.localizedDescription
        }
    }
}
