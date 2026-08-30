import SwiftUI
import UIKit

// MARK: - Keyboard dismissal

/// Installs one non-cancelling window tap recognizer for the whole app. Text
/// inputs and UIKit controls keep their normal focus; taps on surrounding
/// content end editing without blocking SwiftUI navigation or scrolling.
struct KeyboardDismissTapCapture: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.isUserInteractionEnabled = false
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: WindowReaderView, context: Context) {
        context.coordinator.attach(to: uiView.window)
    }

    static func dismantleUIView(_ uiView: WindowReaderView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        func attach(to window: UIWindow?) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            window?.addGestureRecognizer(recognizer)
        }

        func detach() {
            window?.removeGestureRecognizer(recognizer)
            window = nil
        }

        @objc private func dismissKeyboard() {
            window?.endEditing(true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView || current is UIControl {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

final class WindowReaderView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}

// MARK: - Grouped card

/// White card on warm paper. No shadow — at this contrast a shadow only muddies
/// the edge, which is what made the old grey-on-grey layout look soft.
struct CardSection<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous))
            .padding(.horizontal, Theme.Metric.screenPadding)
    }
}

/// Caption above a card group. Sentence case, not uppercase — uppercased CJK
/// does nothing but uppercased latin in a mixed line looks accidental.
struct GroupHeader: View {
    let title: String
    var trailing: String?
    var trailingAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // 12pt muted 太轻，一屏几组下来页面读不出骨架。分组标题是这些
            // 页面唯一的结构，得有实墨重量才撑得住。
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.body)
            Spacer()
            if let trailing {
                Button(trailing) { trailingAction?() }
                    .font(Type.meta(13))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.Metric.headerPadding)
        .padding(.bottom, 8)
    }
}

/// One line under a large navigation title saying what the screen is for.
///
/// A settings screen is otherwise a stack of switches with no voice, and the
/// empty canvas under a short list reads as unfinished rather than calm. This
/// gives the top of the page something to say and lets the content start lower.
struct PageIntro: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .lineSpacing(3)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Metric.headerPadding)
            .padding(.bottom, 4)
    }
}

/// Hairline separator inset from the leading edge, as in the mockups.
struct RowSeparator: View {
    var leadingInset: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: Theme.Metric.hairline)
            .padding(.leading, leadingInset)
    }
}

// MARK: - Node / avatar squares

enum RemoteImageMemoryCache {
    static let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 500
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()

    static func image(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)
    }

    static func insert(_ image: UIImage, for url: URL) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        images.setObject(image, forKey: url as NSURL, cost: cost)
    }

    static func clear() {
        images.removeAllObjects()
    }
}

/// Uses an already-decoded in-memory image synchronously when a lazy list row
/// is recreated. This avoids the placeholder frame that `AsyncImage` shows
/// even when its underlying network response is cached.
struct CachedRemoteImage: View {
    private struct LoadedImage {
        let url: URL
        let image: UIImage
    }

    let url: URL
    var contentMode: ContentMode = .fill

    @State private var loadedImage: LoadedImage?

    init(url: URL, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        _loadedImage = State(initialValue: RemoteImageMemoryCache.image(for: url).map {
            LoadedImage(url: url, image: $0)
        })
    }

    var body: some View {
        Group {
            if let loadedImage, loadedImage.url == url {
                Image(uiImage: loadedImage.image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        if let cached = RemoteImageMemoryCache.image(for: url) {
            loadedImage = LoadedImage(url: url, image: cached)
            return
        }

        loadedImage = nil
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let loaded = UIImage(data: data) else { return }
            RemoteImageMemoryCache.insert(loaded, for: url)
            loadedImage = LoadedImage(url: url, image: loaded)
        } catch {
            // The initials below remain visible on network or decoding errors.
        }
    }
}

/// Rounded square avatar. Shows the remote image when there is one and falls
/// back to the design's coloured initials square — which also stands in as the
/// placeholder while loading, so lists never flash empty grey tiles.
struct IdentitySquare: View {
    let text: String
    var size: CGFloat = 34
    var imageURL: URL?
    var color: Color?

    private var initials: String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        // CJK reads better as a single glyph; latin names as two letters.
        if first.unicodeScalars.first.map({ $0.value > 0x2E80 }) == true {
            return String(first)
        }
        return String(trimmed.prefix(2)).lowercased()
    }

    var body: some View {
        let fill = color ?? Theme.nodeColor(for: text)
        let radius = size * 0.29

        ZStack {
            LinearGradient(
                colors: [fill.opacity(0.92), fill],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let imageURL {
                CachedRemoteImage(url: imageURL)
                    .frame(width: size, height: size)
                    .clipped()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        }
    }
}

/// Subtle press feedback for rows wrapped in a NavigationLink — `.plain`
/// alone gives none, which is most of why a hand-built list feels inert.
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.rowHighlight : Color.clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableRowStyle {
    static var row: PressableRowStyle { PressableRowStyle() }
}

// MARK: - Chips

/// Pill filter used for the home tabs, node sort order, notification scopes…
/// 未选中时是玻璃胶囊（毛玻璃材质 + 高光描边，模拟器与真机都可见）；
/// 选中保持 accent 实心，选中态最清晰。
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isSelected {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accent))
                } else {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                        }
                }
            }
            .animation(.snappy(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

/// Horizontal chip rail with the design's 8pt gutters.
/// 传入 `selected` 时，选中项变化会自动滚动到可视区中间（App Store 风格）。
struct ChipRail<Item: Hashable, Label: View, Trailing: View>: View {
    let items: [Item]
    var selected: Item? = nil
    @ViewBuilder var label: (Item) -> Label
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // 用普通 HStack 排布，不用 GlassEffectContainer——它在横向
                // ScrollView 里布局不稳定（玻璃融合特性会把相邻胶囊连成
                // 一条，或让容器塌缩）。glassEffect 直接做在 chip 上，
                // 真机依然是液态玻璃。
                HStack(spacing: 8) {
                    ForEach(items, id: \.self, content: label)
                    trailing
                }
                .padding(.horizontal, Theme.Metric.screenPadding)
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()
            .onChange(of: selected) { _, newValue in
                guard let newValue else { return }
                withAnimation(.snappy(duration: 0.3)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

extension ChipRail where Trailing == EmptyView {
    init(items: [Item], selected: Item? = nil, @ViewBuilder label: @escaping (Item) -> Label) {
        self.init(items: items, selected: selected, label: label) { EmptyView() }
    }
}

// MARK: - Glass

// MARK: - Small parts

/// Quiet offline marker for topic metadata rows.
struct OfflineBadge: View {
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(Theme.faint)
            .accessibilityLabel("已离线")
    }
}

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.faint)
    }
}

/// Settings-style row: coloured icon tile, title, optional subtitle/value, chevron.
struct SettingsRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            // 单色线条字形，不是填充色圆角方块 —— 那种一行一个彩色小方块的
            // 排布是 iOS 设置的招牌长相，会把本应安静的列表变成拼色墙。
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 17))
                    .kerning(-0.43)
                    .foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Theme.Metric.cardPadding)
        .frame(minHeight: Theme.Metric.rowHeight)
        .contentShape(Rectangle())
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(icon: String, iconColor: Color, title: String, subtitle: String? = nil) {
        self.init(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - State views

struct LoadingCard: View {
    var body: some View {
        CardSection(padding: 28) {
            HStack {
                Spacer()
                ProgressView().tint(Theme.accent)
                Spacer()
            }
        }
    }
}

struct EmptyStateCard: View {
    let icon: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        CardSection(padding: 24) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.faint)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if let message {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - iPad 可读栏宽

/// 把纵向滚动的内容限制在一个舒适的阅读栏宽里并居中，避免 iPad 上列表
/// 被拉得左右贴边。iPhone 屏幕本来就窄于上限，所以这个修饰符在 iPhone
/// 上是零成本空操作。
struct ReadableColumn: ViewModifier {
    var maxWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// 720pt ≈ iPad 阅读栏宽：横屏 11 寸上两侧各留约 240pt，内容不贴边
    /// 也不会显得太窄。
    func readableColumn(maxWidth: CGFloat = 720) -> some View {
        modifier(ReadableColumn(maxWidth: maxWidth))
    }
}
