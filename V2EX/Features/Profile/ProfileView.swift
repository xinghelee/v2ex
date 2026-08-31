import SwiftUI

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published private(set) var member: V2Member?
    @Published private(set) var recentTopics: [V2Topic] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    func load(token: String, sessionUsername: String) async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }

        guard !token.isEmpty || !sessionUsername.isEmpty else {
            member = nil
            recentTopics = []
            return
        }
        do {
            // Access Token 走 API 2.0 拿当前用户；只有网页会话（cookie）时用
            // 公开的 v1 接口按用户名查。两种凭证任占其一都算已连接——网页
            // 登录成功后资料页不该还把人当访客（真机反馈踩过这个坑）。
            let fresh: V2Member
            if !token.isEmpty {
                fresh = try await V2EXClient.shared.currentMember(token: token)
            } else {
                fresh = try await V2EXClient.shared.member(username: sessionUsername)
            }
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
    @EnvironmentObject private var session: V2EXSessionStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var radar: RadarStore
    @EnvironmentObject private var moderation: ModerationStore
    @EnvironmentObject private var history: HistoryStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct HistoryDay: Identifiable {
        let date: Date
        let count: Int
        var id: Date { date }
    }

    /// 已连接 = 任一凭证在手：Access Token（只读 API）或网页会话（回复）。
    private var isConnected: Bool { token.hasToken || session.isLoggedIn }

    private var libraryCount: Int {
        favorites.topics.count + history.entries.count + offline.bundles.count + model.recentTopics.count
    }

    /// `HistoryStore` keeps one entry per topic and updates its `viewedAt` when
    /// the topic is opened again. The chart therefore reports real, unique
    /// topics by their most recent reading day rather than inventing view counts.
    private var weeklyHistory: [HistoryDay] {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { distance in
            guard let date = calendar.date(byAdding: .day, value: -distance, to: today) else {
                return nil
            }
            let count = history.entries.lazy.filter {
                calendar.isDate($0.viewedAt, inSameDayAs: date)
            }.count
            return HistoryDay(date: date, count: count)
        }
    }

    private var weeklyHistoryCount: Int {
        weeklyHistory.reduce(0) { $0 + $1.count }
    }

    private var weeklyHistoryMaximum: Int {
        max(weeklyHistory.map(\.count).max() ?? 0, 1)
    }

    private var weeklyHistoryAccessibilityValue: String {
        weeklyHistory.map { day in
            "\(day.date.formatted(date: .abbreviated, time: .omitted)) \(day.count) 个话题"
        }
        .joined(separator: "，")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                accountSection
                weeklyFootprintSection
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
        .pullToRefresh { await model.load(token: token.token, sessionUsername: session.username) }
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
        .task(id: token.token + "|" + session.username) { await model.load(token: token.token, sessionUsername: session.username) }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        if isConnected, let member = model.member {
            profileCard(member)
        } else if isConnected, model.isLoading {
            LoadingCard()
        } else if isConnected, model.loadFailed {
            EmptyStateCard(
                icon: "wifi.exclamationmark",
                title: "没能加载个人资料",
                message: "网络或接口暂时不可用，你的登录状态没有改变。",
                actionTitle: "重试"
            ) {
                Task { await model.load(token: token.token, sessionUsername: session.username) }
            }
        } else if isConnected {
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
        NavigationLink(value: Route.settings) {
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
                            Text("浏览不受影响；连接账号后可按需启用回复、通知与个人内容。")
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
        .accessibilityHint("打开设置，选择网页登录或 Access Token")
    }

    // MARK: - Library

    private var weeklyFootprintSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(
                title: "本周社区足迹",
                trailing: weeklyHistoryCount == 0 ? nil : "\(weeklyHistoryCount) 个话题"
            )
            CardSection(padding: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    weeklyHistorySummary

                    weeklyHistoryChart

                    Text("同一话题按最近一次阅读日期计入，仅使用保存在本机的浏览历史。")
                        .font(.caption)
                        .lineSpacing(2)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var weeklyHistorySummary: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(weeklyHistoryCount.formatted()) 个话题")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(weeklyHistoryCount == 0 ? Theme.faint : Theme.ink)
                    .contentTransition(.numericText(value: Double(weeklyHistoryCount)))
                Label("过去 7 天", systemImage: "calendar")
                    .font(.body)
                    .foregroundStyle(Theme.muted)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(weeklyHistoryCount.formatted())
                    .font(.title2.weight(.bold))
                    .foregroundStyle(weeklyHistoryCount == 0 ? Theme.faint : Theme.ink)
                    .contentTransition(.numericText(value: Double(weeklyHistoryCount)))
                Text("个话题")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Label("过去 7 天", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private var weeklyHistoryChart: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    ForEach(weeklyHistory) { day in
                        let isToday = Calendar.autoupdatingCurrent.isDateInToday(day.date)
                        HStack(spacing: 12) {
                            Text(
                                isToday
                                    ? "今天"
                                    : day.date.formatted(.dateTime.weekday(.wide))
                            )
                            .foregroundStyle(isToday ? Theme.accent : Theme.body)
                            Spacer(minLength: 8)
                            Text("\(day.count.formatted()) 个话题")
                                .monospacedDigit()
                                .foregroundStyle(day.count == 0 ? Theme.faint : Theme.ink)
                        }
                        .font(.body)
                        .frame(minHeight: 44)
                    }
                }
            } else {
                weeklyHistoryBarChart
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("过去七天阅读足迹")
        .accessibilityValue(weeklyHistoryAccessibilityValue)
    }

    private var weeklyHistoryBarChart: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(weeklyHistory) { day in
                let isToday = Calendar.autoupdatingCurrent.isDateInToday(day.date)
                VStack(spacing: 6) {
                    Text(day.count.formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(day.count == 0 ? Theme.faint : Theme.body)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            day.count == 0
                                ? Theme.separator
                                : isToday ? Theme.accent : Theme.accent.opacity(0.48)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: weeklyBarHeight(for: day.count))

                    Text(day.date, format: .dateTime.weekday(.narrow))
                        .font(.caption2)
                        .foregroundStyle(isToday ? Theme.accent : Theme.muted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minHeight: 86, alignment: .bottom)
    }

    private func weeklyBarHeight(for count: Int) -> CGFloat {
        guard count > 0 else { return 4 }
        return max(8, 48 * CGFloat(count) / CGFloat(weeklyHistoryMaximum))
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "我的空间", trailing: libraryCount > 0 ? "\(libraryCount) 项" : nil)
            CardSection {
                libraryRow(
                    icon: "star",
                    count: favorites.topics.count,
                    title: "收藏",
                    caption: "喜欢的话题",
                    route: .favorites
                )
                RowSeparator(leadingInset: 68)

                libraryRow(
                    icon: "clock",
                    count: history.entries.count,
                    title: "浏览历史",
                    caption: "最近 \(HistoryStore.retentionDays) 天",
                    route: .history
                )
                RowSeparator(leadingInset: 68)

                libraryRow(
                    icon: "bookmark",
                    count: offline.bundles.count,
                    title: "稍后读",
                    caption: offline.bundles.isEmpty ? "离线资料库" : offline.formattedSize,
                    route: .offline
                )
                RowSeparator(leadingInset: 68)

                libraryRow(
                    icon: "doc.text",
                    count: model.recentTopics.count,
                    title: "我的话题",
                    caption: isConnected ? "最近发布" : "连接后查看",
                    route: .myPosts
                )
            }
        }
    }

    private func libraryRow(
        icon: String,
        count: Int,
        title: String,
        caption: String,
        route: Route
    ) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(count.formatted())
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(count == 0 ? Theme.faint : Theme.ink)
                    .contentTransition(.numericText(value: Double(count)))
                Chevron()
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Metric.cardPadding)
            .frame(minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
        .accessibilityLabel("\(title)，\(count.formatted()) 项，\(caption)")
    }

    // MARK: - Utilities

    private var utilitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "管理")
            CardSection {
                utilityRow(
                    icon: "waveform.path.ecg",
                    title: "关键词雷达",
                    subtitle: radar.rules.isEmpty ? "追踪关键词、节点和用户" : "\(radar.rules.count) 条规则正在追踪",
                    route: .radar
                )
                RowSeparator(leadingInset: 54)

                utilityRow(
                    icon: "checkmark.shield",
                    title: "内容与屏蔽",
                    subtitle: moderation.count == 0 ? "关键词、用户与举报记录" : "\(moderation.count) 条规则正在生效",
                    route: .blocked
                )
            }
        }
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
