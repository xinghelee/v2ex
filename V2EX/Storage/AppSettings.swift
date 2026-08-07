import SwiftUI

enum ThemePreference: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .system: return "跟随系统"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

/// Where the experimental Hacker News page lives.
enum HackerNewsPlacement: String, CaseIterable, Identifiable {
    /// One more chip at the end of the home rail — costs no tab-bar room.
    case feed
    /// Its own tab. Reachable in one tap, at the price of a fifth item in a
    /// bar that already carries four plus search.
    case tab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feed: return "首页分类"
        case .tab: return "底部标签"
        }
    }
}

enum LineSpacingPreference: String, CaseIterable, Identifiable {
    case tight, standard, relaxed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tight: return "紧凑"
        case .standard: return "标准"
        case .relaxed: return "宽松"
        }
    }

    /// Multiplier applied to the body font size to get line height.
    var multiplier: CGFloat {
        switch self {
        case .tight: return 1.38
        case .standard: return 1.52
        case .relaxed: return 1.68
        }
    }
}

enum MonoFontPreference: String, CaseIterable, Identifiable {
    case sfMono, menlo, courier
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sfMono: return "SF Mono"
        case .menlo: return "Menlo"
        case .courier: return "Courier"
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .sfMono: return .system(size: size, design: .monospaced)
        case .menlo: return .custom("Menlo", size: size)
        case .courier: return .custom("Courier", size: size)
        }
    }
}

/// Everything screen 09 (外观) controls, plus the reading state it implies.
@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("theme") var theme: ThemePreference = .system
    @AppStorage("palette") var palette: ThemePalette = .emerald
    @AppStorage("bodyFontSize") var bodyFontSize: Double = 14
    @AppStorage("lineSpacing") var lineSpacing: LineSpacingPreference = .relaxed
    @AppStorage("monoFont") var monoFont: MonoFontPreference = .sfMono
    @AppStorage("rememberReadingPosition") var rememberReadingPosition = true
    @AppStorage("autoOfflineFollowedNodes") var autoOfflineFollowedNodes = true
    @AppStorage("autoSyncFollowedNodes") var autoSyncFollowedNodes = true
    @AppStorage("offlineOnWiFiOnly") var offlineOnWiFiOnly = true
    @AppStorage("dimReadTopics") var dimReadTopics = false

    /// 实验性：首页分类条末尾加一个 Hacker News 页。
    /// 默认关闭 —— 这是个 V2EX 客户端，第二个数据源应该是用户主动要的。
    @AppStorage("hackerNewsEnabled") var hackerNewsEnabled = false
    @AppStorage("hackerNewsPlacement") var hackerNewsPlacement: HackerNewsPlacement = .feed

    var bodyFont: Font { .system(size: bodyFontSize) }
    var bodyLineSpacing: CGFloat { bodyFontSize * (lineSpacing.multiplier - 1) }
    func codeFont(size: CGFloat) -> Font { monoFont.font(size: size) }
}
