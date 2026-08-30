import SwiftUI

// MARK: - Shared collection header

/// The library pages share one clear opening gesture: identity, current count,
/// and a short explanation. This replaces one-off status rows and keeps the
/// first card useful even when the collection is empty.
private struct ProfileCollectionHeader: View {
    let icon: String
    let count: Int
    let title: String
    let message: String

    var body: some View {
        CardSection(padding: 18) {
            HStack(alignment: .center, spacing: 15) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 50, height: 50)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(count.formatted())
                            .font(Type.number(28, weight: .bold))
                            .foregroundStyle(count == 0 ? Theme.faint : Theme.ink)
                            .contentTransition(.numericText(value: Double(count)))
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    Text(message)
                        .font(Type.meta(12))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - 我的收藏

struct FavoritesView: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var session: V2EXSessionStore
    @EnvironmentObject private var moderation: ModerationStore
    @State private var reportTarget: ModerationTarget?

    private var visibleTopics: [V2Topic] { moderation.filter(favorites.topics) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ProfileCollectionHeader(
                    icon: "star.fill",
                    count: visibleTopics.count,
                    title: "篇收藏",
                    message: session.isLoggedIn ? "已连接网页收藏，本地内容会合并保留。" : "保存在本机；登录 V2EX 后可合并网页收藏。"
                )

                if visibleTopics.isEmpty {
                    EmptyStateCard(
                        icon: "star",
                        title: "还没有收藏",
                        message: "阅读话题时点右上角的星标，之后就能从这里快速返回。"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        GroupHeader(title: "收藏的话题", trailing: "\(visibleTopics.count) 篇")
                        TopicListCard(items: visibleTopics) { topic in
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
                                    target: .topic(id: topic.id, author: topic.authorName, excerpt: topic.title),
                                    onReport: { reportTarget = $0 }
                                )
                            }
                        }
                    }
                }
            }
            .readableColumn()
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $reportTarget) { ReportSheet(target: $0) }
        .task {
            await favorites.syncFromRemote(cookie: session.cookie)
        }
        .pullToRefresh {
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

    private var visibleCount: Int { sections.reduce(0) { $0 + $1.entries.count } }

    private static func dayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return dayFormatter.string(from: date)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ProfileCollectionHeader(
                    icon: "clock.arrow.circlepath",
                    count: visibleCount,
                    title: "条记录",
                    message: "按最近阅读时间排列，仅保存在本机并保留 \(HistoryStore.retentionDays) 天。"
                )

                if sections.isEmpty {
                    EmptyStateCard(
                        icon: "clock",
                        title: "还没有浏览记录",
                        message: "打开过的话题会自动出现在这里。"
                    )
                } else {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            GroupHeader(title: section.title, trailing: "\(section.entries.count) 条")
                            TopicListCard(items: section.entries) { entry in
                                NavigationLink(value: Route.topic(entry.topic.id)) {
                                    TopicRow(topic: entry.topic, isOffline: offline.isOffline(entry.topic.id))
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
                    }
                }
            }
            .readableColumn()
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("浏览历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
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
    private enum Scope: String, CaseIterable, Hashable {
        case all, manual, automatic

        var title: String {
            switch self {
            case .all: return "全部"
            case .manual: return "手动保存"
            case .automatic: return "自动离线"
            }
        }
    }

    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var moderation: ModerationStore
    @State private var showClearConfirm = false
    @State private var scope: Scope = .all

    private var visibleBundles: [OfflineStore.SavedTopic] {
        offline.bundles.filter { saved in
            guard !moderation.isHidden(saved.topic) else { return false }
            switch scope {
            case .all: return true
            case .manual: return !saved.isAutomatic
            case .automatic: return saved.isAutomatic
            }
        }
    }

    private var automaticCount: Int { offline.bundles.filter(\.isAutomatic).count }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ProfileCollectionHeader(
                    icon: "arrow.down.circle.fill",
                    count: offline.bundles.count,
                    title: "篇离线",
                    message: "占用 \(offline.formattedSize) · \(automaticCount) 篇由关注节点自动保存。"
                )

                if !offline.bundles.isEmpty {
                    ChipRail(items: Scope.allCases, selected: scope) { item in
                        FilterChip(title: item.title, isSelected: scope == item) {
                            scope = item
                        }
                        .id(item)
                    }
                }

                if visibleBundles.isEmpty {
                    EmptyStateCard(
                        icon: scope == .automatic ? "arrow.triangle.2.circlepath" : "arrow.down.circle",
                        title: scope == .all ? "还没有离线内容" : "这个分类还是空的",
                        message: scope == .all
                            ? "在话题页的更多菜单中选择“保存以离线阅读”，正文和回复都会存到本机。"
                            : "切换上方分类查看其他离线内容。"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        GroupHeader(title: scope.title, trailing: "\(visibleBundles.count) 篇")
                        TopicListCard(items: visibleBundles) { saved in
                            NavigationLink(value: Route.topic(saved.topic.id)) {
                                TopicRow(topic: saved.topic, isOffline: true)
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
            }
            .readableColumn()
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("稍后读")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if !offline.bundles.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { showClearConfirm = true }
                        .foregroundStyle(Theme.body)
                }
            }
        }
        .confirmationDialog("清空全部离线内容？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空 \(offline.formattedSize)", role: .destructive) { offline.clearAll() }
            Button("取消", role: .cancel) { }
        }
    }
}

// MARK: - 我的话题

struct MyPostsView: View {
    @EnvironmentObject private var token: TokenStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var moderation: ModerationStore
    @State private var topics: [V2Topic] = []
    @State private var isLoading = false
    @State private var username = ""
    @State private var errorMessage: String?

    private var visibleTopics: [V2Topic] { moderation.filter(topics) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ProfileCollectionHeader(
                    icon: "square.text.square.fill",
                    count: visibleTopics.count,
                    title: "篇话题",
                    message: username.isEmpty ? "连接账号后查看自己发布的内容。" : "@\(username) 最近发布的话题。"
                )

                if !token.hasToken {
                    EmptyStateCard(
                        icon: "key",
                        title: "需要 Access Token",
                        message: "V2EX 通过 API 2.0 提供当前账号信息。Token 只保存在系统钥匙串。",
                        actionTitle: "连接账号"
                    ) { }
                    .overlay {
                        NavigationLink(value: Route.tokenSetup) {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else if isLoading && topics.isEmpty {
                    LoadingCard()
                } else if let errorMessage, topics.isEmpty {
                    EmptyStateCard(
                        icon: "wifi.exclamationmark",
                        title: "没能加载",
                        message: errorMessage,
                        actionTitle: "重试"
                    ) {
                        Task { await load(force: true) }
                    }
                } else if visibleTopics.isEmpty {
                    EmptyStateCard(icon: "doc.text", title: "还没有发过话题")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        GroupHeader(title: "最近发布", trailing: "\(visibleTopics.count) 篇")
                        TopicListCard(items: visibleTopics) { topic in
                            NavigationLink(value: Route.topic(topic.id)) {
                                TopicRow(topic: topic, isOffline: offline.isOffline(topic.id))
                            }
                            .buttonStyle(.row)
                        }
                    }
                }
            }
            .readableColumn()
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("我的话题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: token.token) { await load() }
        .pullToRefresh { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        guard token.hasToken else {
            topics = []
            username = ""
            errorMessage = nil
            return
        }
        guard force || topics.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let member = try await V2EXClient.shared.currentMember(token: token.token)
            username = member.username
            topics = try await V2EXClient.shared.topics(byMember: member.username)
        } catch {
            errorMessage = (error as? V2EXError)?.errorDescription ?? error.localizedDescription
        }
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
            LazyVStack(alignment: .leading, spacing: 16) {
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
                        GroupHeader(title: "最近发布", trailing: "\(visible.count) 篇")
                        TopicListCard(items: visible) { topic in
                            NavigationLink(value: Route.topic(topic.id)) {
                                TopicRow(topic: topic)
                            }
                            .buttonStyle(.row)
                            .contextMenu {
                                ModerationMenuItems(
                                    target: .topic(id: topic.id, author: topic.authorName, excerpt: topic.title),
                                    onReport: { reportTarget = $0 }
                                )
                            }
                        }
                    }
                }
            }
            .readableColumn()
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle(username)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
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
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    IdentitySquare(text: member.username, size: 62, imageURL: member.avatarURL)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(member.username)
                            .font(.system(size: 21, weight: .bold))
                            .kerning(-0.5)
                            .foregroundStyle(Theme.ink)
                        if let days = member.joinedDays {
                            let idText = member.id.map { "第 \($0.formatted()) 号会员 · " } ?? ""
                            Text("\(idText)加入 \(days.formatted()) 天")
                                .font(Type.meta(13))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let tagline = member.tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(Type.body(15))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let bio = member.bio, !bio.isEmpty, bio != member.tagline {
                    Rectangle().fill(Theme.separator).frame(height: Theme.Metric.hairline)
                    Text(bio)
                        .font(Type.body(14))
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
