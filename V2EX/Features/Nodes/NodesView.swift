import SwiftUI

@MainActor
final class NodesViewModel: ObservableObject {
    @Published private(set) var allNodes: [V2Node] = []
    @Published private(set) var isLoading = false
    @Published var query = ""

    private var byName: [String: V2Node] = [:]

    var nodeCount: Int { allNodes.count }

    var searchResults: [V2Node] {
        matches(for: query)
    }

    func matches(for term: String) -> [V2Node] {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return allNodes.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.titleAlternative ?? "").localizedCaseInsensitiveContains(trimmed)
        }
        .sorted { ($0.topics ?? 0) > ($1.topics ?? 0) }
    }

    func node(named name: String) -> V2Node? { byName[name] }

    /// How many of a category's members actually exist in the live node list.
    func count(for category: NodeCatalog.Category) -> Int {
        guard !byName.isEmpty else { return category.members.count }
        return category.members.filter { byName[$0] != nil }.count
    }

    func nodes(in category: NodeCatalog.Category) -> [V2Node] {
        category.members.compactMap { byName[$0] }
    }

    func load() async {
        guard allNodes.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        guard let nodes = try? await V2EXClient.shared.allNodes() else { return }
        allNodes = nodes
        byName = Dictionary(nodes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        NodeCatalog.register(nodes: nodes)
    }
}

struct NodesView: View {

    @StateObject private var model = NodesViewModel()
    @EnvironmentObject private var followed: FollowedNodesStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditingFollowed = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        content
            .background(Theme.canvas)
            .navigationTitle("节点")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $model.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: model.nodeCount > 0 ? "搜索 \(model.nodeCount.formatted()) 个节点" : "搜索节点"
            )
            .searchFocused($isSearchFocused)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if reduceMotion {
                            isEditingFollowed.toggle()
                        } else {
                            withAnimation(.snappy(duration: 0.24)) { isEditingFollowed.toggle() }
                        }
                    } label: {
                        Image(systemName: isEditingFollowed ? "checkmark" : "pencil")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(isEditingFollowed ? "完成编辑" : "编辑关注节点")
                }
            }
            .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !model.query.isEmpty {
                    searchResults
                } else {
                    followedSection
                    categoriesSection
                }
            }
            .readableColumn()
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .softBottomEdgeEffect()
        .scrollDismissesKeyboard(.immediately)
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "\(model.searchResults.count) 个结果")
            if model.searchResults.isEmpty {
                EmptyStateCard(icon: "magnifyingglass", title: "没有匹配的节点")
            } else {
                CardSection {
                    ForEach(Array(model.searchResults.prefix(40).enumerated()), id: \.element.id) { index, node in
                        NavigationLink(value: Route.node(node.name)) {
                            nodeRow(node)
                        }
                        .buttonStyle(.row)
                        if index < min(model.searchResults.count, 40) - 1 {
                            RowSeparator(leadingInset: 58)
                        }
                    }
                }
            }
        }
    }

    private var followedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(
                title: "我关注的",
                trailing: followed.names.isEmpty ? nil : "\(followed.names.count) 个"
            )
            LazyVGrid(columns: followedColumns, alignment: .leading, spacing: 10) {
                ForEach(followed.names, id: \.self) { name in
                    followedNodeCell(name)
                }
                if !isEditingFollowed {
                    addFollowedNodeCell
                }
            }
            .padding(.horizontal, Theme.Metric.screenPadding)
        }
    }

    private var followedColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(
            repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
            count: count
        )
    }

    @ViewBuilder
    private func followedNodeCell(_ name: String) -> some View {
        let node = model.node(named: name)
        let title = node?.title ?? NodeCatalog.displayName(for: name)

        if isEditingFollowed {
            followedNodeCard(name: name, title: title, node: node, isEditing: true)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
        } else {
            NavigationLink(value: Route.node(name)) {
                followedNodeCard(name: name, title: title, node: node, isEditing: false)
            }
            .buttonStyle(.row)
            .accessibilityLabel("打开 \(title) 节点")
            .accessibilityHint(followedNodeAccessibilitySummary(name: name, node: node))
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    private func followedNodeCard(
        name: String,
        title: String,
        node: V2Node?,
        isEditing: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                IdentitySquare(
                    text: title,
                    size: 34,
                    imageURL: node?.avatarURL,
                    color: .clear
                )
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isEditing {
                    Button {
                        removeFollowedNode(name)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.unreadDot)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消关注 \(title)")
                    .accessibilityHint("从我关注的节点中移除")
                    .offset(x: 8, y: -8)
                }
            }

            Text(followedNodeSummary(name: name, node: node))
                .font(.subheadline)
                .lineSpacing(2)
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)

            HStack(spacing: 6) {
                if let topics = node?.topics {
                    Label("\(topics.formatted()) 个话题", systemImage: "text.bubble")
                        .lineLimit(1)
                } else {
                    Label("正在同步资料", systemImage: "arrow.triangle.2.circlepath")
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !isEditing {
                    Chevron()
                        .accessibilityHidden(true)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.faint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: Theme.Metric.hairline)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func removeFollowedNode(_ name: String) {
        if reduceMotion {
            followed.remove(name)
        } else {
            withAnimation(.snappy(duration: 0.2)) { followed.remove(name) }
        }
    }

    private var addFollowedNodeCell: some View {
        Button {
            model.query = ""
            isSearchFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)

                Text("添加关注")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("搜索全部节点")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        Theme.faint,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.row)
        .accessibilityLabel("添加关注节点")
        .accessibilityHint("聚焦节点搜索")
    }

    private func followedNodeSummary(name: String, node: V2Node?) -> String {
        if let header = node?.header {
            let summary = HTMLText.plain(header)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty { return summary }
        }
        return "/go/\(name)"
    }

    private func followedNodeAccessibilitySummary(name: String, node: V2Node?) -> String {
        var parts = [followedNodeSummary(name: name, node: node)]
        if let topics = node?.topics {
            parts.append("累计 \(topics.formatted()) 个话题")
        }
        return parts.joined(separator: "，")
    }

    /// iPad 上分类目录排成两列，iPhone 保持单列；行末与列尾的单元格
    /// 不带分隔线，线只在相邻单元格之间出现。
    private var categoryColumns: [GridItem] {
        horizontalSizeClass == .regular
            ? [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)]
            : [GridItem(.flexible(), spacing: 0)]
    }

    private var categoriesSection: some View {
        let categories = NodeCatalog.categories
        let columns = categoryColumns.count
        // 最后一行从哪开始：总数对列数取余（整除时从倒数第 columns 个开始）。
        let remainder = categories.count % columns
        let lastRowStart = categories.count - (remainder == 0 ? columns : remainder)
        return VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "全部分类")
            CardSection {
                LazyVGrid(columns: categoryColumns, spacing: 0) {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        NavigationLink(value: Route.nodeCategory(category.id)) {
                            categoryRow(category)
                        }
                        .buttonStyle(.row)
                        .overlay(alignment: .bottom) {
                            if index < lastRowStart {
                                Rectangle()
                                    .fill(Theme.separator)
                                    .frame(height: Theme.Metric.hairline)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            if columns == 2, index % 2 == 0, index < categories.count - 1 {
                                Rectangle()
                                    .fill(Theme.separator)
                                    .frame(width: Theme.Metric.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private func categoryRow(_ category: NodeCatalog.Category) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accentSoft)
                Image(systemName: category.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title)
                    .font(.system(size: 17))
                    .kerning(-0.43)
                    .foregroundStyle(Theme.ink)
                Text(NodeCatalog.subtitle(for: category))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(model.count(for: category))")
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
            Chevron()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }

    private func nodeRow(_ node: V2Node) -> some View {
        HStack(spacing: 12) {
            IdentitySquare(text: node.title, size: 30, imageURL: node.avatarURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(.system(size: 17))
                    .kerning(-0.43)
                    .foregroundStyle(Theme.ink)
                Text(node.path)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            if let topics = node.topics {
                Text("\(topics)")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
            }
            Chevron()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }
}

// MARK: - Category detail

/// A category row represents a collection, so it opens the collection instead
/// of silently jumping to its first node. The API has no category endpoint;
/// this view resolves the catalog's member names against the live all-nodes
/// response and keeps readable stubs available while offline.
struct NodeCategoryView: View {
    let category: NodeCatalog.Category

    @StateObject private var model = NodesViewModel()

    private var categoryNodes: [V2Node] {
        let live = model.nodes(in: category)
        guard live.isEmpty else { return live }
        return category.members.map {
            V2Node.stub(name: $0, title: NodeCatalog.displayName(for: $0))
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                categoryHeader

                VStack(alignment: .leading, spacing: 0) {
                    GroupHeader(title: "节点", trailing: "\(categoryNodes.count) 个")
                    CardSection {
                        ForEach(Array(categoryNodes.enumerated()), id: \.element.id) { index, node in
                            NavigationLink(value: Route.node(node.name)) {
                                nodeRow(node)
                            }
                            .buttonStyle(.row)

                            if index < categoryNodes.count - 1 {
                                RowSeparator(leadingInset: 62)
                            }
                        }
                    }
                }
            }
            .readableColumn()
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private var categoryHeader: some View {
        CardSection(padding: 18) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Theme.accentSoft)
                    Image(systemName: category.icon)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text(NodeCatalog.subtitle(for: category))
                        .font(Type.meta(13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
        }
    }

    private func nodeRow(_ node: V2Node) -> some View {
        HStack(spacing: 12) {
            IdentitySquare(text: node.title, size: 34, imageURL: node.avatarURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text("/go/\(node.name)")
                    .font(Type.meta(12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            if let topics = node.topics {
                Text(topics.formatted())
                    .font(Type.number(14, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            Chevron()
        }
        .padding(.horizontal, Theme.Metric.cardPadding)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

// MARK: - Flow layout

/// Wrapping chip layout for the followed-node cloud.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > maxWidth {
                origin.x = 0
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalHeight = origin.y + rowHeight
        }
        return CGSize(width: maxWidth == .infinity ? origin.x : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
