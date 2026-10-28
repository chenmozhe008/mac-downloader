import Foundation

/// 链接分到哪个引擎、落到哪个目录
enum LinkKind: Equatable {
    case magnet, torrentFile, ed2k, videoSite, http

    static let videoHosts = ["bilibili.com", "b23.tv", "youtube.com", "youtu.be", "douyin.com", "xiaohongshu.com",
                             "xhslink.com", "kuaishou.com", "weibo.com", "ixigua.com", "vimeo.com", "x.com", "twitter.com", "xinpianchang.com"]

    static func of(_ raw: String) -> LinkKind? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.hasPrefix("magnet:?") { return .magnet }
        if lower.hasPrefix("ed2k://") { return .ed2k }
        if lower.hasSuffix(".torrent"), FileManager.default.fileExists(atPath: s) { return .torrentFile }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme),
              let host = url.host?.lowercased() else { return nil }
        if videoHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return .videoSite }
        if url.path.lowercased().hasSuffix(".torrent") { return .torrentFile }  // 网页上的种子链接，按种子处理（存影片目录、只选正片）
        return .http
    }

    var label: String {
        switch self {
        case .magnet: "磁力"
        case .torrentFile: "种子文件"
        case .ed2k: "ed2k"
        case .videoSite: "视频网站"
        case .http: "直链"
        }
    }

    static let fileExtensions: Set<String> = ["zip", "rar", "7z", "gz", "tgz", "bz2", "xz", "dmg", "pkg", "exe", "msi", "iso", "img", "apk", "ipa",
                                               "mp4", "mkv", "avi", "mov", "m4v", "ts", "flv", "wmv", "rmvb", "webm", "mp3", "flac", "wav", "m4a", "aac"]

    /// 复制后值得弹浮窗的链接：磁力、ed2k、种子、视频网站、网盘直链，以及以常见文件扩展名结尾的直链。普通网页地址不弹
    static func worthPopup(_ link: String) -> Bool {
        guard let kind = of(link) else { return false }
        if kind != .http { return true }
        guard let url = URL(string: link) else { return false }
        let host = url.host?.lowercased() ?? ""
        if DownloadStore.panHosts.contains(where: { host.contains($0.0) }) { return true }
        return fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// 从一段文字里找出所有能下的链接（粘贴一整段时用）
    static func extract(from text: String) -> [String] {
        let pattern = #"(magnet:\?[^\s"'<>]+|ed2k://[^\s"'<>]+|https?://[^\s"'<>]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let s = ns.substring(with: $0.range)
            return seen.insert(s).inserted ? s : nil
        }
    }
}

enum Category: String, CaseIterable, Identifiable {
    case movie = "电影", video = "视频", cloud = "网盘", other = "其他文件"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .movie: "film"
        case .video: "play.rectangle"
        case .cloud: "cloud"
        case .other: "doc"
        }
    }
}

enum Folders {
    static let defaultMovies = URL(fileURLWithPath: "/Volumes/Jack Feng/movies")
    static let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    /// 三类默认位置，偏好设置里可改（存 UserDefaults 的 dir.movie / dir.video / dir.other）
    static var movies: URL { custom("dir.movie") ?? defaultMovies }
    static var videos: URL { custom("dir.video") ?? downloads }   // 10-28 用户定：视频网站的直接放「下载」，不单建「视频」
    static var others: URL { custom("dir.other") ?? downloads }
    private static func custom(_ key: String) -> URL? { UserDefaults.standard.string(forKey: key).map { URL(fileURLWithPath: $0) } }
    /// 移动硬盘没插时电影的兜底位置
    static var moviesFallback: URL { downloads.appendingPathComponent("电影") }

    static var movieDir: URL {
        FileManager.default.fileExists(atPath: movies.path) ? movies : moviesFallback
    }
    static var diskMounted: Bool { FileManager.default.fileExists(atPath: movies.path) }

    /// 界面上说的位置名：移动硬盘 › movies、下载、下载 › 某文件夹
    static func displayName(_ d: URL) -> String {
        if d == defaultMovies { return "移动硬盘 › movies" }
        if d == downloads { return "下载" }
        if d.deletingLastPathComponent() == downloads { return "下载 › " + d.lastPathComponent }
        let c = d.pathComponents
        if c.count > 3, c[1] == "Volumes" { return c[2] + " › " + d.lastPathComponent }  // 其他硬盘：盘名 › 文件夹
        return FileManager.default.displayName(atPath: d.path)
    }

    static func directory(for kind: LinkKind) -> URL {
        switch kind {
        case .magnet, .torrentFile, .ed2k: movieDir
        case .videoSite: videos
        case .http: others
        }
    }
}

/// 种子里该勾哪些文件：主视频（最大的那个）＋ 体积相近的其他视频（剧集合集）＋ 字幕。
/// 样片、海报、同一部片的低清副本、说明文件都不下。没有视频的种子全选。
enum FileSelection {
    static let videoExt: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "ts", "m2ts", "webm", "wmv", "flv", "rmvb", "mpg", "mpeg", "ogv"]
    static let subtitleExt: Set<String> = ["srt", "ass", "ssa", "sub", "idx", "vtt", "sup"]

    static func pick(_ files: [EngineTask.Meta.File]) -> [Int]? {
        let ext = files.map { ($0.name as NSString).pathExtension.lowercased() }
        let videos = files.indices.filter { videoExt.contains(ext[$0]) && !isSample(files[$0].name) }
        guard let biggest = videos.map({ files[$0].size }).max(), biggest > 0 else { return nil }
        let big = videos.filter { Double(files[$0].size) >= Double(biggest) * 0.4 }
        // 同一部片的多个格式/码率（Jungle_Book.avi / .mp4 / _512kb.mp4）只留一个；剧集文件名各不相同，照样全留
        let keepVideos = Dictionary(grouping: big) { stem(files[$0].name) }.values.compactMap { group in
            group.max { (rank(ext[$0]), files[$0].size) < (rank(ext[$1]), files[$1].size) }
        }
        let subs = files.indices.filter { subtitleExt.contains(ext[$0]) }
        let picked = (keepVideos + subs).sorted()
        return picked.count == files.count ? nil : picked
    }

    /// 去掉扩展名和码率/画质后缀，用来判断是不是同一部片的不同版本
    private static func stem(_ name: String) -> String {
        var n = ((name as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        n = n.replacingOccurrences(of: #"[._\- ]?(512kb|256kb|1024kb|hq|lq|ia|low|high)$"#, with: "", options: .regularExpression)
        return n
    }

    /// 格式偏好：mp4/mkv 兼容最好，其次 avi/mov 等，ogv/webm/flv 最后
    private static func rank(_ ext: String) -> Int {
        switch ext {
        case "mp4", "mkv", "m4v": 3
        case "mov", "avi", "ts", "m2ts", "mpg", "mpeg", "wmv", "rmvb": 2
        default: 1
        }
    }

    private static func isSample(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("sample") || n.contains("预告") || n.contains("trailer")
    }
}

extension Int64 {
    /// 1.09 GB / 680 MB / 42 KB
    var bytesText: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.isAdaptive = true
        return f.string(fromByteCount: self).replacingOccurrences(of: "字节", with: "B")
    }
    var speedText: String { self < 1024 ? "0 KB/s" : bytesText + "/s" }
}

func remainingText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "" }
    let s = Int(seconds)
    if s < 60 { return "剩余 \(s) 秒" }
    if s < 3600 { return "剩余 \(s / 60) 分钟" }
    return "剩余 \(s / 3600) 小时 \(s % 3600 / 60) 分"
}

/// 把发布名整理成人能读的片名：Conclave.2024.1080p.AMZN.WEBRip-GalaxyRG → Conclave 2024
enum PrettyTitle {
    private static let junk = try! NSRegularExpression(pattern:
        #"(?i)\b(2160p|1080p|720p|480p|4k|uhd|hdr10?\+?|dv|blu-?ray|bdrip|brrip|web-?dl|webrip|web|hdtv|hr-hdtv|dvdrip|remux|x26[45]|h\.?26[45]|hevc|avc|10bit|8bit|aac(2\.0)?|ac3|dts(-hd)?( ma)?|ddp?5\.1|dd2\.0|truehd|atmos|5\.1|7\.1|2\.0|amzn|nf|hmax|hbomax|ddp|dsnp|proper|repack|extended|remastered|imax|chs|cht|eng|chs-eng|中英双字|国英双语|双语字幕|esub|multi)\b"#)

    static func clean(_ raw: String) -> String {
        var s = raw
        for ext in FileSelection.videoExt where s.lowercased().hasSuffix("." + ext) { s = String(s.dropLast(ext.count + 1)) }
        s = s.replacingOccurrences(of: #"\[[^\]]*\]|【[^】]*】"#, with: " ", options: .regularExpression)  // [YTS.MX] 【电影天堂】
        if !s.contains(" ") { s = s.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ") }
        // 年份之后基本都是技术参数，截到年份（片名开头的数字不算，如「2001太空漫游」）
        let yearRe = try! NSRegularExpression(pattern: #"(?<![0-9])(19[2-9][0-9]|20[0-4][0-9])(?![0-9])"#)
        let full = NSRange(location: 0, length: (s as NSString).length)
        if let m = yearRe.matches(in: s, range: full).last(where: { $0.range.location > 0 }),
           let r = Range(m.range, in: s) {
            s = String(s[..<r.upperBound])
            s = s.replacingOccurrences(of: #"\(\s*([0-9]{4})$"#, with: "$1", options: .regularExpression)  // Dreams (1990 → Dreams 1990
        }
        let ns = s as NSString
        let hadJunk = junk.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
        s = junk.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        s = s.replacingOccurrences(of: #"\b[0-9]{3,4}[xX×][0-9]{3,4}\b"#, with: " ", options: .regularExpression)  // 1024X576
        if hadJunk { s = s.replacingOccurrences(of: #"-[^\s\-0-9][^\s\-]*$"#, with: "", options: .regularExpression) }  // 结尾的 -GalaxyRG / -人人影视制作
        s = s.replacingOccurrences(of: #"[\s\-\.]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-·.")))
        if !s.contains(" ") { s = s.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression) }  // JungleBook → Jungle Book
        if s == s.lowercased(), s.range(of: #"[a-z]"#, options: .regularExpression) != nil { s = s.capitalized }       // his girl friday → His Girl Friday
        return s.isEmpty ? raw : s
    }
}
