import SwiftUI
import WebKit

/// 用 PikPak 官方网页登录：密码只在 PikPak 自己的网页里输，闪电下载不经手。
/// 登录后读网页存的 credentials_<client_id> 和 deviceid，交给 PikPak.adoptWebSession，然后删掉网页里的那份——
/// 每次刷新会作废旧的 refresh token，同一份会话只能有一个刷新者（做法参照开源项目 peach 的 ADR-0093）
struct PikPakLoginView: View {
    var onDone: (String?) -> Void
    @State private var status = "在下面的网页里登录 PikPak，登录后会自动关联"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.shield").foregroundStyle(Theme.tint)
                Text(status).font(.system(size: 13))
                Spacer()
                Button("取消") { onDone(nil) }
            }
            .padding(.horizontal, 16).frame(height: 44)
            Divider()
            PikPakWebView { cred in
                status = "已登录，正在关联…"
                Task {
                    await PikPak.shared.adoptWebSession(clientID: cred.clientID, deviceID: cred.deviceID, accessToken: cred.access,
                                                        refreshToken: cred.refresh, userID: cred.sub, name: cred.name)
                    onDone(cred.name)
                }
            }
        }
        .frame(width: 900, height: 680)
    }
}

struct WebCredential { var clientID, deviceID, access, refresh, sub, name: String }

private struct PikPakWebView: NSViewRepresentable {
    var onCredential: (WebCredential) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCredential: onCredential) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 网页脚本运行前先删掉旧的登录信息：网页总从未登录开始，不会拿旧 token 去刷新、也不会被当成新登录读回来
        let clear = "Object.keys(localStorage).filter(k => k.startsWith('credentials_')).forEach(k => localStorage.removeItem(k));"
        cfg.userContentController.addUserScript(WKUserScript(source: clear, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.uiDelegate = context.coordinator   // Google、Apple 登录会开新窗口，改在同一个窗口里打开
        v.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        v.load(URLRequest(url: URL(string: "https://mypikpak.com/drive/login")!))
        context.coordinator.start(v)
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {}

    @MainActor final class Coordinator: NSObject, WKUIDelegate {
        let onCredential: (WebCredential) -> Void
        private var timer: Timer?
        private var taken = false
        init(onCredential: @escaping (WebCredential) -> Void) { self.onCredential = onCredential }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        func start(_ v: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak v] _ in
                MainActor.assumeIsolated { if let v { self?.check(v) } }
            }
        }

        private func check(_ v: WKWebView) {
            guard !taken else { return }
            let js = """
            (() => { const k = Object.keys(localStorage).find(k => k.startsWith('credentials_'));
              if (!k) return null; const c = JSON.parse(localStorage.getItem(k) || '{}');
              if (!c.access_token || !c.refresh_token) return null;
              const r = JSON.stringify({ key: k, c, device: localStorage.getItem('deviceid') || '' });
              localStorage.removeItem(k); return r; })()
            """
            v.evaluateJavaScript(js) { [weak self] result, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.taken, let str = result as? String, let d = str.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let key = o["key"] as? String, let c = o["c"] as? [String: Any] else { return }
                    self.taken = true; self.timer?.invalidate()
                    // 键名形如 credentials_<client_id>（多账号时后面还有 @<sub>）
                    let client = String(key.dropFirst("credentials_".count).split(separator: "@").first ?? "")
                    var device = o["device"] as? String ?? ""
                    if device.hasPrefix("\"") { device = device.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                    let sub = c["sub"] as? String ?? (c["user_id"] as? String ?? "")
                    let name = (c["username"] as? String) ?? (c["email"] as? String) ?? "PikPak 账号"
                    self.onCredential(WebCredential(clientID: client.isEmpty ? PikPak.web.clientID : client, deviceID: device,
                                                    access: c["access_token"] as? String ?? "", refresh: c["refresh_token"] as? String ?? "",
                                                    sub: sub, name: name))
                }
            }
        }
    }
}
