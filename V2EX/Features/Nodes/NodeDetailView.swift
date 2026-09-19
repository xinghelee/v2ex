import SwiftUI

@MainActor
final class NodeDetailViewModel: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable {
        case lastReply, newest, weeklyHot
        var id: String { rawValue }

        var title: String {
            switch self {
            case .lastReply: return "最新回复"
            case .newest: return "最新创建"
            case .weeklyHot: return "本周热议"
            }
        }
    }

    @Published private(set) var node: V2Node?
    @Published private(set) var topics: [V2Topic] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var sort: Sort = .lastReply

    private var raw: [V2Topic] = []
    @Published private(set) var page = 1
    @Published private(set) var reachedEnd = false
    @Published private(set) var moreError: String?

    var sorted: [V2Topic] {
        switch sort {
        case .lastReply:
            return raw.sorted { ($0.lastTouched ?? 0) > ($1.lastTouched ?? 0) }
        case .newest:
            // Website rows omit creation timestamps; topic IDs retain creation order.
            return raw.sorted { $0.id > $1.id }
        case .weeklyHot:
            let cutoff = Date().timeIntervalSince1970 - 7 * 86_400
            let recent = raw.filter { TimeInterval($0.lastTouched ?? 0) > cutoff }
            let pool = recent.isEmpty ? raw : recent
            return pool.sorted { $0.replies > $1.replies }
        }
    }

    func load(name: String, token: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        moreError = nil
        defer { isLoading = false }

        node = (try? await V2EXClient.shared.node(name: name))
            ?? V2Node.stub(name: name, title: NodeCatalog.displayName(for: name))

        do {
            // Both token API and public website support pagination.
            if !token.isEmpty {
                raw = try await V2EXClient.shared.nodeTopicsPaged(name: name, page: 1, token: token)
                page = 1
                reachedEnd = raw.isEmpty
            } else {
                let result = try await V2EXClient.shared.publicTopicPage(node: name, page: 1)
                raw = result.topics
                page = 1
                reachedEnd = !result.hasMore
            }
            topics = raw
        } catch {
            errorMessage = (error as? V2EXError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loadMore(name: String, token: String) async {
        guard !reachedEnd, !isLoading else { return }
        isLoading = true
        moreError = nil
        defer { isLoading = false }
        do {
            let next = page + 1
            let more: [V2Topic]
            if token.isEmpty {
                let result = try await V2EXClient.shared.publicTopicPage(node: name, page: next)
                more = result.topics
                reachedEnd = !result.hasMore
            } else {
                more = try await V2EXClient.shared.nodeTopicsPaged(name: name, page: next, token: token)
                reachedEnd = more.isEmpty
            }
            page = next
            var seen = Set(raw.map(\.id))
            raw.append(contentsOf: more.filter { seen.insert($0.id).inserted })
            topics = raw
        } catch {
            moreError = error.localizedDescription
        }
    }

}

struct NodeDetailView: View {
    let nodeName: String

    @StateObject private var model = NodeDetailViewModel()
    @EnvironmentObject private var followed: FollowedNodesStore
    @EnvironmentObject private var session: V2EXSessionStore
    @State private var followError: String?
    @EnvironmentObject private var token: TokenStore
    @EnvironmentObject private var readState: ReadStateStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var moderation: ModerationStore
    @Environment(\.openURL) private var openURL

    private var visibleTopics: [V2Topic] { moderation.filter(model.sorted) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                headerCard
                sortChips
                topicList
                if let error = model.moreError {
                    Text(error).font(.footnote).foregroundStyle(Theme.muted)
                    Button("重试加载更多") { Task { await model.loadMore(name: nodeName, token: token.token) } }
                } else if !model.topics.isEmpty && !model.reachedEnd {
                    ProgressView().frame(maxWidth: .infinity).padding()
                        .task(id: model.page) { await model.loadMore(name: nodeName, token: token.token) }
                } else if !model.topics.isEmpty {
                    Text("没有更多话题了").font(.footnote).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity).padding()
                }
            }
            .readableColumn()
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .pullToRefresh { await model.load(name: nodeName, token: token.token) }
        .background(Theme.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(model.node?.title ?? NodeCatalog.displayName(for: nodeName))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        openURL(URL(string: "https://www.v2ex.com/go/\(nodeName)")!)
                    } label: {
                        Label("在 V2EX 打开", systemImage: "safari")
                    }
                    Button {
                        toggleFollow()
                    } label: {
                        Label(
                            followed.isFollowing(nodeName) ? "取消关注" : "关注节点",
                            systemImage: followed.isFollowing(nodeName) ? "star.slash" : "star"
                        )
                    }
                    .disabled(followed.updatingNames.contains(nodeName))
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.body)
                }
            }
        }
        .task { await model.load(name: nodeName, token: token.token) }
        .alert("关注操作失败", isPresented: Binding(
            get: { followError != nil }, set: { if !$0 { followError = nil } }
        )) {
            Button("好", role: .cancel) { followError = nil }
        } message: {
            Text(followError ?? "")
        }
    }

    private var headerCard: some View {
        CardSection(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    IdentitySquare(
                        text: model.node?.title ?? nodeName,
                        size: 56,
                        imageURL: model.node?.avatarURL,
                        color: .clear,
                        fallbackForeground: Theme.accent
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.node?.title ?? NodeCatalog.displayName(for: nodeName))
                            .font(.system(size: 21, weight: .bold))
                            .kerning(-0.5)
                            .foregroundStyle(Theme.ink)
                        Text("/go/\(nodeName)")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    followButton
                }

                if let header = model.node?.header, !header.isEmpty {
                    Text(HTMLText.plain(header))
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 24) {
                    stat(value: model.node?.topics ?? 0, label: "话题")
                    stat(value: model.node?.stars ?? 0, label: "关注者")
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private var followButton: some View {
        let isFollowing = followed.isFollowing(nodeName)
        return Button {
            toggleFollow()
        } label: {
            HStack(spacing: 6) {
                if followed.updatingNames.contains(nodeName) {
                    ProgressView().controlSize(.small)
                        .tint(isFollowing ? Theme.accent : .white)
                }
                Text(isFollowing ? "已关注" : "关注")
            }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFollowing ? Theme.accent : Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isFollowing ? AnyShapeStyle(Theme.accentSoft) : AnyShapeStyle(Theme.accent))
                .clipShape(Capsule())
        }
        .buttonStyle(.row)
        .disabled(followed.updatingNames.contains(nodeName))
        .accessibilityHint(session.isLoggedIn ? "同步到 V2EX 收藏的节点" : "保存在本机，登录后可同步到 V2EX")
    }

    private func toggleFollow() {
        let following = !followed.isFollowing(nodeName)
        Task {
            do {
                try await followed.setFollowing(nodeName, following: following, session: session)
            } catch {
                followError = error.localizedDescription
            }
        }
    }

    private func stat(value: Int, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value.formatted())
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
    }

    private var sortChips: some View {
        ChipRail(items: NodeDetailViewModel.Sort.allCases, selected: model.sort) { sort in
            FilterChip(title: sort.title, isSelected: model.sort == sort) {
                withAnimation(.snappy) { model.sort = sort }
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var topicList: some View {
        if let message = model.errorMessage, visibleTopics.isEmpty {
            EmptyStateCard(icon: "wifi.exclamationmark", title: "没能加载", message: message)
        } else if model.isLoading && visibleTopics.isEmpty {
            LoadingCard()
        } else if visibleTopics.isEmpty {
            EmptyStateCard(icon: "tray", title: "这个节点还没有话题")
        } else {
            TopicListCard(items: visibleTopics) { topic in
                NavigationLink(value: Route.topic(topic.id)) {
                    TopicRow(
                        topic: topic,
                        showsNode: false,
                        isOffline: offline.isOffline(topic.id),
                        isRead: readState.isRead(topic.id),
                        dimRead: settings.dimReadTopics
                    )
                }
                .buttonStyle(.row)
            }
        }
    }
}
