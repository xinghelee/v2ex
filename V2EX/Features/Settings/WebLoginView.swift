import SwiftUI
import WebKit

/// 网页登录容器：内嵌 WKWebView 加载 v2ex.com/signin，用户像用浏览器一样
/// 登录（验证码、两步验证都正常）。判定成功的唯一标准是拿 WebView 的 cookie
/// 请求 `/settings` 能停在 `/settings`——页面长得像已登录不算数，两步验证没走完
/// 时页面同样是那个样子。确认后把完整会话 cookie 交给 `V2EXSessionStore`。
struct WebLoginView: UIViewRepresentable {
    /// 登录成功回调：cookie 字符串 + 用户名（从页面提取）。
    var onLoggedIn: (String, String) -> Void
    /// 登录表单已消失、正在验证会话时为 true。验证含重试与一次网络请求，
    /// 可能持续一两秒，外层用它显示 loading，避免看起来像卡住。
    var onVerifyingChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        context.coordinator.attach(to: webView)
        webView.load(URLRequest(url: URL(string: "https://www.v2ex.com/signin")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
        coordinator.detach()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        private let parent: WebLoginView
        private weak var webView: WKWebView?
        private var notified = false
        private var isChecking = false
        private var hasFinishedNavigation = false
        private var isVerifyingUI = false

        init(_ parent: WebLoginView) { self.parent = parent }

        func attach(to webView: WKWebView) {
            self.webView = webView
            webView.configuration.websiteDataStore.httpCookieStore.add(self)
        }

        func detach() {
            webView = nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            hasFinishedNavigation = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasFinishedNavigation = true
            detectLogin(in: webView, retriesRemaining: 6)
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            // 有些登录方式只更新 Cookie 或原地替换页面，不一定产生可依赖的 URL 跳转。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hasFinishedNavigation, let webView = self.webView else { return }
                self.detectLogin(in: webView, retriesRemaining: 6)
            }
        }

        /// V2EX 有时会在 `/signin` 这个地址直接返回登录后的首页，所以不能只靠
        /// URL 跳转判断。这里等登录表单消失后抓取 Cookie，再访问 `/settings`
        /// 验证会话确实有效；Cookie 写入稍有延迟时会短暂重试。
        private func detectLogin(in webView: WKWebView, retriesRemaining: Int) {
            let host = webView.url?.host?.lowercased()
            guard host == "v2ex.com" || host == "www.v2ex.com" else { return }
            // 两步验证页顶部已经渲染登录态导航，会话却只是半登录——而且它的表单
            // action 是 /2fa、验证码输入框不是 password，下面的 loginFormVisible
            // 一个都探测不到。在这里判成功会把一个发不了帖的 cookie 存进 Keychain，
            // 所以这个路径直接跳过；用户提交验证码离开本页后自然会再触发一次。
            guard webView.url?.path != "/2fa" else {
                setVerifying(false)
                return
            }
            guard !notified, !isChecking else { return }
            isChecking = true

            webView.evaluateJavaScript("""
                (function() {
                    var loginForm = document.querySelector('form[action*="signin"], input[type="password"]');
                    var memberLinks = Array.from(document.querySelectorAll('a[href^="/member/"]'));
                    var member = memberLinks.find(function(link) {
                        var inHeader = link.closest('#Top, header, #site-header-menu, .site-nav');
                        var top = link.getBoundingClientRect().top;
                        return !!inHeader || (top >= 0 && top < 180);
                    });
                    var avatar = member ? member.querySelector('img[alt]') : null;
                    var identity = member
                        ? (avatar ? avatar.getAttribute('alt') : member.getAttribute('href'))
                        : '';
                    return {
                        loginFormVisible: !!loginForm,
                        identity: identity || ''
                    };
                })()
            """) { [weak self, weak webView] result, _ in
                guard let self, let webView, !self.notified else { return }
                let page = result as? [String: Any]
                let loginFormVisible = page?["loginFormVisible"] as? Bool ?? true
                let username = (page?["identity"] as? String ?? "")
                    .replacingOccurrences(of: "/member/", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    DispatchQueue.main.async {
                        guard !self.notified else { return }
                        self.isChecking = false
                        // 表单一消失就进入"验证中"，重试或网络验证期间保持显示。
                        self.setVerifying(!loginFormVisible)

                        let activeV2EXCookies = cookies.filter { cookie in
                            cookie.domain.contains("v2ex.com") &&
                            (cookie.expiresDate.map { $0 > Date() } ?? true)
                        }
                        let cookie = activeV2EXCookies
                            .map { "\($0.name)=\($0.value)" }
                            .joined(separator: "; ")

                        // 登录表单消失只说明离开了表单页，页面顶部出现登录态导航也
                        // 只是「看起来像」——两步验证没走完时同样是这个样子。会话是否
                        // 真的可用一律以能否停在 /settings 为准，别用页面外观下结论。
                        guard !loginFormVisible, !cookie.isEmpty else {
                            self.scheduleRetry(
                                in: webView,
                                retriesRemaining: retriesRemaining
                            )
                            return
                        }

                        self.isChecking = true
                        Task {
                            let sessionIsValid = await V2EXClient.shared.verifySession(cookie: cookie)
                            await MainActor.run {
                                guard !self.notified else { return }
                                self.isChecking = false
                                if sessionIsValid {
                                    self.notified = true
                                    self.parent.onLoggedIn(cookie, username)
                                } else {
                                    self.scheduleRetry(
                                        in: webView,
                                        retriesRemaining: retriesRemaining
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        private func setVerifying(_ verifying: Bool) {
            guard isVerifyingUI != verifying else { return }
            isVerifyingUI = verifying
            parent.onVerifyingChanged(verifying)
        }

        private func scheduleRetry(in webView: WKWebView, retriesRemaining: Int) {
            isChecking = false
            guard retriesRemaining > 0 else {
                // 重试用尽仍没确认登录：收起提示，避免一直转圈。
                setVerifying(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.detectLogin(in: webView, retriesRemaining: retriesRemaining - 1)
            }
        }
    }
}
