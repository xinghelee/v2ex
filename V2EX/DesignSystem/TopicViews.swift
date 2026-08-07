import SwiftUI

/// Relative timestamps in the design's voice: 18 分钟前 / 3 小时前 / 昨天 / 上周.
enum RelativeTime {
    static func string(from date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60: return "刚刚"
        case ..<3_600: return "\(Int(seconds / 60)) 分钟前"
        case ..<86_400: return "\(Int(seconds / 3_600)) 小时前"
        case ..<172_800: return "昨天"
        case ..<604_800: return "\(Int(seconds / 86_400)) 天前"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "M 月 d 日"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Node tag

/// A node reads as a quiet neutral label. Colour used to carry the source —
/// six hues at random made the feed read as noise, so the tag now stays in
/// ink tones and lets the headline do the work.
struct NodeTag: View {
    let title: String
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.faint)
                .frame(width: size * 0.45, height: size * 0.45)
            Text(title)
                .font(Type.label(size))
                .foregroundStyle(Theme.muted)
        }
    }
}

/// Reply count: rounded tabular numerals in a fixed trailing column.
struct ReplyCount: View {
    let value: Int
    var size: CGFloat = 15

    var body: some View {
        Text("\(value)")
            .font(Type.number(size))
            .foregroundStyle(value == 0 ? Theme.faint : Theme.muted)
            .frame(minWidth: 30, alignment: .trailing)
    }
}

// MARK: - PRO badge

/// V2EX's paid-membership mark. Filled ink rather than the accent, because the
/// accent already means "楼主" two glyphs away and a second saturated chip there
/// reads as one blurred label.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .kerning(0.3)
            .foregroundStyle(Theme.card)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.ink.opacity(0.75), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityLabel("PRO 会员")
    }
}

// MARK: - Promotion badge

enum PromotionBadgeMetric {
    static let height: CGFloat = 20
    /// Gap the row leaves under the badge before the reply count resumes.
    static let gap: CGFloat = 6
}

/// Marks a topic sitting in V2EX's `promotions` node, and explains what that
/// means on tap — an unexplained badge is just decoration.
struct PromotionBadge: View {
    @State private var showsExplanation = false

    var body: some View {
        Button {
            showsExplanation = true
        } label: {
            Image(systemName: "megaphone.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .frame(height: PromotionBadgeMetric.height)
                .padding(.horizontal, 7)
                .background(Theme.amberSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("推广内容，点按查看说明")
        .popover(isPresented: $showsExplanation) {
            explanation.presentationCompactAdaptation(.popover)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("推广内容", systemImage: "megaphone.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)

            Text("这条发布在 V2EX 的「推广」节点，是站方允许的商业内容，不是普通用户讨论。")
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Theme.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 268)
    }
}

extension View {
    /// Lays the promotion marker over a row's top-right corner.
    ///
    /// Deliberately applied *outside* the `NavigationLink` it decorates: a
    /// button nested inside a link's label never receives the tap, so the badge
    /// would look interactive and do nothing. Insets are passed in because the
    /// featured card and the list row bring different padding to the corner.
    /// Defaults land the badge in a `TopicRow`'s corner — they mirror that row's
    /// own horizontal and vertical padding. The featured card passes its own.
    @ViewBuilder
    func promotionBadge(
        for topic: V2Topic,
        trailing: CGFloat = Theme.Metric.cardPadding,
        top: CGFloat = 14
    ) -> some View {
        if topic.isPromotionNode {
            overlay(alignment: .topTrailing) {
                PromotionBadge()
                    .padding(.trailing, trailing)
                    .padding(.top, top)
            }
        } else {
            self
        }
    }
}

// MARK: - Featured card

/// Lead card at the top of a feed. Title-led, one quiet meta line.
struct FeaturedTopicCard: View {
    let topic: V2Topic
    var badge: String = "今日最热"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                NodeTag(title: topic.nodeTitle, size: 12)
                Text(badge)
                    .font(Type.label(11))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.accentSoft, in: Capsule())
                Spacer(minLength: 0)
            }

            Text(topic.title)
                .font(Type.headline(20))
                .kerning(-0.5)
                .lineSpacing(5)
                .lineLimit(3)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            if !topic.excerpt.isEmpty {
                Text(topic.excerpt)
                    .font(Type.body(14))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 7) {
                IdentitySquare(text: topic.authorName, size: 22, imageURL: topic.member?.avatarURL)
                Text(topic.authorName)
                    .font(Type.meta(12))
                    .foregroundStyle(Theme.body)
                    .lineLimit(1)
                Text("·").foregroundStyle(Theme.faint)
                Text(RelativeTime.string(from: topic.activityDate))
                    .font(Type.meta(12))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 6)
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                ReplyCount(value: topic.replies, size: 16)
                    .frame(minWidth: 0)
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - List row

/// Title-first row. The old avatar-led layout put uncontrolled user imagery in
/// the strongest position on screen; here the headline leads and identity is
/// demoted to the meta line.
struct TopicRow: View {
    let topic: V2Topic
    var showsNode = true
    var isOffline = false
    var isRead = false
    var dimRead = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(topic.title)
                    .font(Type.title(16))
                    .kerning(-0.2)
                    .lineSpacing(3)
                    .lineLimit(2)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 7) {
                    if showsNode, !topic.nodeTitle.isEmpty {
                        NodeTag(title: topic.nodeTitle, size: 12)
                    }
                    if !topic.authorName.isEmpty {
                        IdentitySquare(text: topic.authorName, size: 16, imageURL: topic.member?.avatarURL)
                        Text(topic.authorName)
                            .font(Type.meta(11))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    Text(RelativeTime.string(from: topic.activityDate))
                        .font(Type.meta(11))
                        .foregroundStyle(Theme.faint)
                        .layoutPriority(1)
                    if isOffline { OfflineBadge() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ReplyCount(value: topic.replies)
                // The promotion badge is overlaid from outside the enclosing
                // NavigationLink, so it cannot push this down itself — the row
                // reserves the corner for it here instead.
                .padding(.top, topic.isPromotionNode
                    ? PromotionBadgeMetric.height + PromotionBadgeMetric.gap
                    : 1)
        }
        .padding(.horizontal, Theme.Metric.cardPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dimRead && isRead ? 0.4 : 1)
        .contentShape(Rectangle())
    }
}

/// Wraps rows in a card and draws the hairlines between them.
struct TopicListCard<Item: Identifiable, RowContent: View>: View {
    let items: [Item]
    var separatorInset: CGFloat = Theme.Metric.cardPadding
    @ViewBuilder var row: (Item) -> RowContent

    var body: some View {
        // Lazy, not CardSection's eager VStack: paged feeds (node detail,
        // offline, favourites) can grow to dozens of rows, and every row's
        // avatar is an AsyncImage — building them all up front fires a wall
        // of simultaneous downloads that stalls scrolling.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 {
                    RowSeparator(leadingInset: separatorInset)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous))
        .padding(.horizontal, Theme.Metric.screenPadding)
    }
}

// MARK: - Rendered content

/// Draws parsed HTML blocks with the reader settings from 外观 applied.
/// `fontSize`/`lineSpacing` override the reader defaults — replies use a
/// slightly smaller body, so one renderer serves both.
/// An image inside a post body, sized the way the web renders it: scaled *down*
/// to fit the column, but never scaled up past its own pixel size.
///
/// V2EX turns a bare image URL into `<img class="embedded_image">` whether it is
/// a screenshot or a 64px reaction sticker — the markup is identical, so size is
/// the only signal there is. Stretching everything to the full column turned
/// those stickers into blurry full-width portraits.
private struct ContentImage: View {
    let url: URL

    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL) {
        self.url = url
        _image = State(initialValue: RemoteImageMemoryCache.image(for: url))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    // The cap is the picture's own width in points; the column
                    // still shrinks anything wider, so this only stops upscaling.
                    .frame(maxWidth: image.size.width)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if failed {
                placeholder(height: 120) {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.faint)
                }
            } else {
                placeholder(height: 160) { ProgressView().tint(Theme.accent) }
            }
        }
        .task(id: url) { await load() }
    }

    private func placeholder(height: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.inset)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(content())
    }

    @MainActor
    private func load() async {
        if let cached = RemoteImageMemoryCache.image(for: url) {
            image = cached
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let decoded = UIImage(data: data)
            else {
                failed = true
                return
            }
            RemoteImageMemoryCache.insert(decoded, for: url)
            image = decoded
        } catch {
            failed = !Task.isCancelled
        }
    }
}

struct ContentBlocksView: View {
    private struct PreviewImage: Identifiable {
        let id = UUID()
        let url: URL
    }

    let blocks: [ContentBlock]
    var fontSize: CGFloat? = nil
    var lineSpacing: CGFloat? = nil
    @EnvironmentObject private var settings: AppSettings
    @State private var previewImage: PreviewImage?

    private var baseSize: CGFloat { fontSize ?? settings.bodyFontSize }
    private var baseSpacing: CGFloat { lineSpacing ?? settings.bodyLineSpacing }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(blocks) { block in
                switch block {
                case .paragraph(let text):
                    Text(text)
                        .font(.system(size: baseSize))
                        .lineSpacing(baseSpacing)
                        .foregroundStyle(Theme.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                case .code(let source):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(source)
                            .font(settings.codeFont(size: baseSize - 3))
                            .foregroundStyle(Theme.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                case .quote(let text):
                    HStack(alignment: .top, spacing: 12) {
                        Rectangle()
                            .fill(Theme.accent.opacity(0.5))
                            .frame(width: 2)
                        Text(text)
                            .font(.system(size: baseSize - 1))
                            .lineSpacing(baseSpacing * 0.8)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                case .list(let items):
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 9) {
                                Circle()
                                    .fill(Theme.accent.opacity(0.55))
                                    .frame(width: 5, height: 5)
                                    .padding(.top, baseSize * 0.45)
                                Text(item)
                                    .font(.system(size: baseSize))
                                    .lineSpacing(baseSpacing)
                                    .foregroundStyle(Theme.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                case .image(let url):
                    Button {
                        previewImage = PreviewImage(url: url)
                    } label: {
                        ContentImage(url: url)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("放大查看图片")

                case .rule:
                    Rectangle().fill(Theme.separator).frame(height: Theme.Metric.hairline)
                }
            }
        }
        .fullScreenCover(item: $previewImage) { preview in
            FullScreenImagePreview(url: preview.url)
        }
    }
}

private struct FullScreenImagePreview: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    ZoomablePreviewImage(image: image)
                case .failure:
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 32, weight: .light))
                        Text("图片加载失败")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.72))
                case .empty:
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                @unknown default:
                    EmptyView()
                }
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.48), in: Circle())
                    }
                    .accessibilityLabel("关闭图片预览")
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .statusBarHidden()
        .presentationBackground(.black)
    }
}

private struct ZoomablePreviewImage: View {
    let image: Image

    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            image
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(Rectangle())
                .gesture(magnificationGesture(in: proxy.size))
                .simultaneousGesture(dragGesture(in: proxy.size))
                .onTapGesture(count: 2) {
                    toggleZoom()
                }
                .accessibilityLabel("图片预览")
                .accessibilityHint("双击放大或还原")
        }
    }

    private func magnificationGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(settledScale * value.magnification, 1), 5)
                offset = clamped(offset, for: scale, in: size)
            }
            .onEnded { _ in
                if scale < 1.05 {
                    resetZoom()
                } else {
                    settledScale = scale
                    offset = clamped(offset, for: scale, in: size)
                    settledOffset = offset
                }
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard scale > 1 else { return }
                let proposed = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
                offset = clamped(proposed, for: scale, in: size)
            }
            .onEnded { _ in
                settledOffset = offset
            }
    }

    private func toggleZoom() {
        withAnimation(.snappy(duration: 0.24)) {
            if scale > 1 {
                resetZoom()
            } else {
                scale = 2.5
                settledScale = 2.5
            }
        }
    }

    private func resetZoom() {
        scale = 1
        settledScale = 1
        offset = .zero
        settledOffset = .zero
    }

    private func clamped(_ offset: CGSize, for scale: CGFloat, in size: CGSize) -> CGSize {
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}
