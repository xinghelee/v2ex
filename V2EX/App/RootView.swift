import CoreSpotlight
import SwiftUI

struct HomeOpenRequest: Equatable {
    let id = UUID()
    let feed: HomeViewModel.Feed
}

struct SearchOpenRequest: Equatable {
    let id = UUID()
    let query: String?
}

enum AppTab: Int, CaseIterable, Identifiable {
    case home, nodes, notifications, profile, search, hackerNews
    var id: Int { rawValue }

    static let primary: [AppTab] = [.home, .nodes, .notifications, .profile]

    var title: String {
        switch self {
        case .home: return "首页"
        case .nodes: return "节点"
        case .notifications: return "通知"
        case .profile: return "我的"
        case .search: return "搜索"
        case .hackerNews: return "HN"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .nodes: return "square.grid.2x2"
        case .notifications: return "bell"
        case .profile: return "person"
        case .search: return "magnifyingglass"
        case .hackerNews: return "newspaper"
        }
    }

}

/// Destinations pushed onto any tab's navigation stack.
enum Route: Hashable {
    case topic(Int)
    case node(String)
    case nodeCategory(String)
    case member(String)
    case favorites
    case history
    case nodeCatalog
    case hackerNews(Int)
    case offline
    case myPosts
    case radar
    case blocked
    case terms
    case settings
    case appearance
    case reading
    case aiConfiguration
    case tokenSetup
    case v2exLogin
}

struct RootView: View {
    @State private var selection: AppTab = .home
    @State private var paths: [AppTab: NavigationPath] = [:]
    @State private var showCompose = false
    @State private var homeRequest = HomeOpenRequest(feed: .all)
    @State private var searchRequest = SearchOpenRequest(query: nil)
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var autoOffline = AutoOfflineCoordinator()

    /// Debug launch helper — lets automation open a topic directly:
    /// `simctl launch booted com.vibe.v2ex -openTopic 1231572`
    /// 或直接落到某个标签：`-tab nodes`。
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-openTopic"),
           flag + 1 < arguments.count,
           let id = Int(arguments[flag + 1]) {
            var path = NavigationPath()
            path.append(Route.topic(id))
            _paths = State(initialValue: [.home: path])
        }
        if let flag = arguments.firstIndex(of: "-tab"),
           flag + 1 < arguments.count,
           let tab = AppTab.allCases.first(where: { "\($0)" == arguments[flag + 1] }) {
            _selection = State(initialValue: tab)
        }
    }

    @EnvironmentObject private var token: TokenStore
    @EnvironmentObject private var session: V2EXSessionStore
    @EnvironmentObject private var followed: FollowedNodesStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var moderation: ModerationStore
    @EnvironmentObject private var agreement: AgreementStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var notifications = NotificationsViewModel()

    var body: some View {
        // The native iOS 26 tab bar *is* the design's floating glass pill.
        TabView(selection: tabSelection) {
            ForEach(primaryTabs) { tab in
                Tab(tab.title, systemImage: tab.icon, value: tab) {
                    NavigationStack(path: binding(for: tab)) {
                        screen(for: tab)
                            .navigationDestination(for: Route.self) { route in
                                destination(route)
                            }
                    }
                    .environment(\.openURL, memberLinkAction(for: tab))
                }
                .badge(tab == .notifications ? notifications.unreadCount : 0)
            }

            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack(path: binding(for: .search)) {
                    SearchView(request: searchRequest)
                        .navigationDestination(for: Route.self) { route in
                            destination(route)
                        }
                }
                .environment(\.openURL, memberLinkAction(for: .search))
            }
        }
        .keepTabBarExpanded()
        .fullScreenCover(isPresented: $showCompose) {
            ComposeView { newTopicID in
                // 发完直接落到自己的帖子上，省得再去首页找。
                paths[selection, default: NavigationPath()].append(Route.topic(newTopicID))
            }
        }
        .sheet(item: $updateChecker.availableRelease, onDismiss: {
            updateChecker.snoozePresentedRelease()
        }) { release in
            TestFlightUpdateSheet(release: release)
        }
        .environmentObject(notifications)
        // UGC 闸门：条款没同意之前，一条用户内容都不给看。
        .fullScreenCover(isPresented: .constant(!agreement.hasAccepted)) {
            AgreementGateView { agreement.accept() }
        }
        .task {
            await updateChecker.checkForUpdate()
            await moderation.flush()
        }
        .task(id: token.token) {
            await notifications.refresh(token: token.token)
        }
        // 登录后把网页收藏的节点同步到本地（自动同步开关控制）。
        .task(id: session.isLoggedIn) {
            guard settings.autoSyncFollowedNodes else { return }
            await followed.syncFromRemote(cookie: session.cookie)
        }
        .task(id: autoOfflineTaskID) {
            await syncAutomaticOffline()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await syncAutomaticOffline() }
            Task { await moderation.flush() }
        }
        .onOpenURL(perform: handleDeepLink)
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  identifier.hasPrefix("topic-"),
                  let id = Int(identifier.dropFirst("topic-".count)) else { return }
            openTopic(id)
        }
        .background {
            KeyboardDismissTapCapture()
                .allowsHitTesting(false)
        }
    }

    /// HN 只有在开启且选了「底部标签」时才占一格。标签栏本来就有四项加
    /// 搜索，第五项是有代价的，所以交给用户决定。
    /// HN 顶替「节点」而不是追加。
    ///
    /// iOS 的标签栏最多 5 格，原来正好是四个主标签加搜索。直接追加会让系统
    /// 把 HN **和搜索**一起收进「更多」—— 净亏。所以要上标签栏就得腾位置，
    /// 让出的是「节点」：节点仍可从每篇帖子的顶部标签、搜索、以及「我的」
    /// 里的节点目录进入，是四个里唯一还有其他入口的。
    private var primaryTabs: [AppTab] {
        guard settings.hackerNewsEnabled, settings.hackerNewsPlacement == .tab else {
            return AppTab.primary
        }
        return AppTab.primary.map { $0 == .nodes ? .hackerNews : $0 }
    }

    private var autoOfflineTaskID: String {
        "\(settings.autoOfflineFollowedNodes)-\(settings.offlineOnWiFiOnly)-\(followed.names.joined(separator: ","))"
    }

    private func syncAutomaticOffline() async {
        await autoOffline.sync(
            followedNodes: followed.names,
            token: token.token,
            settings: settings,
            offline: offline
        )
    }

    /// Re-selecting the active tab pops it back to root, like the system bar.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == selection { paths[newValue] = NavigationPath() }
                selection = newValue
            }
        )
    }

    /// V2EX writes an @mention as `<a href="/member/name">`, which the content
    /// parser resolves to a full v2ex.com URL — tapping one would hand the reader
    /// to Safari for a page this app already has. Catch those and push the
    /// in-app member screen onto the tab that raised them.
    ///
    /// Deliberately narrow: only `/member/` is claimed. `/t/` URLs are what the
    /// explicit "在 V2EX 打开" buttons pass to `openURL`, and those mean it.
    private func memberLinkAction(for tab: AppTab) -> OpenURLAction {
        OpenURLAction { url in
            guard let username = Self.mentionedMember(in: url) else { return .systemAction }
            paths[tab, default: NavigationPath()].append(Route.member(username))
            return .handled
        }
    }

    static func mentionedMember(in url: URL) -> String? {
        guard let host = url.host()?.lowercased(),
              host == "v2ex.com" || host == "www.v2ex.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "member", !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    private func binding(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(
            get: { paths[tab] ?? NavigationPath() },
            set: { paths[tab] = $0 }
        )
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView(request: homeRequest, onCompose: { showCompose = true })
        case .nodes:
            NodesView()
        case .notifications:
            NotificationsView()
        case .profile:
            ProfileView()
        case .search:
            SearchView(request: searchRequest)
        case .hackerNews:
            HackerNewsView()
                .background(Theme.canvas)
                .navigationTitle("Hacker News")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "v2ex" else { return }
        let host = url.host()?.lowercased() ?? ""
        let path = url.pathComponents.filter { $0 != "/" }

        switch host {
        case "home":
            selection = .home
            paths[.home] = NavigationPath()
            let feed: HomeViewModel.Feed = path.first == "hot" ? .hot : .all
            homeRequest = HomeOpenRequest(feed: feed)
        case "search":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value
            selection = .search
            paths[.search] = NavigationPath()
            searchRequest = SearchOpenRequest(query: query)
        case "favorites":
            selection = .profile
            var path = NavigationPath()
            path.append(Route.favorites)
            paths[.profile] = path
        case "topic":
            if let value = path.first, let id = Int(value) { openTopic(id) }
        case "node":
            guard let name = path.first, !name.isEmpty else { return }
            selection = .home
            var route = NavigationPath()
            route.append(Route.node(name))
            paths[.home] = route
        default:
            break
        }
    }

    private func openTopic(_ id: Int) {
        selection = .home
        var path = NavigationPath()
        path.append(Route.topic(id))
        paths[.home] = path
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .topic(let id): TopicDetailView(topicID: id)
        case .node(let name): NodeDetailView(nodeName: name)
        case .nodeCategory(let id):
            if let category = NodeCatalog.categories.first(where: { $0.id == id }) {
                NodeCategoryView(category: category)
            } else {
                NodesView()
            }
        case .member(let name): MemberView(username: name)
        case .favorites: FavoritesView()
        case .history: HistoryView()
        case .nodeCatalog: NodesView()
        case .hackerNews(let id): HNDetailView(itemID: id)
        case .offline: OfflineListView()
        case .myPosts: MyPostsView()
        case .radar: RadarView()
        case .blocked: ModerationSettingsView()
        case .terms: TermsView()
        case .settings: SettingsView()
        case .appearance: AppearanceSettingsView()
        case .reading: ReadingSettingsView()
        case .aiConfiguration: AIConfigurationView()
        case .tokenSetup: TokenSetupView()
        case .v2exLogin: V2EXLoginView()
        }
    }
}
