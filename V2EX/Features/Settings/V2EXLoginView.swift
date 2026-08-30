import SwiftUI

/// V2EX 网页登录：账号密码 + 验证码，成功后把会话 cookie 存进 Keychain。
/// 官方 API 没有发帖/回复接口，只有网页表单能写——登录一次即可在 app 内
/// 直接回复，不用跳浏览器。
struct V2EXLoginView: View {
    @EnvironmentObject private var session: V2EXSessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var captcha = ""
    @State private var captchaImage: Data?
    @State private var captchaLoadFailed = false
    @State private var challenge: V2EXClient.SignInChallenge?
    @State private var needsTwoFactor = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showWebLogin = false

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        !captcha.isEmpty &&
        !isBusy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if session.isLoggedIn {
                    loggedInCard
                } else {
                    // 主入口：网页登录（底部弹窗，浏览器环境天然通过所有校验）。
                    Button {
                        showWebLogin = true
                    } label: {
                        Label("在网页中登录", systemImage: "globe")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.Metric.headerPadding)
                }
            }
            .readableColumn()
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("V2EX 登录")
        .navigationBarTitleDisplayMode(.large)
        // 设置是一条向下钻的支线，底部标签栏留着只会诱人半路跳走。
        .toolbar(.hidden, for: .tabBar)
        // 两步验证直接弹出，不留在页面里。
        .sheet(isPresented: $needsTwoFactor) {
            TwoFactorSheet(onDone: { dismiss() })
        }
        // 网页登录：底部弹窗。
        .sheet(isPresented: $showWebLogin, onDismiss: {
            // 先让网页弹层完成关闭，再退出这一层登录页，避免两个 dismiss
            // 在同一轮状态更新里互相覆盖。
            if session.isLoggedIn {
                dismiss()
            }
        }) {
            WebLoginSheet()
        }
        .onChange(of: session.isLoggedIn) { _, isLoggedIn in
            // 登录回调先保存 session；父页面观察这份唯一状态并负责收起弹层。
            // 即使 WebView 的回调与页面重绘发生在同一帧，也不会漏掉关闭动作。
            if isLoggedIn {
                showWebLogin = false
            }
        }
    }

    // MARK: - Form

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardSection(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("登录后可在 app 内回复")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("V2EX 的官方 API 没有发回复的接口，只有网页表单能发。用 V2EX 账号登录一次，app 会保存网页会话（cookie 存钥匙串），之后发回复和回复某用户都在 app 内完成。")
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("用户名或邮箱", text: $username)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    SecureField("密码", text: $password)
                        .font(.system(size: 15))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            if let captchaImage, let image = UIImage(data: captchaImage) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            } else if captchaLoadFailed {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.inset)
                                    .frame(height: 80)
                                    .overlay {
                                        VStack(spacing: 4) {
                                            Text("验证码加载失败")
                                                .font(.system(size: 12))
                                                .foregroundStyle(Theme.unreadDot)
                                            Button("重试") {
                                                Task { await loadCaptcha() }
                                            }
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.accent)
                                            .buttonStyle(.plain)
                                        }
                                    }
                            } else {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.inset)
                                    .frame(height: 80)
                                    .overlay {
                                        Text("验证码加载中…")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.muted)
                                    }
                            }

                            Button("换一张") {
                                Task { await loadCaptcha() }
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .buttonStyle(.plain)
                        }

                        TextField("输入图中验证码", text: $captcha)
                            .font(.system(size: 15))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.unreadDot)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        Task { await signIn() }
                    } label: {
                        Text(isBusy ? "登录中…" : "登录")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(canSubmit ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.accent.opacity(0.4)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                }
            }

            Text("密码只用于本次登录请求，不会保存；会话 cookie 存钥匙串。登录后可以随时在此退出。")
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, Theme.Metric.headerPadding)
        }
    }

    // MARK: - Logged in

    private var loggedInCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardSection(padding: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent)
                        Text(String(session.username.prefix(2)).lowercased())
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.username)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("网页会话已连接，可在 app 内发回复")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }

            Button(role: .destructive) {
                session.clear()
                username = ""
                password = ""
                captcha = ""
                errorMessage = nil
            } label: {
                Text("退出登录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.unreadDot)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.unreadDot.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Metric.screenPadding)
        }
    }

    // MARK: - Actions

    /// 验证码与 once 绑定同一次会话：challenge 和图片一起取，登录时复用。
    private func loadCaptcha() async {
        captchaLoadFailed = false
        do {
            let fresh = try await V2EXClient.shared.signInChallenge()
            challenge = fresh
            captchaImage = try await V2EXClient.shared.captchaImage(once: fresh.once)
            // 拿到的可能不是图片（风控页等），解不出就按失败处理。
            captchaLoadFailed = UIImage(data: captchaImage ?? Data()) == nil
            captcha = ""
            errorMessage = nil
        } catch {
            captchaImage = nil
            captchaLoadFailed = true
            errorMessage = (error as? V2EXError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func signIn() async {
        guard let challenge else {
            await loadCaptcha()
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let result = try await V2EXClient.shared.signIn(
                challenge: challenge,
                username: username,
                password: password,
                captcha: captcha
            )
            session.save(cookie: result.cookie, username: result.username)
            if result.needsTwoFactor {
                needsTwoFactor = true
                errorMessage = nil
            } else if await V2EXClient.shared.verifySession(cookie: result.cookie) {
                dismiss()
            } else {
                // 会话验证失败：不保存无效状态。
                session.clear()
                errorMessage = "登录状态验证失败，请重试"
                await loadCaptcha()
            }
        } catch {
            errorMessage = (error as? V2EXError)?.errorDescription ?? error.localizedDescription
            await loadCaptcha()
        }
    }

}

/// 两步验证弹出层：登录（账号/密码/验证码）通过后，如果账号开启了 2FA，
/// 用这个 sheet 输入 TOTP 码，完成后再关闭整个登录页。
private struct TwoFactorSheet: View {
    @EnvironmentObject private var session: V2EXSessionStore
    @Environment(\.dismiss) private var dismiss

    /// 2FA 成功后关闭整个登录页。
    var onDone: () -> Void

    @State private var code = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    private var canSubmit: Bool { code.count >= 6 && !isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardSection(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("两步验证")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("账号已开启两步验证。打开身份验证器（如 Google Authenticator），输入当前的 6 位验证码。")
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("6 位验证码", text: $code)
                        .font(.system(size: 20, design: .monospaced))
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.unreadDot)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        Text(isBusy ? "验证中…" : "验证并登录")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                canSubmit ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.accent.opacity(0.4)),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                }
            }

            Button("返回重新登录") {
                session.clear()
                dismiss()
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.muted)
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Metric.headerPadding)
        }
        .padding(.top, 24)
        .padding(.horizontal, Theme.Metric.screenPadding)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
    }

    private func submit() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let once = try await V2EXClient.shared.twoFactorOnce(cookie: session.cookie)
            guard let freshCookie = try await V2EXClient.shared.signInTwoFactor(
                code: code, once: once, cookie: session.cookie
            ) else {
                errorMessage = "两步验证码不正确。请检查身份验证器的手机时间是否准确（TOTP 依赖时钟同步），然后重试。"
                code = ""
                return
            }
            // 2FA 通过后 V2EX 刷新了会话 —— 用新 cookie 更新登录状态。
            session.save(cookie: freshCookie, username: session.username)
            if await V2EXClient.shared.verifySession(cookie: freshCookie) {
                dismiss()
                onDone()
            } else {
                session.clear()
                errorMessage = "两步验证通过但会话验证失败，请重新登录"
            }
        } catch {
            if case V2EXError.sessionExpired = error {
                session.clear()
                errorMessage = "两步验证会话已过期，请重新登录"
            } else {
                errorMessage = (error as? V2EXError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// 网页登录弹窗：底部弹出，内嵌浏览器完成登录后自动关闭。
private struct WebLoginSheet: View {
    @EnvironmentObject private var session: V2EXSessionStore
    @Environment(\.dismiss) private var dismiss

    /// 网页端登录表单已消失、正在验证会话（可能一两秒），期间显示浮层提示。
    @State private var isVerifying = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部玻璃条：标题 + 副标题 + 圆形关闭按钮。
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("网页登录")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("登录后可在 app 内直接回复")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            Divider().opacity(0.3)

            WebLoginView { cookie, username in
                session.save(cookie: cookie, username: username)
            } onVerifyingChanged: { verifying in
                isVerifying = verifying
            }
            .overlay(alignment: .bottom) {
                if isVerifying {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("登录成功，正在验证会话…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isVerifying)
        }
        .background(Theme.canvas)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
