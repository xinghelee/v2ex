import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case topics, replies, members, nodes
        var id: String { rawValue }

        var title: String {
            switch self {
            case .topics: return "话题"
            case .replies: return "回复"
            case .members: return "用户"
            case .nodes: return "节点"
            }
        }
    }

    @Published var query = ""
    @Published var scope: Scope = .topics
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var nodeResults: [V2Node] = []
    @Published private(set) var member: V2Member?
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasSearched = false

    private var allNodes: [V2Node] = []

    func loadNodes() async {
        guard allNodes.isEmpty else { return }
        allNodes = (try? await V2EXClient.shared.allNodes()) ?? []
    }

    func run() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hits = []; nodeResults = []; member = nil; hasSearched = false
            return
        }

        isSearching = true
        errorMessage = nil
        hasSearched = true
        defer { isSearching = false }

        switch scope {
        case .topics, .replies:
            do {
                // sov2ex is the community full-text index — V2EX has no search API.
                hits = try await V2EXClient.shared.search(
                    query: trimmed,
                    sort: scope == .topics ? "sumup" : "created"
                )
            } catch {
                errorMessage = "搜索服务暂时不可用（sov2ex）"
                hits = []
            }
        case .nodes:
            await loadNodes()
            nodeResults = allNodes.filter {
                $0.title.localizedCaseInsensitiveContains(trimmed)
                    || $0.name.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted { ($0.topics ?? 0) > ($1.topics ?? 0) }
        case .members:
            member = try? await V2EXClient.shared.member(username: trimmed)
            if member == nil { errorMessage = "没有找到用户 \(trimmed)" }
        }
    }
}

struct SearchView: View {
    let request: SearchOpenRequest

    @StateObject private var model = SearchViewModel()
    @EnvironmentObject private var recents: RecentSearchStore
    @EnvironmentObject private var moderation: ModerationStore
    @State private var reportTarget: ModerationTarget?
    @FocusState private var searchFocused: Bool

    var body: some View {
        results
            .background(Theme.canvas)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            // iPad 上系统默认的 searchable 把搜索框缩在导航栏右侧，很怪；
            // 用 drawer 模式让搜索框全宽居中，和节点页一致。
            .searchable(
                text: $model.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "话题、回复、用户或节点"
            )
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { submit() }
            .onChange(of: model.scope) {
                Task { await model.run() }
            }
            .onChange(of: model.query) { _, query in
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task { await model.run() }
                }
            }
            .onAppear {
                guard request.query == nil else { return }
                DispatchQueue.main.async { searchFocused = true }
            }
            .task(id: request.id) {
                guard let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !query.isEmpty else { return }
                model.query = query
                recents.record(query)
                searchFocused = false
                await model.run()
            }
            .sheet(item: $reportTarget) { ReportSheet(target: $0) }
    }

    @ViewBuilder
    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                // scope 选择器自己画：系统 searchScopes 在 iPad drawer
                // 模式下不渲染，换成首页分类栏同款 chips，各端一致。
                scopeBar

                if model.isSearching {
                    LoadingCard()
                } else if let message = model.errorMessage {
                    EmptyStateCard(icon: "magnifyingglass", title: "没有结果", message: message)
                } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !model.hasSearched {
                    // 首屏空态：搜索框聚焦着但还没输入，别让整页空白得
                    // 像没加载出来，放一句引导。
                    EmptyStateCard(
                        icon: "magnifyingglass",
                        title: "搜索 V2EX 社区",
                        message: "输入关键词，搜索话题、回复、用户或节点。索引来自 sov2ex。"
                    )
                } else {
                    switch model.scope {
                    case .topics, .replies: hitList
                    case .nodes: nodeList
                    case .members: memberResult
                    }
                }

                if !recents.queries.isEmpty && !model.hasSearched {
                    recentSearches
                }
            }
            .readableColumn()
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    /// 话题 / 回复 / 用户 / 节点 四个搜索域，chips 形式。
    private var scopeBar: some View {
        ChipRail(items: SearchViewModel.Scope.allCases, selected: model.scope) { scope in
            FilterChip(title: scope.title, isSelected: model.scope == scope) {
                model.scope = scope
            }
            .id(scope)
        }
    }

    /// 屏蔽与举报同样作用于搜索结果 —— 漏了这里，被屏蔽的人搜一下就又
    /// 回来了。
    private var visibleHits: [SearchHit] {
        model.hits.filter { hit in
            !moderation.hiddenTopicIDs.contains(hit.id)
                && !moderation.isBlocked(username: hit.member)
                && !moderation.matchesKeyword(hit.title + " " + hit.content)
        }
    }

    @ViewBuilder
    private var hitList: some View {
        let hits = visibleHits
        if hits.isEmpty {
            if model.hasSearched {
                EmptyStateCard(icon: "magnifyingglass", title: "没有匹配的内容")
            }
        } else {
            CardSection {
                ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                    NavigationLink(value: Route.topic(hit.id)) {
                        hitRow(hit)
                    }
                    .buttonStyle(.row)
                    .contextMenu {
                        ModerationMenuItems(
                            target: .topic(id: hit.id, author: hit.member, excerpt: hit.title),
                            onReport: { reportTarget = $0 }
                        )
                    }
                    if index < hits.count - 1 {
                        RowSeparator()
                    }
                }
            }
        }
    }

    private func hitRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HighlightedText(segments: hit.titleSegments, size: 16, weight: .medium)
            HighlightedText(segments: hit.contentSegments, size: 14, weight: .regular, muted: true)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(NodeCatalog.displayName(for: hit.node))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text("·").font(.system(size: 12)).foregroundStyle(Theme.faint)
                Text("\(hit.member) · \(hit.replies) 回复")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var nodeList: some View {
        if model.nodeResults.isEmpty {
            if model.hasSearched { EmptyStateCard(icon: "square.grid.2x2", title: "没有匹配的节点") }
        } else {
            CardSection {
                ForEach(Array(model.nodeResults.prefix(30).enumerated()), id: \.element.id) { index, node in
                    NavigationLink(value: Route.node(node.name)) {
                        HStack(spacing: 12) {
                            IdentitySquare(text: node.title, size: 30, imageURL: node.avatarURL)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.title).font(.system(size: 17)).foregroundStyle(Theme.ink)
                                Text(node.path).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Chevron()
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.row)
                    if index < min(model.nodeResults.count, 30) - 1 { RowSeparator(leadingInset: 58) }
                }
            }
        }
    }

    @ViewBuilder
    private var memberResult: some View {
        if let member = model.member {
            NavigationLink(value: Route.member(member.username)) {
                CardSection(padding: 18) {
                    HStack(spacing: 14) {
                        IdentitySquare(text: member.username, size: 56, imageURL: member.avatarURL)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(member.username)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.ink)
                            if let tagline = member.tagline, !tagline.isEmpty {
                                Text(tagline).font(.system(size: 13)).foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer()
                        Chevron()
                    }
                }
            }
            .buttonStyle(.row)
        } else if model.hasSearched {
            EmptyStateCard(icon: "person", title: "没有找到用户")
        }
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "最近搜索", trailing: "清空") { recents.clear() }
            CardSection {
                ForEach(Array(recents.queries.enumerated()), id: \.element) { index, query in
                    HStack(spacing: 10) {
                        Image(systemName: "clock")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                        Text(query)
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Button {
                            recents.remove(query)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.faint)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.query = query
                        submit()
                    }
                    if index < recents.queries.count - 1 { RowSeparator(leadingInset: 41) }
                }
            }
        }
    }

    private func submit() {
        recents.record(model.query)
        searchFocused = false
        Task { await model.run() }
    }
}

/// Paints sov2ex's `<em>` runs with the design's yellow highlight.
struct HighlightedText: View {
    let segments: [HighlightSegment]
    var size: CGFloat
    var weight: Font.Weight = .regular
    var muted = false

    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            piece.foregroundColor = muted ? Theme.muted : Theme.ink
            if segment.isMatch {
                piece.backgroundColor = Theme.searchHighlight
                piece.foregroundColor = Theme.ink
            }
            result += piece
        }
        return result
    }

    var body: some View {
        Text(attributed)
            .font(.system(size: size, weight: weight))
            .kerning(muted ? 0 : -0.3)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
