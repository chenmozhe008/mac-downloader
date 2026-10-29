import Foundation

/// 代理跟浏览器一样读系统设置（10-28：原先写死 127.0.0.1:7897，系统代理关了或换了端口就和浏览器不一致）。
/// 系统代理没开、或开了但连不上时不走代理，否则所有下载都会失败；启动时检测一次，下载前各处读 isUp。
/// 本机是 Clash 规则模式（10-28 确认），经过它的国内站也会按 IP 直连，下面的国内名单只是少绕一道。
///
/// 什么走代理（10-28 用户定：电影一般在国内下，别一刀切走代理）：
/// - 磁力 / 种子：一律直连。内核的全局代理关掉——开着时 BT 连其他用户也绕 Clash，
///   10-28 实测《求救信号》全部连接走 7897、上传为 0，速度在几 KB 到 4 MB/s 间乱跳
/// - HTTP 直链、视频网站：按域名判断，国内站直连，其余（YouTube、X、GitHub 等）单个任务走代理
enum LocalProxy {
    nonisolated(unsafe) static var host = "127.0.0.1"
    nonisolated(unsafe) static var port = 7897
    static var url: String { "http://\(host):\(port)" }
    nonisolated(unsafe) static var isUp = true

    /// 读系统代理（优先 HTTPS 那一项），能连上、拿到任何 HTTP 回应就算可用
    static func check() async {
        let sys = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        let pick: (String) -> (String, Int)? = { p in
            guard (sys[p + "Enable"] as? Int) == 1, let h = sys[p + "Proxy"] as? String, !h.isEmpty,
                  let port = sys[p + "Port"] as? Int else { return nil }
            return (h, port)
        }
        guard let (h, p) = pick("HTTPS") ?? pick("HTTP") else { isUp = false; return }
        host = h; port = p
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

    /// 国内站点：后缀命中就直连。没列到的境外站交给 Clash 规则再判断一次，国内 IP 仍会直连
    static let domesticSuffixes = [
        ".cn", "baidu.com", "bdstatic.com", "bcebos.com", "baidupcs.com", "aliyun.com", "aliyuncs.com", "alicdn.com", "aliyundrive.com", "alipan.com",
        "quark.cn", "qq.com", "gtimg.com", "myqcloud.com", "tencent-cloud.com", "weiyun.com", "163.com", "126.net", "netease.com",
        "bilibili.com", "bilivideo.com", "bilivideo.cn", "hdslb.com", "b23.tv", "weibo.com", "sinaimg.cn", "sina.com",
        "douyin.com", "douyinvod.com", "douyincdn.com", "zjcdn.com", "amemv.com", "snssdk.com", "ixigua.com", "bytedance.com", "byteimg.com", "volces.com", "xiaohongshu.com", "xhscdn.com",
        "kuaishou.com", "kwaicdn.com", "kwimgs.com", "yximgs.com", "iqiyi.com", "youku.com", "mgtv.com", "sohu.com", "xunlei.com", "115.com", "123pan.com", "lanzou.com", "lanzoui.com",
        "huaweicloud.com", "myhuaweicloud.com", "ctyun.cn", "jd.com", "taobao.com", "tmall.com", "zhihu.com", "csdn.net", "gitee.com",
        "dytt89.com", "btsj6.com",
    ]

    /// 这个链接要不要走代理（Clash 没开时一律不走）
    static func needed(for link: String) -> Bool {
        guard isUp, let host = URL(string: link)?.host?.lowercased() else { return false }
        if host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("192.168.") || host.hasPrefix("10.") { return false }
        return !domesticSuffixes.contains { host == $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) || host.hasSuffix($0.hasPrefix(".") ? $0 : "." + $0) }
    }

    /// 给内核单个任务的代理设置
    static func engineRequest(for link: String) -> [String: Any] {
        needed(for: link) ? ["mode": "custom", "scheme": "http", "host": "\(host):\(port)", "usr": "", "pwd": ""] : ["mode": "none"]
    }

    /// 给 yt-dlp 的参数
    static func ytdlpArguments(for link: String) -> [String] { needed(for: link) ? ["--proxy", url] : [] }

    /// 给 URLSession 的代理设置（按链接判断）
    static func sessionDictionary(for link: String) -> [AnyHashable: Any] { needed(for: link) ? sessionDictionary : [:] }
}
