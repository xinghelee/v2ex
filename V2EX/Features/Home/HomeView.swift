import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    enum Feed: Hashable {
        case all
        case following
        case hot
        case node(name: String, title: String)
        /// 唯一的非 V2EX 数据源：自成一页，不与本站内容混排。
        case hackerNews

        var title: String {
            switch self {
            case .all: return "全部"
            case .following: return "关注"
            case .hot: return "最热"
            case .node(_, let title): return title
            case .hackerNews: return "HN"
            }
        }
    }

    @Published var feed: Feed = .all
    @Published private(set) var topics: [V2Topic] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var cache: [Feed: [V2Topic]] = [:]

    /// 关注 merges the newest topics of every followed node into one stream.
    func load(feed: Feed, followedNodes: [String], force: Bool = false) async {
        self.feed = feed

        if !force, let cached = cache[feed], !cached.isEmpty {
            topics = cached
            return
        }

        // Never show the previous category's rows under a newly selected chip
        // while its request is in flight. A brief, honest loading state is less
        // disorienting than content that changes identity a moment later.
        if !force { topics = [] }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result: [V2Topic]
            switch feed {
            case .all:
                result = try await V2EXClient.shared.latestTopics()
            case .hot:
                result = try await V2EXClient.shared.hotTopics()
            case .node(let name, _):
                result = try await V2EXClient.shared.topics(inNode: name)
            case .following:
                result = try await followingFeed(nodes: followedNodes)
            case .hackerNews:
                // HN 页自己取数，不经过这里的 V2EX 管道。
                return
            }
            cache[feed] = result
            // A newer selection may have landed while this request was in flight —
            // don't let a stale response clobber the page the user is looking at.
            guard self.feed == feed else { return }
            topics = result
        } catch {
            guard self.feed == feed else { return }
            errorMessage = (error as? V2EXError)?.errorDescription ?? error.localizedDescription
            topics = cache[feed] ?? []
        }
    }

    /// 明显的推广/广告信号词。命中则从首页 feed 隐藏——V2EX 的最新流里
    /// 偶尔会混入“免费送/邀请码/住宅 IP”这类推广帖，它们不该占首页版面。
    private static let promotionSignals = [
        "邀请码", "免费送", "动态住宅", "住宅 ip", "住宅ip", "流量用不完", "注册送", "返利",
    ]

    static func isPromotion(_ topic: V2Topic) -> Bool {
        let haystack = "\(topic.title) \(topic.authorName)".lowercased()
        return promotionSignals.contains { haystack.contains($0) }
    }

    private func followingFeed(nodes: [String]) async throws -> [V2Topic] {
        guard !nodes.isEmpty else { return try await V2EXClient.shared.latestTopics() }

        var merged: [V2Topic] = []
        // Sequential rather than parallel: v1 has a shared 600/hour IP budget and
        // hammering it from a cold launch is the fastest way to get throttled.
        for name in nodes.prefix(6) {
            if let batch = try? await V2EXClient.shared.topics(inNode: name) {
                merged.append(contentsOf: batch)
            }
        }
        if merged.isEmpty { return try await V2EXClient.shared.latestTopics() }

        var seen = Set<Int>()
        return merged
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.lastTouched ?? 0) > ($1.lastTouched ?? 0) }
    }
}

struct HomeView: View {
    let request: HomeOpenRequest
    var onCompose: () -> Void

    @StateObject private var model = HomeViewModel()
    @EnvironmentObject private var followed: FollowedNodesStore
    @EnvironmentObject private var moderation: ModerationStore
    @EnvironmentObject private var readState: ReadStateStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var settings: AppSettings

    /// Per-feed scroll offsets, so swiping between categories doesn't lose your place.
    @State private var scrollPositions: [HomeViewModel.Feed: ScrollPosition] = [:]
    /// 正在被长按拖起的分类 chip（用于关注节点排序）。
    @State private var draggedFeed: HomeViewModel.Feed?

    private var feeds: [HomeViewModel.Feed] {
        [.all, .hot, .following] + followed.names.prefix(8).map {
            .node(name: $0, title: NodeCatalog.displayName(for: $0))
        } + (showsHackerNewsChip ? [.hackerNews] : [])
    }

    /// 放进底部标签时就不再占分类条，否则同一个页面会有两个入口。
    private var showsHackerNewsChip: Bool {
        settings.hackerNewsEnabled && settings.hackerNewsPlacement == .feed
    }

    private var visibleTopics: [V2Topic] {
        moderation.filter(model.topics).filter { !HomeViewModel.isPromotion($0) }
    }

    var body: some View {
        // One page per feed: swipe left/right to change category, the chip rail
        // above stays in sync through the shared `model.feed` selection.
        TabView(selection: $model.feed) {
            ForEach(feeds, id: \.self) { feed in
                feedPage(feed)
                    .tag(feed)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Let the feed scroll under the floating tab bar instead of stopping above it.
        .ignoresSafeArea(edges: .bottom)
        .background(Theme.canvas)
        .navigationTitle("V2EX")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .topSafeAreaBar(spacing: 0) { feedFilterBar }
        .task(id: request.id) {
            if model.feed == request.feed {
                await model.load(feed: request.feed, followedNodes: followed.names)
            } else {
                // `onChange` owns the load after switching feeds, avoiding a
                // duplicate request when Siri opens 今日最热.
                model.feed = request.feed
            }
        }
        .onChange(of: model.feed) { _, newFeed in
            Task { await model.load(feed: newFeed, followedNodes: followed.names) }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onCompose) {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("发布话题")
        }
    }

    private var feedFilterBar: some View {
        ChipRail(items: feeds, selected: model.feed) { feed in
            FilterChip(title: feed.title, isSelected: model.feed == feed) {
                model.feed = feed
            }
            .id(feed)
            // 长按关注节点 chip 可拖动排序（固定项「全部/最热/关注」
            // 不可拖，但可以作为落点参照）。顺序写回 followed.names 并持久化。
            // preview 自定义为胶囊：glassEffect 视图的拖拽快照会丢圆角变方形。
            .onDrag {
                guard feed.isReorderable else { return NSItemProvider() }
                draggedFeed = feed
                return NSItemProvider(object: feed.title as NSString)
            } preview: {
                Text(feed.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.accent))
            }
            .onDrop(of: [.text], delegate: FeedChipDropDelegate(
                target: feed,
                dragged: draggedFeed,
                onMove: moveFeed
            ))
        }
        .readableColumn()
    }

    /// 把被拖起的节点 chip 插到目标 chip 的位置。只处理节点对节点；
    /// 拖到固定项上由 delegate 直接忽略。
    private func moveFeed(to target: HomeViewModel.Feed) {
        guard let dragged = draggedFeed, dragged != target else { return }
        guard case .node(let draggedName, _) = dragged,
              case .node(let targetName, _) = target else { return }
        guard let from = followed.names.firstIndex(of: draggedName),
              let to = followed.names.firstIndex(of: targetName), from != to else { return }
        withAnimation(.snappy(duration: 0.25)) {
            followed.move(from: IndexSet(integer: from), to: to)
        }
    }

    @ViewBuilder
    private func feedPage(_ feed: HomeViewModel.Feed) -> some View {
        if feed == .hackerNews {
            // 数据模型和 V2EX 完全不同（无节点、无附言、评论是嵌套树），
            // 所以自成一页而不是塞进上面的话题列表。
            HackerNewsView()
        } else {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let message = model.errorMessage, visibleTopics.isEmpty {
                    EmptyStateCard(icon: "wifi.exclamationmark", title: "没能加载", message: message,
                                   actionTitle: "重试") {
                        Task { await model.load(feed: feed, followedNodes: followed.names, force: true) }
                    }
                } else if model.isLoading && visibleTopics.isEmpty {
                    LoadingCard()
                } else if visibleTopics.isEmpty {
                    EmptyStateCard(icon: "tray", title: "这里还没有话题")
                } else {
                    // The public feed opens with a compact live map of where
                    // the current conversation is concentrated. It makes the
                    // first screen recognisably v2Explore without changing the
                    // familiar topic-list interaction below.
                    if feed == .all, settings.communityPulseEnabled {
                        CommunityPulseCard(topics: visibleTopics)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Lead card, then the rest as a grouped list — as in the design.
                    if let featured = visibleTopics.first {
                        NavigationLink(value: Route.topic(featured.id)) {
                            CardSection(padding: 16) {
                                FeaturedTopicCard(
                                    topic: featured,
                                    badge: feed == .hot ? "今日最热" : "最新活跃"
                                )
                            }
                        }
                        .buttonStyle(.row)
                        // CardSection insets its content by 16 on top of the
                        // screen padding, so the corner sits further in here.
                        .promotionBadge(
                            for: featured,
                            trailing: Theme.Metric.screenPadding + 16,
                            top: 16
                        )
                    }

                    TopicListCard(items: Array(visibleTopics.dropFirst())) { topic in
                        NavigationLink(value: Route.topic(topic.id)) {
                            TopicRow(
                                topic: topic,
                                isOffline: offline.isOffline(topic.id),
                                isRead: readState.isRead(topic.id),
                                dimRead: settings.dimReadTopics
                            )
                        }
                        .buttonStyle(.row)
                        .promotionBadge(for: topic)
                    }
                }
            }
            .readableColumn()
            .padding(.top, 10)
            // Room for the floating tab bar + home indicator at the bottom.
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
        .softBottomEdgeEffect()
        .pullToRefresh(isEnabled: model.feed == feed) {
            await model.load(feed: feed, followedNodes: followed.names, force: true)
        }
        .scrollPosition(scrollBinding(for: feed))
        }
    }

    private func scrollBinding(for feed: HomeViewModel.Feed) -> Binding<ScrollPosition> {
        Binding(
            get: { scrollPositions[feed] ?? ScrollPosition() },
            set: { scrollPositions[feed] = $0 }
        )
    }
}

// MARK: - Community pulse

private struct CommunityPulseCard: View {
    private struct Signal: Identifiable {
        let name: String
        let title: String
        let topicCount: Int
        let replies: Int
        var id: String { name }
        var score: Int { replies + topicCount * 2 }
    }

    let topics: [V2Topic]
    @EnvironmentObject private var radar: RadarStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var signals: [Signal] {
        var buckets: [String: (title: String, topics: Int, replies: Int)] = [:]
        for topic in topics.prefix(30) {
            guard let node = topic.node, !node.name.isEmpty else { continue }
            var bucket = buckets[node.name] ?? (node.title, 0, 0)
            bucket.topics += 1
            bucket.replies += topic.replies
            buckets[node.name] = bucket
        }
        let mapped: [Signal] = buckets.map { entry in
            let name = entry.key
            let value = entry.value
            return Signal(
                name: name,
                title: value.title,
                topicCount: value.topics,
                replies: value.replies
            )
        }
        let sorted = mapped.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.title < rhs.title }
            return lhs.score > rhs.score
        }
        return Array(sorted.prefix(3))
    }

    private var maxScore: Int { max(signals.map(\.score).max() ?? 1, 1) }
    private var sampledTopicCount: Int { min(topics.count, 30) }
    private var sampledReplyCount: Int { topics.prefix(30).reduce(0) { $0 + $1.replies } }

    var body: some View {
        CardSection(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("社区脉搏")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.ink)
                        Text("当前讨论集中在哪里")
                            .font(Type.meta(11))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    NavigationLink(value: Route.radar) {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 14, weight: .medium))
                            Text(radar.rules.isEmpty ? "雷达" : "雷达 \(radar.rules.count)")
                                .font(Type.meta(11))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                        .glassPill()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开关键词雷达，\(radar.rules.count) 条规则")
                }

                VStack(spacing: 8) {
                    ForEach(signals) { signal in
                        NavigationLink(value: Route.node(signal.name)) {
                            HStack(spacing: 10) {
                                Text(signal.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.body)
                                    .lineLimit(1)
                                    .frame(width: 68, alignment: .leading)

                                GeometryReader { proxy in
                                    let progress = CGFloat(signal.score) / CGFloat(maxScore)
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Theme.inset)
                                        Capsule()
                                            .fill(Theme.accent.opacity(0.28))
                                            .frame(width: max(10, proxy.size.width * progress))
                                        Circle()
                                            .fill(Theme.accent)
                                            .frame(width: 7, height: 7)
                                            .offset(x: max(3, proxy.size.width * progress - 7))
                                    }
                                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: progress)
                                }
                                .frame(height: 7)

                                Text("\(signal.replies)")
                                    .font(Type.number(12, weight: .medium))
                                    .foregroundStyle(Theme.muted)
                                    .frame(minWidth: 28, alignment: .trailing)
                            }
                            .frame(minHeight: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.row)
                        .accessibilityLabel(
                            "\(signal.title)，\(signal.topicCount) 个话题，\(signal.replies) 条回复"
                        )
                    }
                }

                Text("采样 \(sampledTopicCount) 个话题 · \(sampledReplyCount) 条回复")
                    .font(Type.meta(10))
                    .foregroundStyle(Theme.faint)
            }
        }
    }
}

extension HomeViewModel.Feed {
    /// 固定项（全部/最热/关注/HN）不可拖，只有关注节点参与排序。
    var isReorderable: Bool {
        if case .node = self { return true }
        return false
    }
}

/// 首页分类 chip 的拖动落点：被拖起的节点 chip 进入某个可排序 chip 时，
/// 把它插到目标 chip 的位置（由 onMove 执行）。固定项作为落点时直接忽略。
private struct FeedChipDropDelegate: DropDelegate {
    let target: HomeViewModel.Feed
    let dragged: HomeViewModel.Feed?
    let onMove: (HomeViewModel.Feed) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target, target.isReorderable else { return }
        onMove(target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool { true }
}
