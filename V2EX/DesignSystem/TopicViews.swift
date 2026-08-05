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
                .padding(.top, 1)
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
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                // Frame first, then fit — without the explicit
                                // width the image lays out at intrinsic size and
                                // gets clipped (same bug as the avatars).
                                image.resizable().scaledToFit()
                                    .frame(maxWidth: .infinity)
                            case .failure:
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Theme.inset)
                                    .frame(height: 120)
                                    .overlay {
                                        Image(systemName: "photo")
                                            .font(.system(size: 22))
                                            .foregroundStyle(Theme.faint)
                                    }
                            case .empty:
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Theme.inset)
                                    .frame(height: 160)
                                    .overlay(ProgressView().tint(Theme.accent))
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
