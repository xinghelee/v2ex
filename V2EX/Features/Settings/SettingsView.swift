import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var token: TokenStore
    @EnvironmentObject private var session: V2EXSessionStore
    @EnvironmentObject private var aiConfiguration: AIConfigurationStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageIntro(text: "账号连接、外观与阅读偏好都在这里。数据全部存在本机。")

                // 账号排在最前：它是这页唯一有"状态"的东西，也是出问题时
                // 用户来设置里要找的答案。偏好类的项每天都在用，但不需要
                // 被查看。
                VStack(alignment: .leading, spacing: 0) {
                    GroupHeader(title: "账号")
                    CardSection {
                        NavigationLink(value: Route.tokenSetup) {
                            SettingsRow(
                                icon: "key",
                                iconColor: Theme.accent,
                                title: "Access Token",
                                subtitle: token.hasToken ? "已连接" : "未设置"
                            ) { Chevron() }
                        }
                        .buttonStyle(.plain)
                        RowSeparator(leadingInset: 54)

                        NavigationLink(value: Route.v2exLogin) {
                            SettingsRow(
                                icon: "person.badge.key",
                                iconColor: Theme.accent,
                                title: "V2EX 登录",
                                subtitle: session.isLoggedIn
                                    ? "\(session.username) · 已登录"
                                    : "未登录（用于 app 内回复）"
                            ) { Chevron() }
                        }
                        .buttonStyle(.plain)
                        RowSeparator(leadingInset: 54)

                        // 这个开关依赖登录态，跟着账号走才讲得通；它原本落在
                        // 偏好项下面，读起来像是和外观、阅读并列的东西。
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("自动同步关注节点")
                                    .font(.system(size: 17))
                                    .kerning(-0.43)
                                    .foregroundStyle(Theme.ink)
                                Text(session.isLoggedIn
                                    ? "登录 \(session.username) 后自动同步网页收藏的节点"
                                    : "登录 V2EX 后自动同步网页收藏的节点")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Toggle("", isOn: $settings.autoSyncFollowedNodes)
                                .labelsHidden()
                                .disabled(!session.isLoggedIn)
                        }
                        .padding(.horizontal, Theme.Metric.cardPadding)
                        .frame(minHeight: Theme.Metric.rowHeight)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    GroupHeader(title: "偏好")
                    CardSection {
                        NavigationLink(value: Route.appearance) {
                            SettingsRow(icon: "paintbrush", iconColor: Theme.accent, title: "外观") {
                                Chevron()
                            }
                        }
                        .buttonStyle(.plain)
                        RowSeparator(leadingInset: 54)

                        NavigationLink(value: Route.reading) {
                            SettingsRow(
                                icon: "book",
                                iconColor: Theme.accent,
                                title: "阅读与离线",
                                subtitle: "阅读进度、自动离线与缓存"
                            ) { Chevron() }
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    GroupHeader(title: "AI 摘要")
                    CardSection {
                        NavigationLink(value: Route.aiConfiguration) {
                            SettingsRow(
                                icon: "sparkles",
                                iconColor: Theme.accent,
                                title: "自定义 AI API",
                                subtitle: aiConfiguration.isConfigured
                                    ? "已配置 · \(aiConfiguration.providerName ?? aiConfiguration.model)"
                                    : "Apple Intelligence 不可用时作为回退"
                            ) { Chevron() }
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    GroupHeader(title: "实验性功能")
                    CardSection {
                        HStack(spacing: 14) {
                            Image(systemName: "flask")
                                .font(.system(size: 17))
                                .foregroundStyle(settings.hackerNewsEnabled ? Theme.accent : Theme.faint)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Hacker News")
                                    .font(.system(size: 17))
                                    .kerning(-0.43)
                                    .foregroundStyle(Theme.ink)
                                Text("在首页分类条末尾加一页，支持端上翻译为中文")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Toggle("", isOn: $settings.hackerNewsEnabled).labelsHidden()
                        }
                        .padding(.horizontal, Theme.Metric.cardPadding)
                        .padding(.vertical, 10)

                        if settings.hackerNewsEnabled {
                            RowSeparator(leadingInset: 54)
                            HStack(spacing: 14) {
                                Color.clear.frame(width: 22)
                                Text("入口位置")
                                    .font(.system(size: 17))
                                    .kerning(-0.43)
                                    .foregroundStyle(Theme.ink)
                                Spacer(minLength: 8)
                                Picker("", selection: $settings.hackerNewsPlacement) {
                                    ForEach(HackerNewsPlacement.allCases) { placement in
                                        Text(placement.title).tag(placement)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 190)
                            }
                            .padding(.horizontal, Theme.Metric.cardPadding)
                            .padding(.vertical, 10)
                        }
                    }

                    Text("这里的功能可能不稳定，也可能在后续版本中移除。")
                        .font(Type.label(11))
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, Theme.Metric.headerPadding)
                        .padding(.top, 6)
                }

                VStack(alignment: .leading, spacing: 0) {
                    GroupHeader(title: "关于")
                    CardSection {
                        // Apple 1.2 / 5.1.1(i)：条款、隐私政策和支持联系方式
                        // 都必须在 App 内够得着，不能只留在商店页面上。
                        NavigationLink(value: Route.terms) {
                            SettingsRow(
                                icon: "checkmark.shield",
                                iconColor: Theme.accent,
                                title: "使用条款与社区规范",
                                subtitle: "举报、屏蔽与社区规范说明"
                            ) {
                                Chevron()
                            }
                        }
                        .buttonStyle(.plain)
                        RowSeparator(leadingInset: 54)

                        Button {
                            openURL(ReportService.privacyPolicyURL)
                        } label: {
                            SettingsRow(
                                icon: "lock.shield",
                                iconColor: Theme.accent,
                                title: "隐私政策",
                                subtitle: "外部 AI 仅在用户配置并主动生成时调用"
                            ) {
                                Chevron()
                            }
                        }
                        .buttonStyle(.plain)
                        RowSeparator(leadingInset: 54)

                        NavigationLink(value: Route.blocked) {
                            SettingsRow(
                                icon: "nosign",
                                iconColor: Theme.accent,
                                title: "内容与屏蔽",
                                subtitle: "屏蔽名单、已隐藏的内容与举报记录"
                            ) {
                                Chevron()
                            }
                        }
                        .buttonStyle(.plain)
                        RowSeparator(leadingInset: 54)

                        Button {
                            guard let url = URL(string: "mailto:\(ReportService.supportEmail)") else { return }
                            openURL(url)
                        } label: {
                            SettingsRow(
                                icon: "envelope",
                                iconColor: Theme.accent,
                                title: "联系开发者",
                                subtitle: ReportService.supportEmail
                            ) {
                                Chevron()
                            }
                        }
                        .buttonStyle(.plain)
                        RowSeparator(leadingInset: 54)

                        Button {
                            openURL(URL(string: "https://www.v2ex.com/help/api")!)
                        } label: {
                            SettingsRow(icon: "doc.text", iconColor: Theme.accent, title: "V2EX API 文档") {
                                Chevron()
                            }
                        }
                        .buttonStyle(.plain)
                        RowSeparator(leadingInset: 54)

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
        // 设置是一条向下钻的支线，底部标签栏留着只会诱人半路跳走。
        .toolbar(.hidden, for: .tabBar)
    }
}

struct AIConfigurationView: View {
    private enum Preset: String, CaseIterable, Identifiable {
        case deepSeek, siliconFlow, openAI, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .deepSeek: return "DeepSeek"
            case .siliconFlow: return "硅基流动"
            case .openAI: return "OpenAI"
            case .custom: return "自定义"
            }
        }

        var baseURL: String? {
            switch self {
            case .deepSeek: return "https://api.deepseek.com/v1"
            case .siliconFlow: return "https://api.siliconflow.cn/v1"
            case .openAI: return "https://api.openai.com/v1"
            case .custom: return nil
            }
        }

        var model: String? {
            switch self {
            case .deepSeek: return "deepseek-chat"
            case .siliconFlow: return "Qwen/Qwen3-8B"
            case .openAI: return "gpt-4.1-mini"
            case .custom: return nil
            }
        }
    }

    @EnvironmentObject private var configuration: AIConfigurationStore

    @State private var preset: Preset = .deepSeek
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var statusMessage: String?
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardSection(padding: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("OpenAI 兼容 API")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            Text("Apple Intelligence 不可用时，摘要请求会发送到你配置的服务。API Key 只保存在系统钥匙串。")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Picker("服务商", selection: $preset) {
                            ForEach(Preset.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: preset) { _, value in
                            guard value != .custom else { return }
                            baseURL = value.baseURL ?? baseURL
                            model = value.model ?? model
                        }

                        fieldLabel("API Key")
                        SecureField("sk-…", text: $apiKey)
                            .font(.system(size: 14, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .inputFieldStyle()

                        fieldLabel("API Base URL")
                        TextField("https://api.example.com/v1", text: $baseURL)
                            .font(.system(size: 14, design: .monospaced))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .inputFieldStyle()

                        fieldLabel("模型")
                        TextField("model-name", text: $model)
                            .font(.system(size: 14, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .inputFieldStyle()

                        HStack(spacing: 12) {
                            Button {
                                save()
                            } label: {
                                Label(saved ? "已保存" : "保存配置", systemImage: saved ? "checkmark" : "key")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)

                            if configuration.isConfigured {
                                Button("清除", role: .destructive) {
                                    configuration.clear()
                                    apiKey = ""
                                    saved = false
                                    statusMessage = "已清除 API Key"
                                }
                                .font(.system(size: 14))
                            }
                        }

                        if let statusMessage {
                            Text(statusMessage)
                                .font(.system(size: 12))
                                .foregroundStyle(saved ? Theme.accent : Theme.unreadDot)
                        }
                    }
                }

                CardSection(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("隐私提醒", systemImage: "lock.shield")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("使用外部 API 时，当前话题正文和部分回复会发送给所选服务商。请确认你接受该服务商的隐私政策与费用规则。V2EX 登录信息、Token 和 Cookie 不会发送。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("自定义 AI API")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { load() }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.muted)
    }

    private func load() {
        apiKey = configuration.apiKey
        baseURL = configuration.baseURL
        model = configuration.model
        if baseURL.contains("deepseek") { preset = .deepSeek }
        else if baseURL.contains("siliconflow") { preset = .siliconFlow }
        else if baseURL.contains("openai") { preset = .openAI }
        else { preset = .custom }
    }

    private func save() {
        do {
            try configuration.save(apiKey: apiKey, baseURL: baseURL, model: model)
            saved = true
            statusMessage = "已保存，设备端模型不可用时会自动使用 \(configuration.providerName ?? model)"
        } catch {
            saved = false
            statusMessage = error.localizedDescription
        }
    }
}

private extension View {
    func inputFieldStyle() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                        SettingsRow(icon: "safari", iconColor: Theme.accent, title: "打开 Token 设置页") {
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
        .toolbar(.hidden, for: .tabBar)
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
