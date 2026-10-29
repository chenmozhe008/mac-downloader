import AppKit

/// 检查更新（沿用小清）：每天最多查一次 GitHub 最新正式版的版本号，有新版时侧栏底部的版本号变成「新版本 X」。
/// 只读版本号、不上传任何东西；不做自动安装（没公证，自己替换自己会被 Gatekeeper 拦）。
/// `releases/latest` 不含预发布，Windows 的 `win-v<版本>` 不会被当成 Mac 新版
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let page: URL
    }

    @Published private(set) var available: Release?
    @Published var automatic = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automatic, forKey: Keys.automatic)
            if automatic { checkIfDue() } else { available = nil }
        }
    }

    private static let latestAPI = URL(string: "https://api.github.com/repos/chenmozhe008/shandian-download/releases/latest")!

    private enum Keys {
        static let automatic = "updateAutoCheck"
        static let lastCheck = "updateLastCheck"
        static let latestVersion = "updateLatestVersion"
        static let latestPage = "updateLatestPage"
    }

    /// 启动时：一天内查过就用上次的结果，否则去 GitHub 查
    func checkIfDue() {
        // `SHANDIAN_PRETEND_UPDATE=9.9.9`：不发版也能看到提示（截图验证用）
        if let pretend = ProcessInfo.processInfo.environment["SHANDIAN_PRETEND_UPDATE"] {
            available = Release(version: pretend, page: URL(string: "https://github.com/chenmozhe008/shandian-download/releases/latest")!)
            return
        }
        guard automatic, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Keys.lastCheck) as? Date, Date().timeIntervalSince(last) < 86_400 {
            if let version = defaults.string(forKey: Keys.latestVersion),
               let page = defaults.string(forKey: Keys.latestPage).flatMap(URL.init(string:)) {
                show(Release(version: version, page: page))
            }
            return
        }
        Task { await check() }
    }

    /// 立即查一次；没网或 GitHub 没回应时返回 nil
    @discardableResult
    func check() async -> Release? {
        var request = URLRequest(url: Self.latestAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let release = Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page)
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: Keys.lastCheck)
        defaults.set(release.version, forKey: Keys.latestVersion)
        defaults.set(page.absoluteString, forKey: Keys.latestPage)
        show(release)
        return release
    }

    /// 菜单「检查更新…」：立即查，弹窗说结果
    func checkFromMenu() {
        Task {
            let release = await check()
            let alert = NSAlert()
            if let release, Self.isNewer(release.version, than: AppInfo.version) {
                alert.messageText = "新版本 \(release.version) 可用"
                alert.informativeText = "当前版本 \(AppInfo.version)。在下载页选择与本机芯片对应的安装包（Apple 芯片或 Intel），解压后替换「应用程序」中的闪电全能下载。"
                alert.addButton(withTitle: "前往下载")
                alert.addButton(withTitle: "以后")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
            } else {
                alert.messageText = release == nil ? "无法检查更新" : "闪电全能下载已是最新版本"
                alert.informativeText = release == nil ? "未能连接 GitHub，请检查网络后重试。" : "当前版本 \(AppInfo.version)。"
                alert.runModal()
            }
        }
    }

    func openDownload() {
        if let available { NSWorkspace.shared.open(available.page) }
    }

    private func show(_ release: Release) {
        available = automatic && Self.isNewer(release.version, than: AppInfo.version) ? release : nil
    }

    /// 按数字逐段比：0.10.0 比 0.9.2 新。开发版不提示
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parse = { (value: String) in value.split(separator: ".").map { Int($0) } }
        let new = parse(candidate), old = parse(current)
        guard !new.contains(nil), !old.contains(nil), !old.isEmpty else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index]! : 0
            let b = index < old.count ? old[index]! : 0
            if a != b { return a > b }
        }
        return false
    }
}
