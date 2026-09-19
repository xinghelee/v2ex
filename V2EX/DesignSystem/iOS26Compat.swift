import SwiftUI

extension TabRole {
    /// iOS 27 的 search 不保证独立显示，使用 prominent 固定为右侧独立入口。
    static var separateSearch: TabRole {
        if #available(iOS 27.0, *) {
            return .prominent
        }
        return .search
    }
}

// MARK: - iOS 26 API 兼容层
//
// 工程最低版本支持 iOS 18，同时尽量保留 iOS 26 的原生 Liquid Glass 体验。
// 所有 iOS 26 专属 API 都收口在这一层：iOS 26 走原生实现，低版本走降级方案，
// 调用方不需要写 #available 判断。

extension View {
    /// 胶囊磨砂：iOS 26 用原生 Liquid Glass，低版本降级为 ultraThinMaterial。
    /// 对应 `.glassEffect(.regular.interactive(), in: shape)`。
    @ViewBuilder
    func glassPill(in shape: some Shape = Capsule()) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// 强调按钮：iOS 26 用玻璃按钮，低版本降级为 borderedProminent。
    /// 对应 `.buttonStyle(.glassProminent)`。
    @ViewBuilder
    func prominentGlassButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// 顶部安全区栏：iOS 26 用 safeAreaBar，低版本用等效的 safeAreaInset。
    /// 对应 `.safeAreaBar(edge: .top, spacing: 0) { ... }`。
    @ViewBuilder
    func topSafeAreaBar<Content: View>(
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: .top, spacing: spacing, content: content)
        }
    }

    /// 统一使用柔和滚动边缘，避免外观随系统默认值变化；低版本直接忽略。
    /// 在应用入口设置，由层级内的滚动视图继承。
    @ViewBuilder
    func softScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }

    /// 悬浮标签栏不自动收起：iOS 26 专属；低版本标签栏本身不收起，直接忽略。
    /// 对应 `.tabBarMinimizeBehavior(.never)`。
    @ViewBuilder
    func keepTabBarExpanded() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.never)
        } else {
            self
        }
    }
}

/// 玻璃容器：iOS 26 用 GlassEffectContainer 让容器内多个玻璃元素融合渲染，
/// 低版本降级为普通 VStack（各元素自带材质，无需融合）。
struct GlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            VStack(spacing: spacing) { content }
        }
    }
}
