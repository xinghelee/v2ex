import SwiftUI

@MainActor
final class NotificationsViewModel: ObservableObject {
    @Published private(set) var items: [V2Notification] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var scope: V2Notification.Kind? = .reply

    /// IDs already seen, so the badge and the tinted rows agree.
    @Published private(set) var seenIDs: Set<Int> = Set(
        UserDefaults.standard.array(forKey: "seenNotifications") as? [Int] ?? []
    )

    var unreadCount: Int { items.filter { !seenIDs.contains($0.id) }.count }

    func visible(in scope: V2Notification.Kind?) -> [V2Notification] {
        guard let scope else { return items }
        return items.filter { $0.kind == scope }
    }

    func count(of kind: V2Notification.Kind) -> Int {
        items.filter { $0.kind == kind && !seenIDs.contains($0.id) }.count
    }

    func isUnread(_ item: V2Notification) -> Bool { !seenIDs.contains(item.id) }

    func refresh(token: String) async {
        guard !token.isEmpty else {
            items = []
            errorMessage = nil
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            items = try await V2EXClient.shared.notifications(page: 1, token: token)
            await backfillAvatars()
        } catch {
            errorMessage = (error as? V2EXError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Notification members only carry `username` — fetch the avatar from API
    /// 1.0 once per user (cached) and patch it into the rows.
    private var avatarCache: [String: String] = [:]

    private func backfillAvatars() async {
        // Re-apply cached avatars to the fresh rows first — every refresh
        // replaces `items` with a payload that never carries avatar fields,
        // so without this the avatars get wiped on each refresh.
        for index in items.indices {
            guard let member = items[index].member,
                  member.avatarURL == nil,
                  let cached = avatarCache[member.username] else { continue }
            items[index].member?.avatarLarge = cached
        }
        // Then fetch whatever is still missing, once per user.
        for item in items {
            guard let member = item.member,
                  member.avatarURL == nil,
                  !member.username.isEmpty,
                  avatarCache[member.username] == nil else { continue }
            guard let fetched = try? await V2EXClient.shared.member(username: member.username),
                  let url = fetched.avatarURL?.absoluteString else { continue }
            avatarCache[member.username] = url
            for index in items.indices where items[index].member?.username == member.username {
                items[index].member?.avatarLarge = url
            }
        }
    }

    func markAllRead() {
        seenIDs.formUnion(items.map(\.id))
        persistSeen()
    }

    func markRead(_ item: V2Notification) {
        guard seenIDs.insert(item.id).inserted else { return }
        persistSeen()
    }

    func delete(_ item: V2Notification, token: String) async {
        guard !token.isEmpty else { return }
        try? await V2EXClient.shared.deleteNotification(id: item.id, token: token)
        items.removeAll { $0.id == item.id }
    }

    private func persistSeen() {
        UserDefaults.standard.set(Array(seenIDs), forKey: "seenNotifications")
    }
}

struct NotificationsView: View {
    @EnvironmentObject private var model: NotificationsViewModel
    @EnvironmentObject private var token: TokenStore

    /// Per-scope scroll offsets, so swiping between scopes doesn't lose your place.
    @State private var scrollPositions: [V2Notification.Kind?: ScrollPosition] = [:]

    private let scopes: [(kind: V2Notification.Kind?, title: String)] = [
        (.reply, "回复我的"), (.mention, "@ 我的"), (.thanks, "感谢"), (nil, "全部"),
    ]

    var body: some View {
        // One page per scope: swiping and the system segmented control stay in
        // sync through the shared `model.scope` selection.
        TabView(selection: $model.scope) {
            ForEach(Array(scopes.enumerated()), id: \.offset) { _, scope in
                page(for: scope.kind)
                    .tag(scope.kind)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Let the list scroll under the floating tab bar instead of stopping above it.
        .ignoresSafeArea(edges: .bottom)
        .background(Theme.canvas)
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("全部已读") {
                    withAnimation(.snappy) { model.markAllRead() }
                }
                .disabled(model.unreadCount == 0)
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) { scopePicker }
        .task { await model.refresh(token: token.token) }
    }

    private var scopePicker: some View {
        Picker("通知类型", selection: $model.scope) {
            ForEach(Array(scopes.enumerated()), id: \.offset) { _, scope in
                Text(scopeLabel(scope.kind, title: scope.title))
                    .tag(scope.kind)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.Metric.screenPadding)
        .padding(.vertical, 8)
        .readableColumn()
    }

    private func scopeLabel(_ kind: V2Notification.Kind?, title: String) -> String {
        let count = kind.map { model.count(of: $0) } ?? model.unreadCount
        return count > 0 ? "\(title) \(count)" : title
    }

    private func page(for kind: V2Notification.Kind?) -> some View {
        let visible = model.visible(in: kind)
        return ScrollView {
            LazyVStack(spacing: 10) {
                if !token.hasToken {
                    tokenPrompt
                } else if model.isLoading && model.items.isEmpty {
                    LoadingCard()
                } else if let message = model.errorMessage, model.items.isEmpty {
                    EmptyStateCard(icon: "exclamationmark.triangle", title: "没能读取通知", message: message,
                                   actionTitle: "重试") {
                        Task { await model.refresh(token: token.token) }
                    }
                } else if visible.isEmpty {
                    EmptyStateCard(icon: "bell.slash", title: "没有新通知")
                } else {
                    CardSection {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                            row(item)
                            if index < visible.count - 1 {
                                RowSeparator(leadingInset: 62)
                            }
                        }
                    }
                }
            }
            .readableColumn()
            // Room for the floating tab bar + home indicator at the bottom.
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
        .pullToRefresh(isEnabled: model.scope == kind) {
            await model.refresh(token: token.token)
        }
        .scrollPosition(scrollBinding(for: kind))
    }

    private func scrollBinding(for kind: V2Notification.Kind?) -> Binding<ScrollPosition> {
        Binding(
            get: { scrollPositions[kind] ?? ScrollPosition() },
            set: { scrollPositions[kind] = $0 }
        )
    }

    private var tokenPrompt: some View {
        EmptyStateCard(
            icon: "key",
            title: "通知需要 Access Token",
            message: "V2EX 只在 API 2.0 提供通知，需要在 v2ex.com/settings/tokens 生成一个 Personal Access Token。",
            actionTitle: "去填写"
        ) { }
        .overlay {
            NavigationLink(value: Route.tokenSetup) {
                // Color.clear is transparent to hit-testing by default — the
                // shape makes the whole card tappable.
                Color.clear.contentShape(Rectangle())
            }
                .buttonStyle(.plain)
        }
    }

    private func row(_ item: V2Notification) -> some View {
        let parsed = item.parsed
        let unread = model.isUnread(item)

        return Group {
            if let topicID = parsed.topicID {
                NavigationLink(value: Route.topic(topicID)) { rowContent(item, parsed: parsed, unread: unread) }
                    .buttonStyle(.row)
                    .simultaneousGesture(TapGesture().onEnded { model.markRead(item) })
            } else {
                rowContent(item, parsed: parsed, unread: unread)
            }
        }
        .contextMenu {
            Button("标记已读") { model.markRead(item) }
            Button(role: .destructive) {
                Task { await model.delete(item, token: token.token) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func rowContent(
        _ item: V2Notification,
        parsed: (action: String, topicTitle: String?, topicID: Int?),
        unread: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            IdentitySquare(text: item.authorName, size: 34, imageURL: item.member?.avatarURL)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.authorName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(parsed.action)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 4)
                    Text(RelativeTime.string(from: item.date))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }

                if let payload = item.displayPayload, !payload.isEmpty {
                    Text(HTMLText.plain(payload))
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let title = parsed.topicTitle {
                    Text("在「\(title)」")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(unread ? Theme.accentWash : Color.clear)
        .overlay(alignment: .topLeading) {
            if unread {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
                    .padding(.leading, 6)
                    .padding(.top, 18)
            }
        }
        .contentShape(Rectangle())
    }
}
