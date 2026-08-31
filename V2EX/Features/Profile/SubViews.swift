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

// MARK: - 关键词雷达

@MainActor
private final class RadarViewModel: ObservableObject {
    @Published private(set) var topics: [V2Topic] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func load(rules: [RadarRule]) async {
        guard !rules.isEmpty else {
            topics = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var merged = (try? await V2EXClient.shared.latestTopics()) ?? []

        let nodeNames = uniqueValues(for: .node, in: rules)
        for name in nodeNames.prefix(5) {
            if let batch = try? await V2EXClient.shared.topics(inNode: name) {
                merged.append(contentsOf: batch)
            }
        }

        let members = uniqueValues(for: .member, in: rules)
        for username in members.prefix(5) {
            if let batch = try? await V2EXClient.shared.topics(byMember: username) {
                merged.append(contentsOf: batch)
            }
        }

        var seen = Set<Int>()
        topics = merged
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.lastTouched ?? $0.created ?? 0) > ($1.lastTouched ?? $1.created ?? 0) }

        if topics.isEmpty {
            errorMessage = "暂时没有读取到可供雷达匹配的话题"
        }
    }

    private func uniqueValues(for kind: RadarRuleKind, in rules: [RadarRule]) -> [String] {
        var seen = Set<String>()
        return rules.compactMap { rule in
            guard rule.kind == kind else { return nil }
            let key = rule.value.lowercased()
            return seen.insert(key).inserted ? rule.value : nil
        }
    }
}

struct RadarView: View {
    @StateObject private var model = RadarViewModel()
    @EnvironmentObject private var radar: RadarStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var moderation: ModerationStore

    @State private var kind: RadarRuleKind = .keyword
    @State private var draft = ""

    private var visibleTopics: [V2Topic] {
        moderation.filter(model.topics.filter { radar.matches($0) })
    }

    private var ruleSignature: String {
        radar.rules.map { "\($0.id):\($0.kind.rawValue):\($0.value)" }.joined(separator: "|")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ProfileCollectionHeader(
                    icon: "waveform.path.ecg",
                    count: visibleTopics.count,
                    title: "条命中",
                    message: radar.rules.isEmpty
                        ? "添加规则，主动追踪你关心的关键词、节点或用户。"
                        : "\(radar.rules.count) 条规则正在扫描公开话题。"
                )

                ruleEditor

                if radar.rules.isEmpty {
                    EmptyStateCard(
                        icon: "scope",
                        title: "创建第一条雷达规则",
                        message: "例如追踪“SwiftUI”、programmer 节点，或某位用户的新话题。"
                    )
                } else if model.isLoading && model.topics.isEmpty {
                    LoadingCard()
                } else if let errorMessage = model.errorMessage, visibleTopics.isEmpty {
                    EmptyStateCard(
                        icon: "waveform.path.ecg",
                        title: "暂时没有命中",
                        message: errorMessage,
                        actionTitle: "重新扫描"
                    ) {
                        Task { await model.load(rules: radar.rules) }
                    }
                } else if visibleTopics.isEmpty {
                    EmptyStateCard(
                        icon: "scope",
                        title: "暂时没有命中",
                        message: "雷达会保留规则；下次打开或下拉刷新时重新扫描。"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        GroupHeader(title: "雷达命中", trailing: "\(visibleTopics.count) 条")
                        TopicListCard(items: visibleTopics) { topic in
                            NavigationLink(value: Route.topic(topic.id)) {
                                radarTopicRow(topic)
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
        .navigationTitle("关键词雷达")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: ruleSignature) {
            await model.load(rules: radar.rules)
        }
        .pullToRefresh {
            await model.load(rules: radar.rules)
        }
    }

    private var ruleEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "追踪规则", trailing: radar.rules.isEmpty ? nil : "\(radar.rules.count) 条")
            CardSection {
                Picker("规则类型", selection: $kind) {
                    ForEach(RadarRuleKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.top, 12)

                HStack(spacing: 8) {
                    TextField(kind.placeholder, text: $draft)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .onSubmit(addRule)

                    Button(action: addRule) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("添加雷达规则")
                }
                .padding(12)

                if !radar.rules.isEmpty {
                    RowSeparator()
                    FlowLayout(spacing: 8) {
                        ForEach(radar.rules) { rule in
                            HStack(spacing: 7) {
                                Text("\(rule.kind.title) · \(rule.value)")
                                    .font(Type.meta(12))
                                    .foregroundStyle(Theme.ink)
                                Button {
                                    radar.remove(rule)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Theme.faint)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除 \(rule.value) 规则")
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, 7)
                            .frame(height: 34)
                            .background(Theme.inset, in: Capsule())
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func radarTopicRow(_ topic: V2Topic) -> some View {
        let matches = radar.matchingRules(for: topic)
        return VStack(alignment: .leading, spacing: 0) {
            TopicRow(topic: topic, isOffline: offline.isOffline(topic.id))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(matches) { rule in
                        Text(rule.value)
                            .font(Type.label(10))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.accentSoft, in: Capsule())
                    }
                }
                .padding(.horizontal, Theme.Metric.cardPadding)
            }
            .padding(.top, -8)
            .padding(.bottom, 11)
        }
    }

    private func addRule() {
        radar.add(kind: kind, value: draft)
        draft = ""
    }
}

// MARK: - 我的收藏

struct FavoritesView: View {
    private struct CollectionFilter: Hashable {
        let id: String?
        let title: String
    }

    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var session: V2EXSessionStore
    @EnvironmentObject private var moderation: ModerationStore
    @State private var reportTarget: ModerationTarget?
    @State private var organizerTopic: V2Topic?
    @State private var showsNewCollection = false
    @State private var selectedCollectionID: String?

    private var filters: [CollectionFilter] {
        [CollectionFilter(id: nil, title: "全部")] + favorites.collections.map {
            CollectionFilter(id: $0.id, title: $0.name)
        }
    }

    private var selectedFilter: CollectionFilter {
        filters.first(where: { $0.id == selectedCollectionID }) ?? filters[0]
    }

    private var visibleTopics: [V2Topic] {
        moderation.filter(favorites.topics(in: selectedCollectionID))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ProfileCollectionHeader(
                    icon: "star.fill",
                    count: visibleTopics.count,
                    title: "篇收藏",
                    message: session.isLoggedIn ? "已连接网页收藏；收藏夹、标签和备注保存在本机。" : "使用收藏夹、标签和备注整理本机内容。"
                )

                collectionRail

                if visibleTopics.isEmpty {
                    EmptyStateCard(
                        icon: "star",
                        title: selectedCollectionID == nil ? "还没有收藏" : "这个收藏夹还是空的",
                        message: "阅读话题时点右上角的星标，再长按收藏内容进行整理。"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        GroupHeader(title: selectedFilter.title, trailing: "\(visibleTopics.count) 篇")
                        TopicListCard(items: visibleTopics) { topic in
                            NavigationLink(value: Route.topic(topic.id)) {
                                favoriteTopicRow(topic)
                            }
                            .buttonStyle(.row)
                            .contextMenu {
                                Button {
                                    organizerTopic = topic
                                } label: {
                                    Label("整理收藏", systemImage: "folder")
                                }
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
        .sheet(item: $organizerTopic) { topic in
            FavoriteOrganizerSheet(topic: topic)
        }
        .sheet(isPresented: $showsNewCollection) {
            NewFavoriteCollectionSheet { id in
                selectedCollectionID = id
            }
        }
        .task {
            await favorites.syncFromRemote(cookie: session.cookie)
        }
        .pullToRefresh {
            await favorites.syncFromRemote(cookie: session.cookie, maxPages: 1)
        }
    }

    private var collectionRail: some View {
        ChipRail(
            items: filters,
            selected: selectedFilter,
            label: { filter in
                FilterChip(title: filter.title, isSelected: selectedCollectionID == filter.id) {
                    selectedCollectionID = filter.id
                }
                .id(filter)
                .contextMenu {
                    if let id = filter.id, id != FavoritesStore.inboxCollectionID {
                        Button(role: .destructive) {
                            favorites.removeCollection(id)
                            if selectedCollectionID == id { selectedCollectionID = nil }
                        } label: {
                            Label("删除收藏夹", systemImage: "trash")
                        }
                    }
                }
            }
        ) {
            Button {
                showsNewCollection = true
            } label: {
                Label("新建", systemImage: "folder.badge.plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .glassPill()
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private func favoriteTopicRow(_ topic: V2Topic) -> some View {
        let details = favorites.details(for: topic.id)
        return VStack(alignment: .leading, spacing: 0) {
            TopicRow(topic: topic, isOffline: offline.isOffline(topic.id))
            if !details.tags.isEmpty || !details.note.isEmpty {
                HStack(spacing: 6) {
                    ForEach(details.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(Type.label(10))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.accentSoft, in: Capsule())
                    }
                    if !details.note.isEmpty {
                        Image(systemName: "note.text")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .accessibilityLabel("有收藏备注")
                    }
                }
                .padding(.horizontal, Theme.Metric.cardPadding)
                .padding(.top, -7)
                .padding(.bottom, 11)
            }
        }
    }
}

private struct NewFavoriteCollectionSheet: View {
    let onCreated: (String) -> Void
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("用收藏夹把长期资料与临时关注分开。")
                    .font(Type.body(14))
                    .foregroundStyle(Theme.muted)
                TextField("收藏夹名称", text: $name)
                    .font(.system(size: 16))
                    .padding(.horizontal, 13)
                    .frame(height: 46)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button {
                    if let id = favorites.addCollection(named: name) {
                        onCreated(id)
                        dismiss()
                    }
                } label: {
                    Text("创建收藏夹")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(18)
            .background(Theme.canvas)
            .navigationTitle("新建收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct FavoriteOrganizerSheet: View {
    let topic: V2Topic
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.dismiss) private var dismiss
    @State private var collectionID = FavoritesStore.inboxCollectionID
    @State private var tagsText = ""
    @State private var note = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CardSection(padding: 16) {
                        Text(topic.title)
                            .font(Type.title(16))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        GroupHeader(title: "收藏夹")
                        CardSection {
                            Picker("收藏夹", selection: $collectionID) {
                                ForEach(favorites.collections) { collection in
                                    Text(collection.name).tag(collection.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        GroupHeader(title: "标签")
                        CardSection(padding: 14) {
                            TextField("用逗号分隔，例如 AI, 待评估", text: $tagsText)
                                .font(.system(size: 15))
                                .padding(.horizontal, 12)
                                .frame(height: 44)
                                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        GroupHeader(title: "备注")
                        CardSection(padding: 14) {
                            TextEditor(text: $note)
                                .font(.system(size: 15))
                                .frame(minHeight: 110)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .background(Theme.canvas)
            .navigationTitle("整理收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear { loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        let details = favorites.details(for: topic.id)
        collectionID = details.collectionID
        tagsText = details.tags.joined(separator: ", ")
        note = details.note
        loaded = true
    }

    private func save() {
        let tags = tagsText
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",")
            .map(String.init)
        favorites.organize(
            topicID: topic.id,
            collectionID: collectionID,
            tags: tags,
            note: note
        )
        dismiss()
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
    @EnvironmentObject private var session: V2EXSessionStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var moderation: ModerationStore
    @State private var topics: [V2Topic] = []
    @State private var isLoading = false
    @State private var username = ""
    @State private var errorMessage: String?

    private var visibleTopics: [V2Topic] { moderation.filter(topics) }

    /// 任一凭证都能定位「我自己」：token 走 API 2.0，网页会话直接有用户名。
    private var isConnected: Bool { token.hasToken || session.isLoggedIn }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ProfileCollectionHeader(
                    icon: "square.text.square.fill",
                    count: visibleTopics.count,
                    title: "篇话题",
                    message: username.isEmpty ? "连接账号后查看自己发布的内容。" : "@\(username) 最近发布的话题。"
                )

                if !isConnected {
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
        .task(id: token.token + "|" + session.username) { await load() }
        .pullToRefresh { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        guard isConnected else {
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
            // token 在手就问 API 2.0 要当前用户名；只有网页会话时登录流程
            // 已经把用户名存下来了，直接用。
            if token.hasToken {
                let member = try await V2EXClient.shared.currentMember(token: token.token)
                username = member.username
            } else {
                username = session.username
            }
            topics = try await V2EXClient.shared.topics(byMember: username)
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
