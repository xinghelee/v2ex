import SwiftUI

/// 使用条款与社区规范。
///
/// Apple 的 1.2 要求 UGC App 在用户开始使用之前取得条款同意，且条款必须写明
/// 对冒犯性内容与滥用用户零容忍。这个 App 游客即可浏览全部内容，所以闸门
/// 放在首次启动，而不是登录之前 —— 只挡登录的话，游客一路刷下去仍然是在
/// 未同意的状态下消费 UGC。
enum Agreement {
    /// 条款改动时 +1，老用户会重新看到一次闸门。
    static let currentVersion = 1

    struct Section: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    static let intro = """
    v2Explore · Way to Explore 是 v2ex.com 的第三方阅读客户端，由独立开发者开发，与 V2EX 官方无从属关系。\
    App 内显示的话题与回复均由 V2EX 用户发布，不代表本 App 的立场。
    """

    static let sections: [Section] = [
        Section(
            icon: "hand.raised",
            title: "友善交流，共建社区",
            body: """
            希望你在这里友善交流，回复有用的信息，一起创建更好的社区。\
            请避免发布骚扰、辱骂、歧视、仇恨言论、色情、暴力、违法欺诈以及\
            侵犯他人隐私的内容。对冒犯性内容与滥用行为零容忍：相关内容会被移除，\
            情节严重者将被上报至 V2EX 站方处理。
            """
        ),
        Section(
            icon: "flag",
            title: "举报",
            body: """
            每条话题和回复都可以举报：点右上角的「…」或长按内容，选择「举报」。\
            举报后，相关内容会先从你的视野中移除，再由开发者核实处理。
            """
        ),
        Section(
            icon: "nosign",
            title: "屏蔽",
            body: """
            你可以屏蔽任何用户或关键词。屏蔽后，对方的话题和回复将不再出现在首页、节点、\
            搜索、收藏、历史以及帖子中。随时可以在「我的 → 内容与屏蔽」里撤销。
            """
        ),
        Section(
            icon: "clock.badge.checkmark",
            title: "24 小时内处理",
            body: """
            开发者会在收到举报后的 24 小时内核实：确认违规的内容会被移出 App，\
            涉及的用户会被屏蔽，并视情节上报 V2EX 站方处理。如有疑问，可随时联系开发者申诉。
            """
        ),
        Section(
            icon: "envelope",
            title: "联系方式",
            body: """
            对内容处理有疑问，或需要申诉，可随时联系开发者：\(ReportService.supportEmail)。
            """
        ),
    ]
}

/// 是否已同意条款。存 UserDefaults —— 条款同意是设备级的一次性状态，
/// 不值得为它开一个磁盘文件。
@MainActor
final class AgreementStore: ObservableObject {
    @Published private(set) var acceptedVersion: Int

    private let key = "agreedTermsVersion"

    init() {
        acceptedVersion = UserDefaults.standard.integer(forKey: key)
    }

    var hasAccepted: Bool { acceptedVersion >= Agreement.currentVersion }

    func accept() {
        acceptedVersion = Agreement.currentVersion
        UserDefaults.standard.set(acceptedVersion, forKey: key)
    }
}

// MARK: - 首次启动闸门

struct AgreementGateView: View {
    let onAccept: () -> Void

    @State private var showDeclineNotice = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("使用条款与社区规范")
                            .font(Type.display(28))
                            .foregroundStyle(Theme.ink)
                        Text(Agreement.intro)
                            .font(Type.body(14))
                            .lineSpacing(5)
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 28)

                    ForEach(Agreement.sections) { section in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: section.icon)
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 24)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(section.title)
                                    .font(Type.title(15))
                                    .foregroundStyle(Theme.ink)
                                Text(section.body)
                                    .font(Type.body(14))
                                    .lineSpacing(5)
                                    .foregroundStyle(Theme.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if showDeclineNotice {
                        Text("本 App 展示的是社区用户发布的内容。若暂时不想接受这些规范，\n可以先离开，随时欢迎你回来使用。")
                            .font(Type.body(13))
                            .lineSpacing(4)
                            .foregroundStyle(Theme.accent)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .readableColumn()
                .padding(.horizontal, Theme.Metric.screenPadding + 6)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 10) {
                Button {
                    onAccept()
                } label: {
                    Text("同意并继续")
                        .font(Type.title(16))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .prominentGlassButtonStyle()
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .tint(Theme.accent)

                Button {
                    withAnimation(.snappy) { showDeclineNotice = true }
                } label: {
                    Text("暂不同意")
                        .font(Type.body(14))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Metric.screenPadding + 6)
            .padding(.bottom, 20)
            .background(
                Theme.canvas
                    .ignoresSafeArea()
                    .overlay(alignment: .top) {
                        Rectangle().fill(Theme.separator).frame(height: Theme.Metric.hairline)
                    }
            )
        }
        .background(Theme.canvas.ignoresSafeArea())
        .interactiveDismissDisabled()
    }
}

// MARK: - 设置里的常驻入口

struct TermsView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(Agreement.intro)
                    .font(Type.body(14))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.muted)

                ForEach(Agreement.sections) { section in
                    CardSection(padding: 16) {
                        HStack(alignment: .top, spacing: 13) {
                            Image(systemName: section.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 22)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(section.title)
                                    .font(Type.title(15))
                                    .foregroundStyle(Theme.ink)
                                Text(section.body)
                                    .font(Type.body(14))
                                    .lineSpacing(5)
                                    .foregroundStyle(Theme.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Button {
                    openURL(ReportService.privacyPolicyURL)
                } label: {
                    Label("隐私政策", systemImage: "lock.shield")
                        .font(Type.title(15))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    guard let url = URL(string: "mailto:\(ReportService.supportEmail)") else { return }
                    openURL(url)
                } label: {
                    Label("联系开发者", systemImage: "envelope")
                        .font(Type.title(15))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .readableColumn()
            .padding(.horizontal, Theme.Metric.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("使用条款")
        .navigationBarTitleDisplayMode(.inline)
    }
}
