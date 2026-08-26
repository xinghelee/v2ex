import SwiftUI

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published private(set) var member: V2Member?
    @Published private(set) var recentTopics: [V2Topic] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    func load(token: String) async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }

        guard !token.isEmpty else {
            member = nil
            recentTopics = []
            return
        }
        do {
            let fresh = try await V2EXClient.shared.currentMember(token: token)
            member = fresh
            recentTopics = (try? await V2EXClient.shared.topics(byMember: fresh.username)) ?? []
        } catch {
            // Keep whatever we already have — a transient failure (throttle,
            // flaky network) must not look like the user signed out.
            if member == nil { loadFailed = true }
        }
    }
}

struct ProfileView: View {
    @StateObject private var model = ProfileViewModel()
    @EnvironmentObject private var token: TokenStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var moderation: ModerationStore
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var followed: FollowedNodesStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if token.hasToken, let member = model.member {
                    profileCard(member)
                } else if token.hasToken, model.isLoading {
                    LoadingCard()
                } else if token.hasToken, model.loadFailed {
                    EmptyStateCard(
                        icon: "wifi.exclamationmark",
                        title: "没能加载个人资料",
                        message: "网络或接口暂时不可用，你的登录状态没有变，下拉或点重试即可。",
                        actionTitle: "重试"
                    ) {
                        Task { await model.load(token: token.token) }
                    }
                } else {
                    signedOutCard
                }
                collectionsGrid
                if !model.recentTopics.isEmpty {
                    recentSection
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .pullToRefresh { await model.load(token: token.token) }
        .background(Theme.canvas)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
        .task(id: token.token) { await model.load(token: token.token) }
    }

    private func profileCard(_ member: V2Member) -> some View {
        CardSection(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        LinearGradient(
                            colors: [Theme.accent, Theme.accentDeep],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        Text(String(member.username.prefix(2)).lowercased())
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                        if let url = member.avatarURL {
                            CachedRemoteImage(url: url)
                        }
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(member.username)
                            .font(.system(size: 20, weight: .bold))
                            .kerning(-0.5)
                            .foregroundStyle(Theme.ink)
                        Text(membershipLine(member))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }

                if let bio = member.bio ?? member.tagline, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }
        }
    }

    private func membershipLine(_ member: V2Member) -> String {
        var parts: [String] = []
        if let id = member.id { parts.append("V2EX 第 \(id.formatted()) 号会员") }
        if let days = member.joinedDays { parts.append("加入 \(days.formatted()) 天") }
        return parts.isEmpty ? "V2EX 会员" : parts.joined(separator: " · ")
    }

    private var signedOutCard: some View {
        NavigationLink(value: Route.tokenSetup) {
            CardSection(padding: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        LinearGradient(
                            colors: [Theme.accent, Theme.accentDeep],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        Image(systemName: "person.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("未连接账号")
                            .font(.system(size: 20, weight: .bold))
                            .kerning(-0.5)
                            .foregroundStyle(Theme.ink)
                        Text("填入 Access Token 后可看通知和个人资料")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Chevron()
                }
            }
        }
        .buttonStyle(.row)
    }

    /// 四个「有内容」的入口做成 2×2 数据网格。
    ///
    /// 之前它们和「屏蔽」并列成五行等宽菜单，读起来就是一张系统设置表：
    /// 每行权重相同，真正有信息量的数字被挤到行尾当配角。这里把数字提到
    /// 主位，并换上设计系统里那套等宽圆体数字 —— 全 App 的计数都用它，
    /// 唯独这页之前没用。
    private var collectionsGrid: some View {
        VStack(spacing: 0) {
            // 「节点」让位给 HN 时才出现，避免和标签栏重复。
            if nodesTabDisplaced {
                collectionRow(icon: "square.grid.2x2", count: followed.names.count,
                              title: "节点目录", caption: "已关注", route: .nodeCatalog)
                RowSeparator(leadingInset: 52)
            }
            collectionRow(icon: "star", count: favorites.topics.count,
                          title: "收藏", route: .favorites)
            RowSeparator(leadingInset: 52)
            collectionRow(icon: "clock.arrow.circlepath", count: history.entries.count,
                          title: "浏览历史", caption: "保留 \(HistoryStore.retentionDays) 天",
                          route: .history)
            RowSeparator(leadingInset: 52)
            collectionRow(icon: "arrow.down.circle", count: offline.bundles.count,
                          title: "稍后读",
                          caption: offline.bundles.isEmpty ? nil : offline.formattedSize,
                          route: .offline)
            RowSeparator(leadingInset: 52)
            collectionRow(icon: "square.text.square", count: model.recentTopics.count,
                          title: "我的话题", route: .myPosts)
            RowSeparator(leadingInset: 52)
            collectionRow(icon: "nosign", count: moderation.count,
                          title: "内容与屏蔽", route: .blocked)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous))
        .padding(.horizontal, Theme.Metric.screenPadding)
    }

    /// 一行一个入口，计数当右侧锚点。
    ///
    /// 之前这里是填充色圆角方块图标 + 行尾灰色小字计数 —— 那套配色方块正是
    /// iOS 设置的招牌，而真正有信息量的数字被降成了配角。现在图标退成单色
    /// 线条，计数换上设计系统那套等宽圆体数字；没有内容的项整行退到 faint，
    /// 于是有东西的几行不必加粗也会自己浮出来。陈列了计数就不再给 chevron，
    /// 两个尾随元素只会互相打架。
    private var nodesTabDisplaced: Bool {
        settings.hackerNewsEnabled && settings.hackerNewsPlacement == .tab
    }

    private func collectionRow(
        icon: String,
        count: Int,
        title: String,
        caption: String? = nil,
        route: Route
    ) -> some View {
        let isEmpty = count == 0
        return NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isEmpty ? Theme.faint : Theme.accent)
                    .frame(width: 22)

                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(isEmpty ? Theme.muted : Theme.ink)

                if let caption {
                    Text(caption)
                        .font(Type.label(11))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("\(count)")
                    .font(Type.number(18, weight: .semibold))
                    .foregroundStyle(isEmpty ? Theme.faint : Theme.ink)
            }
            .padding(.horizontal, Theme.Metric.cardPadding)
            .frame(height: Theme.Metric.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "最近发布")
            CardSection {
                ForEach(Array(model.recentTopics.prefix(5).enumerated()), id: \.element.id) { index, topic in
                    NavigationLink(value: Route.topic(topic.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(topic.title)
                                .font(.system(size: 16, weight: .medium))
                                .kerning(-0.3)
                                .lineSpacing(2)
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            Text("\(topic.nodeTitle) · \(RelativeTime.string(from: topic.activityDate)) · \(topic.replies) 回复")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.row)
                    if index < min(model.recentTopics.count, 5) - 1 { RowSeparator() }
                }
            }
        }
    }
}
