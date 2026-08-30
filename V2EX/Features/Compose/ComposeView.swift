import SwiftUI
import UIKit

struct ComposeView: View {
    /// Called with the new topic's id so the caller can push it.
    var onPublished: ((Int) -> Void)? = nil

    @EnvironmentObject private var drafts: DraftStore
    @EnvironmentObject private var followed: FollowedNodesStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @EnvironmentObject private var session: V2EXSessionStore

    @State private var showNodePicker = false
    @State private var showDrafts = false
    @State private var showPublishNotice = false
    @State private var isPublishing = false
    @State private var publishError: String?
    @State private var showPublishError = false
    @FocusState private var focus: Field?

    private enum Field { case title, body }

    private var webComposeURL: URL {
        URL(string: "https://www.v2ex.com/write?node=\(drafts.draft.nodeName)")!
    }

    @MainActor
    private func publish() async {
        guard !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }

        do {
            let id = try await V2EXClient.shared.createTopic(
                title: drafts.draft.title,
                content: drafts.draft.body,
                nodeName: drafts.draft.nodeName,
                cookie: session.cookie,
                username: session.username
            )
            // 只有确认拿到新帖 id 才删草稿 —— 任何不确定的结果都必须把
            // 用户写的字留在原地。
            drafts.delete(drafts.activeID)
            dismiss()
            onPublished?(id)
        } catch {
            publishError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showPublishError = true
        }
    }

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
                    .readableColumn()
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
        .alert("发布需要先登录", isPresented: $showPublishNotice) {
            Button("打开 V2EX 网页并复制正文") {
                UIPasteboard.general.string = drafts.draft.body
                openURL(webComposeURL)
            }
            Button("好", role: .cancel) { }
        } message: {
            Text("在设置里完成 V2EX 登录后即可直接在 app 内发布。也可以现在去网页发——正文会复制到剪贴板，到网页长按粘贴即可。")
        }
        .alert("没能发布", isPresented: $showPublishError) {
            Button("改用网页发布") {
                UIPasteboard.general.string = drafts.draft.body
                openURL(webComposeURL)
            }
            Button("好", role: .cancel) { }
        } message: {
            // 原样透传 V2EX 的说法。笼统报「失败」会让人反复重试，
            // 而额度和冷却类的限制越试越糟。
            Text(publishError ?? "请稍后重试。")
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
                    // 未登录时没有会话 cookie，表单提交必然失败，直接走网页。
                    if session.isLoggedIn {
                        Task { await publish() }
                    } else {
                        showPublishNotice = true
                    }
                } label: {
                    Group {
                        if isPublishing {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Text("发布")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(minWidth: 44)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        drafts.isEmpty ? Theme.accent.opacity(0.4) : Theme.accent,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(drafts.isEmpty || isPublishing)
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
                        // TextEditor 的文本原点不在 (0,0)：底层 UITextView 有
                        // textContainerInset.top = 8 与 lineFragmentPadding = 5。
                        // 占位文字必须让开同样的距离，否则光标会压在它第一个字上。
                        Text("正文（支持 Markdown）")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 8)
                            .padding(.leading, 5)
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
