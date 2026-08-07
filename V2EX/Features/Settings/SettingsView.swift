import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var token: TokenStore
    @EnvironmentObject private var session: V2EXSessionStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardSection {
                    NavigationLink(value: Route.appearance) {
                        SettingsRow(icon: "paintbrush.fill", iconColor: Theme.accent, title: "外观") {
                            Chevron()
                        }
                    }
                    .buttonStyle(.plain)
                    RowSeparator(leadingInset: 58)

                    NavigationLink(value: Route.reading) {
                        SettingsRow(
                            icon: "book.fill",
                            iconColor: Theme.accent,
                            title: "阅读与离线",
                            subtitle: "阅读进度、自动离线与缓存"
                        ) { Chevron() }
                    }
                    .buttonStyle(.plain)
                    RowSeparator(leadingInset: 58)

                    NavigationLink(value: Route.tokenSetup) {
                        SettingsRow(
                            icon: "key.fill",
                            iconColor: Theme.accent,
                            title: "Access Token",
                            subtitle: token.hasToken ? "已连接" : "未设置"
                        ) { Chevron() }
                    }
                    .buttonStyle(.plain)
                    RowSeparator(leadingInset: 58)

                    NavigationLink(value: Route.v2exLogin) {
                        SettingsRow(
                            icon: "person.badge.key.fill",
                            iconColor: Theme.accent,
                            title: "V2EX 登录",
                            subtitle: session.isLoggedIn ? "\(session.username) · 已登录" : "未登录（用于 app 内回复）"
                        ) { Chevron() }
                    }
                    .buttonStyle(.plain)
                    RowSeparator(leadingInset: 58)
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("自动同步关注节点")
                                .font(.system(size: 17))
                                .kerning(-0.43)
                                .foregroundStyle(Theme.ink)
                            Text(session.isLoggedIn ? "登录 \(session.username) 后自动同步网页收藏的节点" : "登录 V2EX 后自动同步网页收藏的节点")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.autoSyncFollowedNodes)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: Theme.Metric.rowHeight)
                }

                VStack(alignment: .leading, spacing: 0) {
                    GroupHeader(title: "关于")
                    CardSection {
                        Button {
                            openURL(URL(string: "https://www.v2ex.com/help/api")!)
                        } label: {
                            SettingsRow(icon: "doc.text", iconColor: Theme.accent, title: "V2EX API 文档") {
                                Chevron()
                            }
                        }
                        .buttonStyle(.plain)
                        RowSeparator(leadingInset: 58)

                        SettingsRow(icon: "info.circle", iconColor: Theme.accent, title: "版本") {
                            Text(AppInfo.displayVersion)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }

                Text("数据来自 V2EX 开放 API（api/v1 公开，api/v2 需要 Token）。全文搜索由社区项目 sov2ex 提供。")
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, Theme.Metric.headerPadding)
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct TokenSetupView: View {
    @EnvironmentObject private var token: TokenStore
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle, checking, ok(String), failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardSection(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Personal Access Token")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("在 v2ex.com/settings/tokens 生成，用于读取通知、个人资料，以及长贴的分页回复。Token 存在钥匙串里，不会离开设备。")
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)

                        SecureField("粘贴 Token", text: $draft)
                            .font(.system(size: 15, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        HStack(spacing: 10) {
                            Button {
                                Task { await verifyAndSave() }
                            } label: {
                                Text(status == .checking ? "验证中…" : "保存并验证")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 9)
                                    .background(Theme.accent, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)

                            if token.hasToken {
                                Button("清除", role: .destructive) {
                                    token.clear()
                                    draft = ""
                                    status = .idle
                                }
                                .font(.system(size: 15))
                            }
                        }

                        switch status {
                        case .ok(let message):
                            statusLine(message, color: Theme.accent, icon: "checkmark.circle.fill")
                        case .failed(let message):
                            statusLine(message, color: Theme.unreadDot, icon: "xmark.circle.fill")
                        default:
                            EmptyView()
                        }
                    }
                }

                Button {
                    openURL(URL(string: "https://www.v2ex.com/settings/tokens")!)
                } label: {
                    CardSection {
                        SettingsRow(icon: "safari.fill", iconColor: Theme.accent, title: "打开 Token 设置页") {
                            Chevron()
                        }
                    }
                }
                .buttonStyle(.plain)

                Text("没有 Token 也能用：首页、节点、话题、搜索都走公开的 API 1.0。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, Theme.Metric.headerPadding)
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("Access Token")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = token.token }
    }

    private func statusLine(_ message: String, color: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13))
            Text(message).font(.system(size: 13))
        }
        .foregroundStyle(color)
    }

    private func verifyAndSave() async {
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        status = .checking

        do {
            let member = try await V2EXClient.shared.currentMember(token: candidate)
            token.save(candidate)
            status = .ok("已连接为 \(member.username)")
        } catch {
            let message = (error as? V2EXError)?.errorDescription ?? error.localizedDescription
            status = .failed(message)
        }
    }
}
