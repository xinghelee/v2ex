import SwiftUI

struct TopicDetailView: View {
    let topicID: Int

    @StateObject private var model = TopicDetailViewModel()
    @EnvironmentObject private var token: TokenStore
    @EnvironmentObject private var topicCache: TopicDetailCacheStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var readState: ReadStateStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var session: V2EXSessionStore
    @EnvironmentObject private var replyDrafts: ReplyDraftStore
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var moderation: ModerationStore
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var replyError: String?
    @State private var showReplyError = false
    @State private var isSending = false
    @State private var isSyncingFavorite = false
    @State private var isComposerHidden = false
    @State private var showShareCard = false
    @State private var showShareLink = false
    @State private var reportTarget: ModerationTarget?
    @State private var highlightedReplyID: Int?
    @State private var highlightClearTask: Task<Void, Never>?
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            // iPad 宽屏（横屏 / 大窗）双栏阅读：正文居左、楼层回复居右，
            // 各自独立滚动；窄屏（iPhone / iPad 竖屏窄窗）保持单栏同轴。
            GeometryReader { geo in
                let usesTwoPane = geo.size.width > twoPaneWidthThreshold
                ZStack(alignment: .bottom) {
                    if usesTwoPane {
                        twoPaneContent
                    } else {
                        singlePaneContent
                    }

                    // In two-pane reading the composer belongs to the reply
                    // pane, not the physical centre of the whole display.
                    replyComposer
                        .frame(maxWidth: usesTwoPane ? min(geo.size.width / 2, 720) : 720)
                        .frame(maxWidth: .infinity, alignment: usesTwoPane ? .trailing : .center)
                        .offset(y: isComposerHidden ? 110 : 0)
                        .opacity(isComposerHidden ? 0 : 1)
                        .allowsHitTesting(!isComposerHidden)
                        .accessibilityHidden(isComposerHidden)
                        .animation(.snappy(duration: 0.24), value: isComposerHidden)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // The floating reply composer owns the bottom of this screen.
        .toolbar(.hidden, for: .tabBar)
        .toolbar { toolbarContent }
        .task {
            readState.markRead(topicID)
            await model.load(
                id: topicID,
                token: token.token,
                cookie: session.cookie,
                cache: topicCache,
                offline: offline
            )
            // 载入之后才记，历史列表要靠这份话题体自己把行画出来。
            if let topic = model.topic { history.record(topic) }
        }
        .sheet(isPresented: $showShareCard) {
            if let topic = model.topic {
                TopicShareCardSheet(
                    topic: topic,
                    summarySource: shareSummaryContext.source,
                    summarySignature: shareSummaryContext.signature,
                    offersSummary: shareSummaryContext.offers
                )
            }
        }
        .sheet(isPresented: $showShareLink) {
            if let topic = model.topic {
                TopicShareLinkSheet(
                    topic: topic,
                    summarySource: shareSummaryContext.source,
                    summarySignature: shareSummaryContext.signature,
                    offersSummary: shareSummaryContext.offers
                )
            }
        }
        .sheet(item: $reportTarget) { ReportSheet(target: $0) }
        .onDisappear { replyDrafts.save() }
    }

    /// 分享相关面板共用的摘要输入：正文 + 可见回复组成的源文本、缓存签名
    /// 与「是否值得生成摘要」判定。两个面板共用，避免重复计算。
    private var shareSummaryContext: (source: String, signature: String, offers: Bool) {
        let summaryReplies = moderation.visible(model.replies)
        let source = model.summarySource(from: summaryReplies)
        return (
            source,
            model.summarySignature(for: source, visibleReplyCount: summaryReplies.count),
            model.shouldOfferSummary(visibleReplyCount: summaryReplies.count)
        )
    }

    /// 双栏阈值；可用 `-twoPaneWidth 800` 启动参数覆盖，便于在竖屏或
    /// 分屏窄窗下调试双栏布局（与 -openTopic 同一套调试手段）。
    private var twoPaneWidthThreshold: CGFloat {
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "-twoPaneWidth"), flag + 1 < args.count,
           let value = Double(args[flag + 1]) {
            return CGFloat(value)
        }
        return 1050
    }

    // MARK: 单栏 / 双栏

    /// 窄屏：正文与回复共用一根滚动轴。
    private var singlePaneContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if moderation.hiddenTopicIDs.contains(topicID) {
                        hiddenTopicCard
                    } else if let topic = model.topic {
                        topicCard(topic)
                        let summaryReplies = moderation.visible(model.replies)
                        if model.shouldOfferSummary(visibleReplyCount: summaryReplies.count) {
                            let source = model.summarySource(from: summaryReplies)
                            TopicAISummaryCard(
                                topicID: topic.id,
                                source: source,
                                signature: model.summarySignature(
                                    for: source,
                                    visibleReplyCount: summaryReplies.count
                                )
                            )
                        }
                        replyHeader(topic)
                        discussionTrack(proxy)
                        replyList(proxy)
                    } else if model.isLoading {
                        LoadingCard().padding(.top, 8)
                    } else if let message = model.errorMessage {
                        EmptyStateCard(icon: "exclamationmark.triangle", title: "打不开这个话题",
                                       message: message, actionTitle: "在 V2EX 打开") {
                            openURL(URL(string: "https://www.v2ex.com/t/\(topicID)")!)
                        }
                        .padding(.top, 8)
                    }
                }
                .readableColumn()
                .padding(.top, 6)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(composerVisibilityGesture)
            .pullToRefresh { await reload() }
            .onChange(of: model.replies.count) { _, _ in restoreReadingPosition(proxy) }
        }
    }

    /// 宽屏：正文左、回复右，各自独立滚动；中间一条发丝分隔线。回复区
    /// 保持可读栏宽，楼层、举报、只看楼主等交互都在右栏原样工作。
    private var twoPaneContent: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if moderation.hiddenTopicIDs.contains(topicID) {
                        hiddenTopicCard
                    } else if let topic = model.topic {
                        topicCard(topic)
                        let summaryReplies = moderation.visible(model.replies)
                        if model.shouldOfferSummary(visibleReplyCount: summaryReplies.count) {
                            let source = model.summarySource(from: summaryReplies)
                            TopicAISummaryCard(
                                topicID: topic.id,
                                source: source,
                                signature: model.summarySignature(
                                    for: source,
                                    visibleReplyCount: summaryReplies.count
                                )
                            )
                        }
                    } else if model.isLoading {
                        LoadingCard().padding(.top, 8)
                    } else if let message = model.errorMessage {
                        EmptyStateCard(icon: "exclamationmark.triangle", title: "打不开这个话题",
                                       message: message, actionTitle: "在 V2EX 打开") {
                            openURL(URL(string: "https://www.v2ex.com/t/\(topicID)")!)
                        }
                        .padding(.top, 8)
                    }
                }
                .readableColumn(maxWidth: 640)
                .padding(.top, 6)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(composerVisibilityGesture)
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Theme.separator)
                .frame(width: Theme.Metric.hairline)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let topic = model.topic {
                            replyHeader(topic)
                            discussionTrack(proxy)
                            replyList(proxy)
                        }
                    }
                    .readableColumn(maxWidth: 640)
                    .padding(.top, 6)
                    .padding(.bottom, 110)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(composerVisibilityGesture)
                .pullToRefresh { await reload() }
                .onChange(of: model.replies.count) { _, _ in restoreReadingPosition(proxy) }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func reload() async {
        await model.load(
            id: topicID,
            token: token.token,
            cookie: session.cookie,
            cache: topicCache,
            offline: offline
        )
    }

    private func restoreReadingPosition(_ proxy: ScrollViewProxy) {
        guard settings.rememberReadingPosition, model.replies.count > 0,
              let floor = readState.position(for: topicID), floor > 1 else { return }
        // Restore where the reader left off.
        if let target = model.replies.first(where: { $0.floor == floor }) {
            proxy.scrollTo(target.id, anchor: .top)
        }
    }

    // MARK: @提及 补全

    /// The `@name` fragment being typed at the tail of the draft, if any.
    ///
    /// Only the tail is examined. SwiftUI's `TextField` exposes no caret
    /// position, and mentioning someone mid-sentence after the fact is rare
    /// enough that it isn't worth dropping down to a `UITextView` for.
    private var activeMentionQuery: String? {
        let text = replyDrafts.text(for: topicID)
        guard let at = text.lastIndex(of: "@") else { return nil }

        // Anything before the "@" must be a word break, or an email address
        // typed into the box would open the list.
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }

        let fragment = text[text.index(after: at)...]
        guard !fragment.contains(where: \.isWhitespace) else { return nil }
        return String(fragment)
    }

    /// Everyone in this thread, nearest floor first — the person you are
    /// answering is almost always one of the last few to have spoken.
    private var mentionCandidates: [String] {
        guard let query = activeMentionQuery else { return [] }

        var seen: Set<String> = []
        var ordered: [String] = []
        for item in model.replies.reversed() where !item.reply.authorName.isEmpty {
            if seen.insert(item.reply.authorName).inserted {
                ordered.append(item.reply.authorName)
            }
        }
        if let author = model.topic?.authorName, !author.isEmpty, seen.insert(author).inserted {
            ordered.append(author)
        }
        if !session.username.isEmpty { ordered.removeAll { $0 == session.username } }

        let needle = query.lowercased()
        let matches = needle.isEmpty ? ordered : ordered.filter { $0.lowercased().hasPrefix(needle) }
        return Array(matches.prefix(8))
    }

    private func mentionAvatar(for username: String) -> URL? {
        if let member = model.replies.first(where: { $0.reply.authorName == username })?.reply.member {
            return member.avatarURL
        }
        return model.topic?.authorName == username ? model.topic?.member?.avatarURL : nil
    }

    private func insertMention(_ username: String) {
        var text = replyDrafts.text(for: topicID)
        guard let at = text.lastIndex(of: "@") else { return }
        text.replaceSubrange(at..., with: "@\(username) ")
        replyDrafts.update(text, for: topicID)
    }

    @ViewBuilder
    private var mentionSuggestions: some View {
        let candidates = mentionCandidates
        if composerFocused, !candidates.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(candidates, id: \.self) { name in
                        Button {
                            insertMention(name)
                        } label: {
                            HStack(spacing: 6) {
                                IdentitySquare(text: name, size: 18, imageURL: mentionAvatar(for: name))
                                Text(name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                            }
                            .padding(.leading, 6)
                            .padding(.trailing, 11)
                            .padding(.vertical, 6)
                            .glassPill()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
            .frame(height: 42)
            .transition(.opacity)
        }
    }

    private var replyDraftBinding: Binding<String> {
        Binding(
            get: { replyDrafts.text(for: topicID) },
            set: { replyDrafts.update($0, for: topicID) }
        )
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let node = model.topic?.node {
                NavigationLink(value: Route.node(node.name)) {
                    Text(node.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                Button {
                    guard let topic = model.topic, !isSyncingFavorite else { return }
                    if session.isLoggedIn {
                        // 已登录：星标转 loading，V2EX 同步完成后再更新状态。
                        isSyncingFavorite = true
                        Task {
                            do {
                                let newState = try await V2EXClient.shared.toggleFavorite(
                                    topicID: topic.id, cookie: session.cookie
                                )
                                if newState != favorites.contains(topic.id) {
                                    favorites.toggle(topic)  // 服务器最终状态为准
                                }
                            } catch {
                                // 同步失败：保持原状态。
                            }
                            isSyncingFavorite = false
                        }
                    } else {
                        favorites.toggle(topic)
                    }
                } label: {
                    Group {
                        if isSyncingFavorite {
                            ProgressView().controlSize(.small).tint(Theme.body)
                        } else {
                            Image(systemName: favorites.contains(topicID) ? "star.fill" : "star")
                                .foregroundStyle(favorites.contains(topicID) ? Theme.amber : Theme.body)
                        }
                    }
                }
                .disabled(isSyncingFavorite)
                Menu {
                    Button {
                        toggleOffline()
                    } label: {
                        Label(
                            offline.isOffline(topicID) ? "移除离线内容" : "保存以离线阅读",
                            systemImage: offline.isOffline(topicID) ? "trash" : "arrow.down.circle"
                        )
                    }
                    if let topic = model.topic {
                        Button {
                            showShareLink = true
                        } label: {
                            Label("分享链接", systemImage: "link")
                        }
                        Button {
                            showShareCard = true
                        } label: {
                            Label("分享为卡片", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            openURL(topic.webURL)
                        } label: {
                            Label("在 V2EX 打开", systemImage: "safari")
                        }
                        Divider()
                        ModerationMenuItems(
                            target: .topic(
                                id: topic.id,
                                author: topic.authorName,
                                excerpt: topic.title + "\n" + (topic.content ?? "")
                            ),
                            onReport: { reportTarget = $0 }
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(Theme.body)
                }
                .accessibilityLabel("更多操作")
            }
        }
    }

    private func toggleOffline() {
        if offline.isOffline(topicID) {
            offline.remove(id: topicID)
        } else if let (topic, replies) = model.offlinePayload {
            offline.save(topic: topic, replies: replies)
        }
    }

    // MARK: Topic card

    private func topicCard(_ topic: V2Topic) -> some View {
        CardSection(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text(topic.title)
                    .font(.system(size: 20, weight: .bold))
                    .kerning(-0.5)
                    .lineSpacing(4)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    NavigationLink(value: Route.member(topic.authorName)) {
                        HStack(spacing: 10) {
                            IdentitySquare(text: topic.authorName, size: 34, imageURL: topic.member?.avatarURL)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(topic.authorName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    if model.proMembers.contains(topic.authorName) { ProBadge() }
                                }
                                Text(RelativeTime.string(from: topic.activityDate))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 4)
                    if let views = model.topicViews {
                        Label(views.formatted(), systemImage: "eye")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.muted)
                            .accessibilityLabel("\(views.formatted()) 次阅读")
                    }
                    if offline.isOffline(topicID) { OfflineBadge() }
                }

                Rectangle().fill(Theme.separator).frame(height: Theme.Metric.hairline)

                let blocks = model.contentBlocks
                if blocks.isEmpty {
                    Text("（本帖没有正文）")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                } else {
                    ContentBlocksView(blocks: blocks)
                }

                // 楼主 APPEND：网页抓取，API 不返回。
                if !model.appends.isEmpty {
                    ForEach(model.appends, id: \.self) { append in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(
                                "楼主 \(append.timeLabel.isEmpty ? "补充" : append.timeLabel) 补充",
                                systemImage: "plus.bubble"
                            )
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)

                            let appendBlocks = model.contentBlocks(for: append)
                            if appendBlocks.isEmpty {
                                Text(append.content)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.ink)
                            } else {
                                ContentBlocksView(blocks: appendBlocks)
                            }
                        }
                        .padding(.top, 10)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Theme.accent.opacity(0.35))
                                .frame(width: 2.5)
                        }
                    }
                }
            }
        }
    }

    // MARK: Replies

    private func replyHeader(_ topic: V2Topic) -> some View {
        HStack {
            Text("\(topic.replies) 条回复")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Spacer()
            HStack(spacing: 6) {
                ForEach(TopicDetailViewModel.ReplyFilter.allCases) { filter in
                    Button {
                        withAnimation(.snappy) { model.filter = filter }
                    } label: {
                        Text(filter.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(model.filter == filter ? Theme.accent : Theme.muted)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(
                                model.filter == filter
                                    ? AnyShapeStyle(Theme.accentSoft)
                                    : AnyShapeStyle(Theme.inset)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Theme.Metric.screenPadding + 6)
        .padding(.top, 2)
    }

    // MARK: Discussion track

    @ViewBuilder
    private func discussionTrack(_ proxy: ScrollViewProxy) -> some View {
        let visible = moderation.visible(model.visibleReplies)
        if visible.count > 1 {
            DiscussionTrack(
                items: sampledTrackItems(from: visible),
                totalCount: visible.count
            ) { item in
                if reduceMotion {
                    proxy.scrollTo(item.id, anchor: .top)
                } else {
                    withAnimation(.snappy(duration: 0.28)) {
                        proxy.scrollTo(item.id, anchor: .top)
                    }
                }
            }
        }
    }

    /// Keep the map readable even on a thread with hundreds of floors. First
    /// and last are always present; the points between them are evenly sampled.
    private func sampledTrackItems(from items: [ThreadedReply]) -> [ThreadedReply] {
        let maximum = 8
        guard items.count > maximum else { return items }
        return (0..<maximum).map { position in
            let ratio = Double(position) / Double(maximum - 1)
            let index = Int((ratio * Double(items.count - 1)).rounded())
            return items[index]
        }
    }

    /// 举报过的话题不再画正文和回复 —— 举报的语义是「我不想再看到它」，
    /// 从链接、历史或收藏再点进来也一样。
    private var hiddenTopicCard: some View {
        EmptyStateCard(
            icon: "flag",
            title: "你已举报这个话题",
            message: "它已经从你的 App 里移除。开发者会在 24 小时内核实并向 V2EX 站方上报。",
            actionTitle: "恢复显示"
        ) {
            moderation.unhideTopic(topicID)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func replyList(_ proxy: ScrollViewProxy) -> some View {
        let items = moderation.visible(model.visibleReplies)
        if items.isEmpty {
            if model.isLoading {
                LoadingCard()
            } else if let message = model.repliesErrorMessage {
                EmptyStateCard(
                    icon: "exclamationmark.triangle",
                    title: "没能加载回复",
                    message: message,
                    actionTitle: "重试"
                ) {
                    Task {
                        await model.load(
                            id: topicID,
                            token: token.token,
                            cookie: session.cookie,
                            cache: topicCache,
                            offline: offline
                        )
                    }
                }
            } else if !token.hasToken, (model.topic?.replies ?? 0) > 0 {
                // v1's replies endpoint returns empty data for recent threads —
                // guide the user to the API 2.0 path instead of "no replies".
                EmptyStateCard(
                    icon: "key",
                    title: "回复未能加载",
                    message: "这个帖有回复，但 V2EX 旧版接口不返回新帖的回复数据，填入 Access Token 后即可查看。",
                    actionTitle: "去设置"
                ) { }
                .overlay {
                    NavigationLink(value: Route.tokenSetup) {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else if !model.visibleReplies.isEmpty {
                // 有回复，但全被屏蔽或举报滤掉了。说清楚是被过滤而不是没人回，
                // 否则用户会以为 App 没加载出来。
                EmptyStateCard(
                    icon: "nosign",
                    title: "回复已被隐藏",
                    message: "这个帖子里的回复都来自你屏蔽或举报过的内容。可以在「我的 → 内容与屏蔽」里调整。"
                )
            } else {
                EmptyStateCard(icon: "bubble.left", title: "还没有回复")
            }
        } else {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 0) {
                    ReplyRow(
                        item: item,
                        topicID: topicID,
                        isPro: model.proMembers.contains(item.reply.authorName),
                        onReply: { mention in
                            setComposerHidden(false)
                            replyDrafts.update(mention, for: topicID)
                            composerFocused = true
                        },
                        onQuoteTap: { floor in
                            jumpToQuotedReply(floor: floor, proxy: proxy)
                        },
                        onReport: { reportTarget = $0 }
                    )
                        .id(item.id)
                        .onAppear {
                            guard settings.rememberReadingPosition else { return }
                            readState.rememberPosition(item.floor, for: topicID)
                        }
                    if index < items.count - 1 {
                        RowSeparator(leadingInset: 59)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(highlightedReplyID == item.id ? Theme.accentSoft : Theme.card)
                .animation(.easeOut(duration: 0.22), value: highlightedReplyID)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: index == 0 ? Theme.Metric.cardRadius : 0,
                        bottomLeadingRadius: index == items.count - 1 ? Theme.Metric.cardRadius : 0,
                        bottomTrailingRadius: index == items.count - 1 ? Theme.Metric.cardRadius : 0,
                        topTrailingRadius: index == 0 ? Theme.Metric.cardRadius : 0,
                        style: .continuous
                    )
                )
                .padding(.horizontal, Theme.Metric.screenPadding)
                .padding(.top, index == 0 ? 0 : -10)
            }

            let hidden = model.visibleReplies.count - items.count
            if hidden > 0 {
                Text("\(hidden) 条回复已因屏蔽或举报隐藏")
                    .font(Type.meta(12))
                    .foregroundStyle(Theme.faint)
                    .padding(.horizontal, Theme.Metric.headerPadding)
                    .padding(.top, 8)
            }
        }
    }

    /// Quote cards carry the resolved floor number. Reveal that row even when
    /// "只看楼主" is active, then briefly tint it so the destination is clear.
    private func jumpToQuotedReply(floor: Int, proxy: ScrollViewProxy) {
        let visibleReplies = moderation.visible(model.replies)
        guard let target = visibleReplies.first(where: { $0.floor == floor }) else { return }

        if model.filter == .authorOnly, !target.isAuthor {
            model.filter = .byFloor
        }

        highlightClearTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            highlightedReplyID = target.id
        }

        // Changing the filter materializes previously hidden rows on the next
        // update cycle, so defer the scroll by one turn of the main actor.
        Task { @MainActor in
            await Task.yield()
            if reduceMotion {
                proxy.scrollTo(target.id, anchor: .center)
            } else {
                withAnimation(.snappy(duration: 0.3)) {
                    proxy.scrollTo(target.id, anchor: .center)
                }
            }
        }

        highlightClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, highlightedReplyID == target.id else { return }
            withAnimation(.easeIn(duration: 0.3)) {
                highlightedReplyID = nil
            }
        }
    }

    // MARK: Composer

    private var composerVisibilityGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if value.translation.height < -18 {
                    setComposerHidden(true)
                } else if value.translation.height > 18 {
                    setComposerHidden(false)
                }
            }
    }

    private func setComposerHidden(_ hidden: Bool) {
        guard hidden != isComposerHidden, !(hidden && isSending) else { return }
        if hidden { composerFocused = false }
        isComposerHidden = hidden
    }

    /// Floating Liquid Glass composer. The field and the send button live in one
    /// GlassContainer (GlassEffectContainer on iOS 26) so their glass blends instead of stacking.
    /// 已登录（网页会话）时直接在 app 内输入并发送；未登录时跳网页版。
    private var composerBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("写下你的回复…", text: replyDraftBinding, axis: .vertical)
                .lineLimit(1...6)
                .font(.system(size: 16))
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit { Task { await sendReply() } }
                .padding(.leading, 18)
                .padding(.trailing, 12)
                .padding(.vertical, 14)
                .glassPill()

            Button {
                Task { await sendReply() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .prominentGlassButtonStyle()
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(Theme.accent)
            .disabled(
                isSending
                    || replyDrafts.text(for: topicID)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
            )
        }
    }

    private var replyComposer: some View {
        GlassContainer(spacing: 12) {
            if session.isLoggedIn {
                VStack(alignment: .leading, spacing: 8) {
                    mentionSuggestions
                    composerBar
                }
                .animation(.snappy(duration: 0.18), value: mentionCandidates)
            } else {
                HStack(spacing: 12) {
                    Text("写下你的回复…（未登录将打开网页版）")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 18)
                        .padding(.trailing, 12)
                        .padding(.vertical, 14)
                        .glassPill()
                        .onTapGesture {
                            // API 2.0 has no reply endpoint — hand off to the web composer.
                            openURL(URL(string: "https://www.v2ex.com/t/\(topicID)#reply")!)
                        }

                    Button {
                        openURL(URL(string: "https://www.v2ex.com/t/\(topicID)#reply")!)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .prominentGlassButtonStyle()
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .tint(Theme.accent)
                }
            }
        }
        .padding(.horizontal, Theme.Metric.screenPadding)
        .padding(.bottom, 8)
        .alert("回复失败", isPresented: $showReplyError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(replyError ?? "")
        }
    }

    private func sendReply() async {
        let content = replyDrafts.text(for: topicID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await V2EXClient.shared.reply(topicID: topicID, content: content, cookie: session.cookie)
            replyDrafts.clear(topicID: topicID)
            composerFocused = false
            await model.load(
                id: topicID,
                token: token.token,
                cookie: session.cookie,
                cache: topicCache,
                offline: offline
            )
        } catch {
            // 回复失败不再清登录状态：一次失败不代表会话失效，由用户决定何时退出。
            if case V2EXError.sessionExpired = error {
                replyError = "网页会话可能已失效，请到设置里重新登录 V2EX。"
            } else {
                replyError = (error as? V2EXError)?.errorDescription ?? error.localizedDescription
            }
            showReplyError = true
        }
    }
}

// MARK: - Discussion track

private struct DiscussionTrack: View {
    let items: [ThreadedReply]
    let totalCount: Int
    let onSelect: (ThreadedReply) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("讨论轨道", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(totalCount) 层")
                    .font(Type.number(11, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }

            ZStack {
                Capsule()
                    .fill(Theme.separator)
                    .frame(height: 1)
                    .padding(.horizontal, 18)

                HStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            VStack(spacing: 4) {
                                Group {
                                    if item.isAuthor {
                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                            .fill(Theme.accent)
                                            .rotationEffect(.degrees(45))
                                    } else {
                                        Circle().fill(Theme.card)
                                            .overlay {
                                                Circle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.25)
                                            }
                                    }
                                }
                                .frame(width: item.isAuthor ? 9 : 8, height: item.isAuthor ? 9 : 8)

                                Text("\(item.floor)")
                                    .font(Type.number(9, weight: .medium))
                                    .foregroundStyle(item.isAuthor ? Theme.accent : Theme.muted)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "跳到第 \(item.floor) 楼\(item.isAuthor ? "，楼主回复" : "")"
                        )
                    }
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .glassPill(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(13)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: Theme.Metric.hairline)
        }
        .padding(.horizontal, Theme.Metric.screenPadding)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Reply row

struct ReplyRow: View {
    let item: ThreadedReply
    /// 举报回复要连帖子 ID 一起报，好让开发者拼出 v2ex.com 上的定位链接。
    /// `V2Reply.topicId` 在网页抓取和离线快照里可能缺，所以由父视图给。
    var topicID: Int = 0
    var isPro = false
    var onReply: ((String) -> Void)? = nil
    var onQuoteTap: ((Int) -> Void)? = nil
    var onReport: ((ModerationTarget) -> Void)? = nil
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            NavigationLink(value: Route.member(item.reply.authorName)) {
                IdentitySquare(
                    text: item.reply.authorName,
                    size: 32,
                    imageURL: item.reply.member?.avatarURL
                )
            }
            .buttonStyle(.plain)
            .fixedSize()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(item.reply.authorName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    if item.isAuthor {
                        Text("楼主")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    if isPro { ProBadge() }
                    Text(RelativeTime.string(from: item.reply.date))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 4)
                    Text("#\(item.floor)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                    if let onReply {
                        Button {
                            onReply("@\(item.reply.authorName) #\(item.floor) ")
                        } label: {
                            Image(systemName: "arrowshape.turn.up.left")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    // 举报入口给一个看得见的按钮，不藏在长按里 —— 长按是
                    // 发现不了的手势，而这是每条 UGC 都必须够得着的动作。
                    if let onReport {
                        Menu {
                            ModerationMenuItems(target: moderationTarget, onReport: onReport)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 30, height: 32)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        // 不加这个，Menu 的 label 是纯图标，辅助功能树里读不出
                        // 任何名字 —— 举报入口对 VoiceOver 用户等于不存在。
                        .accessibilityLabel("举报或屏蔽 \(item.reply.authorName) 的这条回复")
                    }
                }

                if let quoted = item.quoted {
                    quoteBlock(quoted)
                }

                // Block renderer, not inline: replies can carry images, and
                // the inline path collapses `<img>` to a "[图片]" link.
                ContentBlocksView(
                    blocks: item.contentBlocks,
                    fontSize: settings.bodyFontSize - 1,
                    lineSpacing: settings.bodyLineSpacing * 0.75
                )
            }
            // Without this the VStack gets an unbounded width proposal and the
            // reply body runs past the card's right edge.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // Must come after the padding: widening first and padding second makes
        // the row 32pt wider than the card, which clips the last glyph.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if let onReport {
                ModerationMenuItems(target: moderationTarget, onReport: onReport)
            }
        }
    }

    private var moderationTarget: ModerationTarget {
        .reply(
            id: item.reply.id,
            topicID: item.reply.topicId ?? topicID,
            author: item.reply.authorName,
            excerpt: item.reply.content
        )
    }

    /// The design's fold-quote: accent rule, author + floor, one-line excerpt.
    @ViewBuilder
    private func quoteBlock(_ quoted: ThreadedReply.QuotedReply) -> some View {
        if let floor = quoted.floor, let onQuoteTap {
            Button {
                onQuoteTap(floor)
            } label: {
                quoteBlockContent(quoted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("跳到 \(quoted.username) 的第 \(floor) 楼回复")
        } else {
            quoteBlockContent(quoted)
        }
    }

    private func quoteBlockContent(_ quoted: ThreadedReply.QuotedReply) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.accent.opacity(0.35))
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(quoted.floor.map { "\(quoted.username) #\($0)" } ?? quoted.username)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                if !quoted.excerpt.isEmpty {
                    Text(quoted.excerpt)
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if quoted.floor != nil, onQuoteTap != nil {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
        .fixedSize(horizontal: false, vertical: true)
    }
}
