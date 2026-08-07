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
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var replyError: String?
    @State private var showReplyError = false
    @State private var isSending = false
    @State private var isSyncingFavorite = false
    @State private var isComposerHidden = false
    @State private var showShareCard = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.canvas.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let topic = model.topic {
                            topicCard(topic)
                            replyHeader(topic)
                            replyList
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
                    .padding(.top, 6)
                    .padding(.bottom, 110)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(composerVisibilityGesture)
                .pullToRefresh {
                    await model.load(
                        id: topicID,
                        token: token.token,
                        cookie: session.cookie,
                        cache: topicCache,
                        offline: offline
                    )
                }
                .onChange(of: model.replies.count) { _, count in
                    guard settings.rememberReadingPosition, count > 0,
                          let floor = readState.position(for: topicID), floor > 1 else { return }
                    // Restore where the reader left off.
                    if let target = model.replies.first(where: { $0.floor == floor }) {
                        proxy.scrollTo(target.id, anchor: .top)
                    }
                }
            }

            replyComposer
                .offset(y: isComposerHidden ? 110 : 0)
                .opacity(isComposerHidden ? 0 : 1)
                .allowsHitTesting(!isComposerHidden)
                .accessibilityHidden(isComposerHidden)
                .animation(.snappy(duration: 0.24), value: isComposerHidden)
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
                TopicShareCardSheet(topic: topic)
            }
        }
        .onDisappear { replyDrafts.save() }
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
                            .glassEffect(.regular.interactive(), in: .capsule)
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
                        ShareLink(item: topic.webURL) { Label("分享链接", systemImage: "link") }
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
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(Theme.body)
                }
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

    @ViewBuilder
    private var replyList: some View {
        let items = model.visibleReplies
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
            } else {
                EmptyStateCard(icon: "bubble.left", title: "还没有回复")
            }
        } else {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 0) {
                    ReplyRow(
                        item: item,
                        isPro: model.proMembers.contains(item.reply.authorName),
                        onReply: { mention in
                            setComposerHidden(false)
                            replyDrafts.update(mention, for: topicID)
                            composerFocused = true
                        }
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
                .background(Theme.card)
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
    /// GlassEffectContainer so their glass blends instead of stacking.
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
                .glassEffect(.regular.interactive(), in: .capsule)

            Button {
                Task { await sendReply() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glassProminent)
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
        GlassEffectContainer(spacing: 12) {
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
                        .glassEffect(.regular.interactive(), in: .capsule)
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
                    .buttonStyle(.glassProminent)
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

// MARK: - Reply row

struct ReplyRow: View {
    let item: ThreadedReply
    var isPro = false
    var onReply: ((String) -> Void)? = nil
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
    }

    /// The design's fold-quote: accent rule, author + floor, one-line excerpt.
    private func quoteBlock(_ quoted: ThreadedReply.QuotedReply) -> some View {
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
        }
        .padding(.vertical, 2)
        .fixedSize(horizontal: false, vertical: true)
    }
}
