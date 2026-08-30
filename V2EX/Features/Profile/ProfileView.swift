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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var metricColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    private var libraryCount: Int {
        favorites.topics.count + history.entries.count + offline.bundles.count + model.recentTopics.count
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                accountSection
                librarySection
                utilitySection

                if !model.recentTopics.isEmpty {
                    recentSection
                }
            }
            .readableColumn()
            .padding(.top, 10)
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
        .softBottomEdgeEffect()
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

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        if token.hasToken, let member = model.member {
            profileCard(member)
        } else if token.hasToken, model.isLoading {
            LoadingCard()
        } else if token.hasToken, model.loadFailed {
            EmptyStateCard(
                icon: "wifi.exclamationmark",
                title: "没能加载个人资料",
                message: "网络或接口暂时不可用，你的登录状态没有改变。",
                actionTitle: "重试"
            ) {
                Task { await model.load(token: token.token) }
            }
        } else if token.hasToken {
            // Avoid flashing the signed-out CTA for one frame before the task
            // flips isLoading on a connected account.
            LoadingCard()
        } else {
            signedOutCard
        }
    }

    private func profileCard(_ member: V2Member) -> some View {
        CardSection(padding: 18) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 14) {
                    IdentitySquare(text: member.username, size: 64, imageURL: member.avatarURL)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Text(member.username)
                                .font(.system(size: 21, weight: .bold))
                                .kerning(-0.5)
                                .foregroundStyle(Theme.ink)
                            Label("已连接", systemImage: "checkmark.circle.fill")
                                .font(Type.label(10))
                                .foregroundStyle(Theme.accent)
                                .labelStyle(.titleAndIcon)
                        }
                        Text(membershipLine(member))
                            .font(Type.meta(13))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                if let bio = profileBio(member) {
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(height: Theme.Metric.hairline)
                    Text(bio)
                        .font(Type.body(15))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func membershipLine(_ member: V2Member) -> String {
        var parts: [String] = []
        if let id = member.id { parts.append("第 \(id.formatted()) 号会员") }
        if let days = member.joinedDays { parts.append("加入 \(days.formatted()) 天") }
        return parts.isEmpty ? "V2EX 会员" : parts.joined(separator: " · ")
    }

    private func profileBio(_ member: V2Member) -> String? {
        [member.bio, member.tagline]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private var signedOutCard: some View {
        NavigationLink(value: Route.tokenSetup) {
            CardSection(padding: 18) {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Theme.accentSoft)
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .frame(width: 64, height: 64)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("访客模式")
                                .font(.system(size: 21, weight: .bold))
                                .kerning(-0.5)
                                .foregroundStyle(Theme.ink)
                            Text("浏览不受影响；连接账号后可查看通知与个人内容。")
                                .font(Type.meta(13))
                                .lineSpacing(2)
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 7) {
                        Text("连接 V2EX 账号")
                            .font(.system(size: 14, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Theme.accentSoft, in: Capsule())
                }
            }
        }
        .buttonStyle(.row)
        .accessibilityLabel("访客模式，连接 V2EX 账号")
        .accessibilityHint("填写 Access Token")
    }

    // MARK: - Library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "我的空间", trailing: libraryCount > 0 ? "\(libraryCount) 项" : nil)
            LazyVGrid(columns: metricColumns, spacing: 10) {
                metricCard(
                    icon: "star.fill",
                    count: favorites.topics.count,
                    title: "收藏",
                    caption: "喜欢的话题",
                    route: .favorites
                )
                metricCard(
                    icon: "clock.arrow.circlepath",
                    count: history.entries.count,
                    title: "浏览历史",
                    caption: "最近 \(HistoryStore.retentionDays) 天",
                    route: .history
                )
                metricCard(
                    icon: "arrow.down.circle.fill",
                    count: offline.bundles.count,
                    title: "稍后读",
                    caption: offline.bundles.isEmpty ? "离线资料库" : offline.formattedSize,
                    route: .offline
                )
                metricCard(
                    icon: "square.text.square.fill",
                    count: model.recentTopics.count,
                    title: "我的话题",
                    caption: token.hasToken ? "最近发布" : "连接后查看",
                    route: .myPosts
                )
            }
            .padding(.horizontal, Theme.Metric.screenPadding)
        }
    }

    private func metricCard(
        icon: String,
        count: Int,
        title: String,
        caption: String,
        route: Route
    ) -> some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Spacer(minLength: 8)
                    Text(count.formatted())
                        .font(Type.number(24, weight: .bold))
                        .foregroundStyle(count == 0 ? Theme.faint : Theme.ink)
                        .contentTransition(.numericText(value: Double(count)))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(caption)
                        .font(Type.meta(11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.row)
    }

    // MARK: - Utilities

    private var utilitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "管理")
            CardSection {
                if nodesTabDisplaced {
                    utilityRow(
                        icon: "square.grid.2x2",
                        title: "节点目录",
                        subtitle: "已关注 \(followed.names.count) 个节点",
                        route: .nodeCatalog
                    )
                    RowSeparator(leadingInset: 54)
                }

                utilityRow(
                    icon: "checkmark.shield",
                    title: "内容与屏蔽",
                    subtitle: moderation.count == 0 ? "关键词、用户与举报记录" : "\(moderation.count) 条规则正在生效",
                    route: .blocked
                )
            }
        }
    }

    private var nodesTabDisplaced: Bool {
        settings.hackerNewsEnabled && settings.hackerNewsPlacement == .tab
    }

    private func utilityRow(icon: String, title: String, subtitle: String, route: Route) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text(subtitle)
                        .font(Type.meta(12))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Chevron()
            }
            .padding(.horizontal, Theme.Metric.cardPadding)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "最近发布", trailing: "\(min(model.recentTopics.count, 4)) 篇")
            TopicListCard(items: Array(model.recentTopics.prefix(4))) { topic in
                NavigationLink(value: Route.topic(topic.id)) {
                    TopicRow(topic: topic, showsNode: true)
                }
                .buttonStyle(.row)
            }
        }
    }
}
