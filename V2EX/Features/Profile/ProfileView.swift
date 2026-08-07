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
    @EnvironmentObject private var blocks: BlockStore
    @EnvironmentObject private var history: HistoryStore

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
                menuCard
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

                HStack(spacing: 8) {
                    statTile(value: "\(model.recentTopics.count)", label: "话题", destination: .myPosts)
                    statTile(value: "\(favorites.topics.count)", label: "收藏", destination: .favorites)
                    statTile(value: "\(offline.bundles.count)", label: "离线", tinted: true, destination: .offline)
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

    private func statTile(value: String, label: String, tinted: Bool = false, destination: Route) -> some View {
        NavigationLink(value: destination) {
            VStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(tinted ? Theme.amber : Theme.ink)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.row)
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

    private var menuCard: some View {
        CardSection {
            NavigationLink(value: Route.favorites) {
                SettingsRow(icon: "star.fill", iconColor: Theme.amber, title: "我的收藏") {
                    HStack(spacing: 6) {
                        Text("\(favorites.topics.count)")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                        Chevron()
                    }
                }
            }
            .buttonStyle(.row)
            RowSeparator(leadingInset: 58)

            NavigationLink(value: Route.history) {
                SettingsRow(
                    icon: "clock.arrow.circlepath",
                    iconColor: Theme.accent,
                    title: "浏览历史",
                    subtitle: "保留 \(HistoryStore.retentionDays) 天"
                ) {
                    HStack(spacing: 6) {
                        Text("\(history.entries.count)")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                        Chevron()
                    }
                }
            }
            .buttonStyle(.row)
            RowSeparator(leadingInset: 58)

            NavigationLink(value: Route.offline) {
                SettingsRow(
                    icon: "arrow.down.circle.fill",
                    iconColor: Theme.accent,
                    title: "稍后读 / 离线",
                    subtitle: "\(offline.bundles.count) 篇已下载 · 占用 \(offline.formattedSize)"
                ) { Chevron() }
            }
            .buttonStyle(.row)
            RowSeparator(leadingInset: 58)

            NavigationLink(value: Route.myPosts) {
                SettingsRow(icon: "list.bullet", iconColor: Theme.accent, title: "我的话题与回复") {
                    Chevron()
                }
            }
            .buttonStyle(.row)
            RowSeparator(leadingInset: 58)

            NavigationLink(value: Route.blocked) {
                SettingsRow(icon: "nosign", iconColor: Theme.accent, title: "屏蔽的关键词与用户") {
                    HStack(spacing: 6) {
                        Text("\(blocks.count)")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                        Chevron()
                    }
                }
            }
            .buttonStyle(.row)
        }
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
