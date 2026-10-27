import Foundation

/// 本机 Clash 代理（127.0.0.1:7897，规则模式：境外走代理、国内直连）。
/// Clash 没开时不走代理，否则所有下载都会失败；启动时检测一次，下载前各处读 isUp。
enum LocalProxy {
    static let host = "127.0.0.1"
    static let port = 7897
    static var url: String { "http://\(host):\(port)" }
    nonisolated(unsafe) static var isUp = true

    /// 能连上端口、拿到任何 HTTP 回应就算在运行
    static func check() async {
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 1.5
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        isUp = (try? await URLSession(configuration: cfg).data(for: req)) != nil
    }

    /// 给 URLSession 用的代理设置；Clash 没开时为空（直连）
    static var sessionDictionary: [AnyHashable: Any] {
        isUp ? ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port, "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port] : [:]
    }

    /// 给 yt-dlp 的参数
    static var ytdlpArguments: [String] { isUp ? ["--proxy", url] : [] }
}
