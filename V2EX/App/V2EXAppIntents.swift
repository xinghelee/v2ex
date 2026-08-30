import AppIntents
import Foundation

struct OpenHotTopicsIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 V2EX 最热话题"
    static let description = IntentDescription("直接进入 V2EX 今日最热话题。")
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "v2ex://home/hot")!))
    }
}

struct SearchV2EXIntent: AppIntent {
    static let title: LocalizedStringResource = "搜索 V2EX"
    static let description = IntentDescription("搜索 V2EX 的话题、回复、用户或节点。")
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "关键词")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("在 V2EX 搜索 \(\.$query)")
    }

    init() {}

    init(query: String) {
        self.query = query
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        var components = URLComponents()
        components.scheme = "v2ex"
        components.host = "search"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return .result(opensIntent: OpenURLIntent(components.url!))
    }
}

struct OpenV2EXFavoritesIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 V2EX 收藏"
    static let description = IntentDescription("查看收藏的 V2EX 话题。")
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "v2ex://favorites")!))
    }
}

struct V2EXShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenHotTopicsIntent(),
            phrases: [
                "用 \(.applicationName) 看今日最热",
                "打开 \(.applicationName) 最热话题",
            ],
            shortTitle: "今日最热",
            systemImageName: "flame"
        )
        AppShortcut(
            intent: SearchV2EXIntent(),
            phrases: [
                "用 \(.applicationName) 搜索",
                "在 \(.applicationName) 查找内容",
            ],
            shortTitle: "搜索 V2EX",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenV2EXFavoritesIntent(),
            phrases: [
                "打开 \(.applicationName) 收藏",
                "查看我的 \(.applicationName) 收藏",
            ],
            shortTitle: "我的收藏",
            systemImageName: "star"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .orange }
}
