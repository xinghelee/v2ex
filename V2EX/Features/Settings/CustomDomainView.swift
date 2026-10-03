import SwiftUI

/// Issue #2：访问不了 v2ex.com 时改走用户自建的反向代理。默认官方域名，
/// 不预置任何第三方地址；保存前可以先「测试连接」逐项检查反代是否完整。
struct CustomDomainView: View {
    @AppStorage(V2EXEndpoint.customBaseKey) private var savedBase = ""
    @AppStorage(V2EXEndpoint.customImageBaseKey) private var savedImageBase = ""

    @State private var base = ""
    @State private var imageBase = ""
    @State private var checks: [EndpointCheck] = []
    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private var isCustomized: Bool { !savedBase.isEmpty || !savedImageBase.isEmpty }

    private var usesPlainHTTP: Bool {
        [base, imageBase].contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardSection(padding: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("自建反向代理")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            Text("访问不了 v2ex.com 时，填写你自己搭建的反向代理。留空即使用官方域名。")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        fieldLabel("主站地址")
                        addressField(V2EXEndpoint.officialBase, text: $base)

                        fieldLabel("图片地址（可选）")
                        addressField("https://\(V2EXEndpoint.officialImageHost)", text: $imageBase)
                        Text("头像和帖子图片来自 \(V2EXEndpoint.officialImageHost)。它也打不开时，再填一个转发到它的反代。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)

                        if usesPlainHTTP {
                            Label("http 是明文传输，Token、Cookie 和登录密码可能被同一网络里的人看到。",
                                  systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.unreadDot)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 12) {
                            Button {
                                save()
                            } label: {
                                Label("保存", systemImage: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)

                            Button {
                                Task { await test() }
                            } label: {
                                Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.accent)
                            .disabled(isTesting)
                        }

                        if isCustomized {
                            Button("恢复官方域名", role: .destructive) { reset() }
                                .font(.system(size: 14))
                        }

                        if let statusMessage {
                            Text(statusMessage)
                                .font(.system(size: 12))
                                .foregroundStyle(statusIsError ? Theme.unreadDot : Theme.accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if isTesting || !checks.isEmpty {
                    CardSection(padding: 16) { results }
                }

                note(
                    title: "安全提醒",
                    icon: "lock.shield",
                    text: "填写后，所有发往 V2EX 的请求——包括 Access Token、登录 Cookie 和网页登录时输入的密码——都会经过这个地址。只填写你自己控制的反代。分享出去的链接仍然是官方域名。"
                )
                note(
                    title: "反代需要做到",
                    icon: "server.rack",
                    text: "主站反代把全部路径转发到 \(V2EXEndpoint.officialBase)，跳转（Location）和 Cookie 原样返回或改写成反代自己的地址，网页登录才能用；图片反代转发到 https://\(V2EXEndpoint.officialImageHost) 即可。不支持带路径的地址。"
                )
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("自定义域名")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            base = savedBase
            imageBase = savedImageBase
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(isTesting ? "正在测试…" : "测试结果")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if isTesting { ProgressView().controlSize(.small).tint(Theme.accent) }
            }
            ForEach(checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon(for: check.outcome))
                        .foregroundStyle(color(for: check.outcome))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        Text(check.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addressField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 14, design: .monospaced))
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .inputFieldStyle()
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.muted)
    }

    private func note(title: String, icon: String, text: String) -> some View {
        CardSection(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func icon(for outcome: EndpointCheck.Outcome) -> String {
        switch outcome {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(for outcome: EndpointCheck.Outcome) -> Color {
        switch outcome {
        case .passed: return Theme.accent
        case .warning: return Theme.amber
        case .failed: return Theme.unreadDot
        }
    }

    private func save() {
        do {
            let parsedBase = try V2EXEndpoint.parseOrigin(base)
            let parsedImageBase = try V2EXEndpoint.parseOrigin(imageBase)
            V2EXEndpoint.save(base: parsedBase, imageBase: parsedImageBase)
            base = V2EXEndpoint.customBase?.absoluteString ?? ""
            imageBase = V2EXEndpoint.customImageBase?.absoluteString ?? ""
            statusIsError = false
            statusMessage = base.isEmpty && imageBase.isEmpty
                ? "已使用官方域名"
                : "已保存。回到列表下拉刷新，就会通过新地址加载。"
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func reset() {
        V2EXEndpoint.save(base: nil, imageBase: nil)
        base = ""
        imageBase = ""
        checks = []
        statusIsError = false
        statusMessage = "已恢复官方域名"
    }

    /// 测的是输入框里的地址，不必先保存；主站留空时测官方域名本身能不能连上。
    private func test() async {
        let parsedBase: URL?
        let parsedImageBase: URL?
        do {
            parsedBase = try V2EXEndpoint.parseOrigin(base)
            parsedImageBase = try V2EXEndpoint.parseOrigin(imageBase)
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
            return
        }
        statusMessage = nil
        checks = []
        isTesting = true
        checks = await V2EXClient.shared.probe(
            base: parsedBase ?? URL(string: V2EXEndpoint.officialBase)!,
            imageBase: parsedImageBase
        )
        isTesting = false
    }
}
