import Foundation

/// 抖音、小红书不登录拿不到视频地址。用户在浏览器里登录着，浏览器扩展下载时把这两家的 Cookie 一起带来，
/// 存成 yt-dlp 认的 cookies.txt（每家一个，600 权限，只给本机 yt-dlp 用），下载这两家时带上。
enum SiteCookies {
    static let domains = ["douyin.com", "iesdouyin.com", "xiaohongshu.com", "xhslink.com"]

    static func site(of link: String) -> String? {
        guard let host = URL(string: link)?.host?.lowercased() else { return nil }
        if host.hasSuffix("douyin.com") { return "douyin" }
        if host.hasSuffix("xiaohongshu.com") || host.hasSuffix("xhslink.com") { return "xhs" }
        return nil
    }

    static func file(for site: String) -> URL { EngineConfig.supportDir.appendingPathComponent("cookies-\(site).txt") }

    /// 扩展传来的 Cookie：[{domain, path, secure, expires, name, value}]
    static func save(_ cookies: [[String: Any]], for link: String) {
        guard let site = site(of: link), !cookies.isEmpty else { return }
        var lines = ["# Netscape HTTP Cookie File", "# 闪电下载：浏览器扩展带来的登录信息，供 yt-dlp 使用"]
        for c in cookies {
            guard let name = c["name"] as? String, let value = c["value"] as? String, var domain = c["domain"] as? String else { continue }
            if !domain.hasPrefix(".") { domain = "." + domain }
            let expiry = Int((c["expires"] as? Double) ?? Date().addingTimeInterval(86400 * 30).timeIntervalSince1970)
            lines.append([domain, "TRUE", c["path"] as? String ?? "/", (c["secure"] as? Bool ?? false) ? "TRUE" : "FALSE", "\(expiry)", name, value]
                .joined(separator: "\t"))
        }
        let f = file(for: site)
        try? (lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
    }

    static func ytdlpArguments(for link: String) -> [String] {
        guard let site = site(of: link) else { return [] }
        let f = file(for: site)
        return FileManager.default.fileExists(atPath: f.path) ? ["--cookies", f.path] : []
    }
}
