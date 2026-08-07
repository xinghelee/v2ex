import SwiftUI
import os
import SandboxServer

@main
struct V2EXApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var token = TokenStore()
    @StateObject private var session = V2EXSessionStore()
    @StateObject private var followed = FollowedNodesStore()
    @StateObject private var readState = ReadStateStore()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var topicCache = TopicDetailCacheStore()
    @StateObject private var offline = OfflineStore()
    @StateObject private var recentSearches = RecentSearchStore()
    @StateObject private var blocks = BlockStore()
    @StateObject private var drafts = DraftStore()
    @StateObject private var replyDrafts = ReplyDraftStore()
    @StateObject private var history = HistoryStore()

    init() {
        #if DEBUG
        // DEBUG 调试台：浏览器 / curl / MCP 直接看 App 的网络请求与沙盒数据。
        // Release 构建里 SandboxServer 是 no-op 空壳，这段代码物理上不存在。
        Task {
            let result = await SandboxServer.shared.start(
                SandboxConfig(bindingPolicy: .localNetwork, auth: .token)
            )
            if case .started(let info) = result {
                print("🧰 Sandbox 控制台 → \(info.consoleURL)")
                // os_log 版本便于 `log stream` 抓取（真机 print 不一定会进日志流）。
                Logger(subsystem: "com.vibe.v2ex", category: "sandbox")
                    .info("🧰 Sandbox 控制台 → \(info.consoleURL.absoluteString, privacy: .public)")
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(token)
                .environmentObject(session)
                .environmentObject(followed)
                .environmentObject(readState)
                .environmentObject(favorites)
                .environmentObject(topicCache)
                .environmentObject(offline)
                .environmentObject(recentSearches)
                .environmentObject(blocks)
                .environmentObject(drafts)
                .environmentObject(replyDrafts)
                .environmentObject(history)
                .preferredColorScheme(settings.theme.colorScheme)
                .tint(Theme.accent)
        }
    }
}
