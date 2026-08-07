import SwiftUI
import Translation

// MARK: - 列表

struct HackerNewsView: View {
    @AppStorage("hnTranslate") private var translateTitles = true

    @State private var stories: [HNItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var titleTranslations: [Int: String] = [:]
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationError: String?
    @State private var isTranslating = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                header
                if let translationError {
                    Text(translationError)
                        .font(Type.label(11))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, Theme.Metric.headerPadding)
                        .padding(.bottom, 2)
                }
                if let errorMessage, stories.isEmpty {
                    EmptyStateCard(
                        icon: "wifi.exclamationmark", title: "没能加载",
                        message: errorMessage, actionTitle: "重试"
                    ) { Task { await load() } }
                } else if isLoading && stories.isEmpty {
                    LoadingCard()
                } else {
                    TopicListCard(items: stories) { story in
                        NavigationLink(value: Route.hackerNews(story.id)) {
                            HNRow(story: story, translated: titleTranslations[story.id])
                        }
                        .buttonStyle(.row)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .scrollIndicators(.hidden)
        .pullToRefresh { await load() }
        .task { if stories.isEmpty { await load() } }
        // 端上翻译：无需 key、不出网。首次用某语言对时系统会提示下载模型。
        .translationTask(translationConfig) { session in
            await translate(using: session)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Hacker News")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.body)
            Spacer()
            if isTranslating {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                    Text("翻译中")
                        .font(Type.meta(12))
                        .foregroundStyle(Theme.accent)
                }
            } else {
                Button {
                    translateTitles.toggle()
                    if translateTitles { requestTranslation() } else { titleTranslations = [:] }
                } label: {
                    Label(translateTitles ? "已翻译" : "原文", systemImage: "character.bubble")
                        .font(Type.meta(12))
                        .foregroundStyle(translateTitles ? Theme.accent : Theme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Metric.headerPadding)
        .padding(.bottom, 2)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            stories = try await HNClient.shared.stories(.top, limit: 30)
            errorMessage = nil
            // 先把缓存里已有的贴上，剩下的才走翻译。
            titleTranslations = HNTranslationCache.shared.lookup(
                stories.compactMap { story in story.title.map { (story.id, $0) } }
            )
            if translateTitles { requestTranslation() }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Re-assigning the configuration is what re-runs `translationTask`; a
    /// fresh instance is required or SwiftUI treats it as unchanged.
    /// 首轮建配置，之后必须用 invalidate() 触发重跑。
    /// 新建一个"看起来不同"的实例是不行的：Configuration 按语言对判等，
    /// SwiftUI 会认为没变化而跳过 —— 这正是标题译了、评论没译的原因。
    private func requestTranslation() {
        translationError = nil
        if translationConfig == nil {
            translationConfig = HNTranslator.configuration()
        } else {
            translationConfig?.invalidate()
        }
    }

    private func translate(using session: TranslationSession) async {
        let pieces = stories.compactMap { story -> (id: Int, text: String)? in
            guard let title = story.title, titleTranslations[story.id] == nil else { return nil }
            return (story.id, title)
        }
        guard !pieces.isEmpty else { return }
        isTranslating = true
        defer { isTranslating = false }
        do {
            // 逐条回填：30 条标题不必等最后一条译完才一起出现。
            try await HNTranslator.stream(pieces, using: session) { id, text in
                titleTranslations[id] = text
            }
            translationError = nil
        } catch {
            // 静默失败最糟：按钮写着「已翻译」而满屏英文，用户只会以为坏了。
            translationError = error.localizedDescription
        }
    }
}

// MARK: - 行

private struct HNRow: View {
    let story: HNItem
    let translated: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(translated ?? story.title ?? "")
                    .font(Type.title(16))
                    .kerning(-0.2)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                // 译文在上、原文在下：扫读用中文，判断术语准不准用英文。
                if translated != nil, let original = story.title {
                    Text(original)
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 7) {
                    if let domain = story.domain {
                        NodeTag(title: domain, size: 12)
                    }
                    if let by = story.by {
                        Text(by)
                            .font(Type.meta(11))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    Text(RelativeTime.string(from: story.date))
                        .font(Type.meta(11))
                        .foregroundStyle(Theme.faint)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    if let score = story.score {
                        Label("\(score)", systemImage: "arrow.up")
                            .font(Type.number(11))
                            .foregroundStyle(Theme.amber)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ReplyCount(value: story.descendants ?? 0)
                .padding(.top, 1)
        }
        .padding(.horizontal, Theme.Metric.cardPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
