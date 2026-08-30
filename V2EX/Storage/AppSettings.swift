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

    /// 首页「全部」分类顶部的节点活跃分布。默认开启，让产品差异
    /// 在首次使用时可见；不喜欢仪表盘的用户可以恢复纯列表。
    @AppStorage("communityPulseEnabled") var communityPulseEnabled = true

    /// 实验性：首页分类条末尾加一个 Hacker News 页。
    /// 默认关闭 —— 这是个 V2EX 客户端，第二个数据源应该是用户主动要的。
    @AppStorage("hackerNewsEnabled") var hackerNewsEnabled = false

    var bodyFont: Font { .system(size: bodyFontSize) }
    var bodyLineSpacing: CGFloat { bodyFontSize * (lineSpacing.multiplier - 1) }
    func codeFont(size: CGFloat) -> Font { monoFont.font(size: size) }
}
