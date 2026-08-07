import SwiftUI

struct ComposeView: View {
    @EnvironmentObject private var drafts: DraftStore
    @EnvironmentObject private var followed: FollowedNodesStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showNodePicker = false
    @State private var showDrafts = false
    @State private var showPublishNotice = false
    @FocusState private var focus: Field?

    private enum Field { case title, body }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                navBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        nodeRow
                        editorCard
                        formatBar
                        draftStatus
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Theme.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showNodePicker) {
            NodePickerView { name, title in
                drafts.draft.nodeName = name
                drafts.draft.nodeTitle = title
                drafts.save()
            }
        }
        .sheet(isPresented: $showDrafts) {
            DraftListView()
        }
        .alert("发布需要在网页完成", isPresented: $showPublishNotice) {
            Button("打开 V2EX") {
                openURL(URL(string: "https://www.v2ex.com/new/\(drafts.draft.nodeName)")!)
            }
            Button("好", role: .cancel) { }
        } message: {
            Text("V2EX 的 API 2.0 只提供读取接口，没有开放发帖。草稿已保存在本地，可以复制到网页发布。")
        }
        .onDisappear { drafts.save() }
    }

    private var navBar: some View {
        ZStack {
            Text("新话题")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)

            HStack {
                Button("取消") {
                    drafts.save()
                    dismiss()
                }
                .font(.system(size: 17))
                .foregroundStyle(Theme.accent)

                Spacer()

                Button {
                    showDrafts = true
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("管理草稿")

                Button {
                    drafts.save()
                    showPublishNotice = true
                } label: {
                    Text("发布")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(drafts.isEmpty ? Theme.accent.opacity(0.4) : Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(drafts.isEmpty)
            }
        }
        .padding(.horizontal, Theme.Metric.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: Theme.Metric.hairline)
        }
    }

    private var nodeRow: some View {
        CardSection {
            Button {
                showNodePicker = true
            } label: {
                HStack(spacing: 12) {
                    IdentitySquare(text: drafts.draft.nodeTitle, size: 30)
                    Text(drafts.draft.nodeTitle)
                        .font(.system(size: 17))
                        .kerning(-0.43)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text("更换节点")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                    Chevron()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.row)
        }
    }

    private var editorCard: some View {
        CardSection(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("标题", text: $drafts.draft.title, axis: .vertical)
                    .font(.system(size: 19, weight: .semibold))
                    .kerning(-0.4)
                    .lineSpacing(4)
                    .foregroundStyle(Theme.ink)
                    .focused($focus, equals: .title)

                Rectangle().fill(Theme.separator).frame(height: Theme.Metric.hairline)

                ZStack(alignment: .topLeading) {
                    if drafts.draft.body.isEmpty {
                        Text("正文（支持 Markdown）")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $drafts.draft.body)
                        .font(.system(size: 16))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 200)
                        .focused($focus, equals: .body)
                }
            }
        }
    }

    private var formatBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            GroupHeader(title: "格式")
            CardSection(padding: 12) {
                HStack(spacing: 10) {
                    formatButton(label: "B", weight: .bold) { wrap("**") }
                    formatButton(label: "I", italic: true) { wrap("*") }
                    formatButton(label: "</>", mono: true) { wrap("`") }
                    formatButton(label: "🔗") { insert("[标题](https://)") }
                    Spacer()
                    Text("支持 Markdown")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func formatButton(
        label: String,
        weight: Font.Weight = .regular,
        italic: Bool = false,
        mono: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(mono ? .system(size: 14, design: .monospaced) : .system(size: 16, weight: weight))
                .italic(italic)
                .foregroundStyle(Theme.body)
                .frame(width: 32, height: 32)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var draftStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Text("草稿已自动保存 · \(drafts.savedAtText)")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, Theme.Metric.headerPadding)
    }

    private func wrap(_ marker: String) {
        drafts.draft.body += "\(marker)文本\(marker)"
        drafts.save()
    }

    private func insert(_ text: String) {
        drafts.draft.body += text
        drafts.save()
    }
}

// MARK: - Draft list

private struct DraftListView: View {
    @EnvironmentObject private var drafts: DraftStore
    @Environment(\.dismiss) private var dismiss

    private var sortedDrafts: [DraftStore.Draft] {
        drafts.drafts.sorted { $0.savedAt > $1.savedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedDrafts) { draft in
                    Button {
                        drafts.select(draft.id)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(drafts.title(for: draft))
                                    .font(.headline)
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(2)
                                Text(draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? draft.nodeTitle
                                     : draft.body)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(2)
                                Text(draft.savedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 8)
                            if draft.id == drafts.activeID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            drafts.delete(draft.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("草稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        drafts.createDraft()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建草稿")
                }
            }
        }
    }
}

// MARK: - Node picker

struct NodePickerView: View {
    var onPick: (String, String) -> Void

    @StateObject private var model = NodesViewModel()
    @EnvironmentObject private var followed: FollowedNodesStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [V2Node] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return followed.names.map { name in
                model.node(named: name) ?? V2Node.stub(name: name, title: NodeCatalog.displayName(for: name))
            }
        }
        return Array(model.matches(for: trimmed).prefix(40))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { node in
                    Button {
                        onPick(node.name, node.title)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            IdentitySquare(text: node.title, size: 30, imageURL: node.avatarURL)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.title).foregroundStyle(Theme.ink)
                                Text(node.path)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索节点")
            .navigationTitle("选择节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await model.load() }
        }
    }
}
