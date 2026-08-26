import SwiftUI

// MARK: - 我的收藏

struct FavoritesView: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var session: V2EXSessionStore
    @EnvironmentObject private var moderation: ModerationStore
    @State private var reportTarget: ModerationTarget?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                let visible = moderation.filter(favorites.topics)
                if visible.isEmpty {
                    EmptyStateCard(
                        icon: "star",
                        title: "还没有收藏",
                        message: "在话题页点右上角的星标即可收藏。"
                    )
                    .padding(.top, 8)
                } else {
                    TopicListCard(items: visible) { topic in
                        NavigationLink(value: Route.topic(topic.id)) {
                            TopicRow(topic: topic, isOffline: offline.isOffline(topic.id))
                        }
                        .buttonStyle(.row)
                        .contextMenu {
                            Button(role: .destructive) {
                                favorites.toggle(topic)
                            } label: {
                                Label("取消收藏", systemImage: "star.slash")
                            }
                            ModerationMenuItems(
                                target: .topic(
                                    id: topic.id,
                                    author: topic.authorName,
                                    excerpt: topic.title
                                ),
                                onReport: { reportTarget = $0 }
                            )
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 登录态下拉 V2EX 网页收藏合并进本地列表。
            await favorites.syncFromRemote(cookie: session.cookie)
        }
        .pullToRefresh {
            // 新收藏按时间倒序出现在第一页；完整历史已由上面的后台任务同步。
            await favorites.syncFromRemote(cookie: session.cookie, maxPages: 1)
        }
    }
}

// MARK: - 浏览历史

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var moderation: ModerationStore
    @State private var showClearConfirm = false

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M 月 d 日"
        return formatter
    }()

    /// 按天分组。`history.entries` 已按时间倒序，所以顺着走一遍即可，
    /// 分完组不必再排序。
    private var sections: [(title: String, entries: [HistoryStore.Entry])] {
        var order: [String] = []
        var grouped: [String: [HistoryStore.Entry]] = [:]
        for entry in history.entries where !moderation.isHidden(entry.topic) {
            let title = Self.dayTitle(for: entry.viewedAt)
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(entry)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private static func dayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return dayFormatter.string(from: date)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if history.entries.isEmpty {
                    EmptyStateCard(
                        icon: "clock.arrow.circlepath",
                        title: "还没有浏览记录",
                        message: "读过的话题会出现在这里，保留 \(HistoryStore.retentionDays) 天。"
                    )
                    .padding(.top, 8)
                } else {
                    ForEach(sections, id: \.title) { section in
                        GroupHeader(title: section.title)
                        TopicListCard(items: section.entries) { entry in
                            NavigationLink(value: Route.topic(entry.topic.id)) {
                                TopicRow(
                                    topic: entry.topic,
                                    isOffline: offline.isOffline(entry.topic.id)
                                )
                            }
                            .buttonStyle(.row)
                            .promotionBadge(for: entry.topic)
                            .contextMenu {
                                Button(role: .destructive) {
                                    history.remove(id: entry.topic.id)
                                } label: {
                                    Label("从历史中移除", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Text("记录保留 \(HistoryStore.retentionDays) 天，只存在这台设备上。")
                        .font(Type.meta(12))
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, Theme.Metric.headerPadding)
                        .padding(.top, 6)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("浏览历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !history.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { showClearConfirm = true }
                        .foregroundStyle(Theme.body)
                }
            }
        }
        .confirmationDialog("清空浏览历史？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) { history.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(history.entries.count) 条记录，清空后无法恢复。")
        }
    }
}

// MARK: - 稍后读 / 离线

struct OfflineListView: View {
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var moderation: ModerationStore
    @State private var showClearConfirm = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                CardSection {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(offline.bundles.count) 篇已下载")
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.ink)
                            Text("占用 \(offline.formattedSize)")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if !offline.bundles.isEmpty {
                            Button("清空", role: .destructive) { showClearConfirm = true }
                                .font(.system(size: 15))
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
                }

                let visibleBundles = offline.bundles.filter { !moderation.isHidden($0.topic) }
                if visibleBundles.isEmpty {
                    EmptyStateCard(
                        icon: "arrow.down.circle",
                        title: "还没有离线内容",
                        message: "在话题页的「…」里选择「保存以离线阅读」，整帖和回复都会存到本地。"
                    )
                } else {
                    TopicListCard(items: visibleBundles) { saved in
                        NavigationLink(value: Route.topic(saved.topic.id)) {
                            TopicRow(topic: saved.topic, isOffline: false)
                        }
                        .buttonStyle(.row)
                        .contextMenu {
                            Button(role: .destructive) {
                                offline.remove(id: saved.id)
                            } label: {
                                Label("删除离线内容", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("稍后读 / 离线")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog("清空全部离线内容？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空 \(offline.formattedSize)", role: .destructive) { offline.clearAll() }
            Button("取消", role: .cancel) { }
        }
    }
}

// MARK: - 我的话题与回复

struct MyPostsView: View {
    @EnvironmentObject private var token: TokenStore
    @State private var topics: [V2Topic] = []
    @State private var isLoading = false
    @State private var username = ""

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if !token.hasToken {
                    EmptyStateCard(
                        icon: "key",
                        title: "需要 Access Token",
                        message: "V2EX 只在 API 2.0 暴露当前账号，填入 Token 后这里会显示你发过的话题。"
                    )
                    .padding(.top, 8)
                } else if isLoading {
                    LoadingCard().padding(.top, 8)
                } else if topics.isEmpty {
                    EmptyStateCard(icon: "doc.text", title: "还没有发过话题").padding(.top, 8)
                } else {
                    TopicListCard(items: topics) { topic in
                        NavigationLink(value: Route.topic(topic.id)) {
                            TopicRow(topic: topic)
                        }
                        .buttonStyle(.row)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("我的话题")
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
    }

    private func load() async {
        guard token.hasToken, topics.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        guard let member = try? await V2EXClient.shared.currentMember(token: token.token) else { return }
        username = member.username
        topics = (try? await V2EXClient.shared.topics(byMember: member.username)) ?? []
    }
}

// MARK: - 用户主页

struct MemberView: View {
    let username: String

    @State private var member: V2Member?
    @State private var topics: [V2Topic] = []
    @State private var isLoading = false
    @State private var reportTarget: ModerationTarget?
    @EnvironmentObject private var moderation: ModerationStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if moderation.isBlocked(username: username) {
                    blockedBanner
                }
                if let member {
                    profileCard(member)
                } else if isLoading {
                    LoadingCard()
                } else {
                    EmptyStateCard(icon: "person", title: "没有找到这个用户")
                }

                let visible = moderation.filter(topics)
                if !visible.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        GroupHeader(title: "最近发布")
                        TopicListCard(items: visible) { topic in
                            NavigationLink(value: Route.topic(topic.id)) {
                                TopicRow(topic: topic)
                            }
                            .buttonStyle(.row)
                            .contextMenu {
                                ModerationMenuItems(
                                    target: .topic(
                                        id: topic.id,
                                        author: topic.authorName,
                                        excerpt: topic.title
                                    ),
                                    onReport: { reportTarget = $0 }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle(username)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ModerationMenuItems(
                        target: .member(username: username),
                        onReport: { reportTarget = $0 }
                    )
                    if moderation.isBlocked(username: username) {
                        Button {
                            moderation.unblock(username: username)
                        } label: {
                            Label("取消屏蔽", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.body)
                }
                .accessibilityLabel("举报或屏蔽这个用户")
            }
        }
        .sheet(item: $reportTarget) { ReportSheet(target: $0) }
        .task { await load() }
    }

    /// 屏蔽后仍然进得来这个页面（从别处的链接），所以要说清楚为什么这里
    /// 是空的，以及怎么反悔。
    private var blockedBanner: some View {
        CardSection(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "nosign")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("你已屏蔽这个用户")
                        .font(Type.title(15))
                        .foregroundStyle(Theme.ink)
                    Text("他的话题和回复不会出现在 App 的任何地方。")
                        .font(Type.body(13))
                        .foregroundStyle(Theme.muted)
                    Button("取消屏蔽") { moderation.unblock(username: username) }
                        .font(Type.meta(13))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func profileCard(_ member: V2Member) -> some View {
        CardSection(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    IdentitySquare(text: member.username, size: 56, imageURL: member.avatarURL)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(member.username)
                            .font(.system(size: 20, weight: .bold))
                            .kerning(-0.5)
                            .foregroundStyle(Theme.ink)
                        if let days = member.joinedDays {
                            let idText = member.id.map { "第 \($0.formatted()) 号会员 · " } ?? ""
                            Text("\(idText)加入 \(days.formatted()) 天")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let tagline = member.tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let bio = member.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func load() async {
        guard member == nil else { return }
        isLoading = true
        defer { isLoading = false }
        member = try? await V2EXClient.shared.member(username: username)
        topics = (try? await V2EXClient.shared.topics(byMember: username)) ?? []
    }
}
