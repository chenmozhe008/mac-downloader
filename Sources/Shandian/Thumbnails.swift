import AppKit
import Foundation

/// 缩略图缓存在 Application Support/ShandianDownload/thumbs/<任务 id>.jpg。
/// 电影：用 ffmpeg 从视频里截一帧（下到一部分也能截，失败过一会再试）；视频网站：下载站点给的封面。
@MainActor
final class Thumbnails: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    /// 电影海报（竖版），和截帧分开存：卡片上海报要整张显示，截帧铺满
    @Published private(set) var posters: [String: NSImage] = [:]
    private var posterTried = Set<String>()
    private var attempts: [String: (count: Int, last: Date)] = [:]
    private var inFlight = Set<String>()
    private(set) var remoteFailed = Set<String>()   // 站点封面取不到的，改从视频里截帧
    private let dir = EngineConfig.supportDir.appendingPathComponent("thumbs")
    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

    init() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    func image(for id: String) -> NSImage? {
        if let img = images[id] { return img }
        let file = dir.appendingPathComponent("\(id).jpg")
        if let img = NSImage(contentsOf: file) { images[id] = img; return img }
        return nil
    }

    /// 从本地视频文件截帧。progress 太低时文件头可能还没下到，跳过；失败最多重试 6 次、间隔 30 秒
    func requestFrame(id: String, video: URL, progress: Double) {
        guard images[id] == nil, image(for: id) == nil, !inFlight.contains(id), progress > 0.08 || progress >= 1 else { return }
        // BT 乱序下载，没下完的文件常截不出画面；下载中最多试 6 次，下完后另外再给 2 次
        let key = progress >= 1 ? id + "#done" : id
        if let a = attempts[key], a.count >= (progress >= 1 ? 2 : 6) || Date().timeIntervalSince(a.last) < 30 { return }
        guard let ffmpeg = Self.ffmpeg, FileManager.default.fileExists(atPath: video.path) else { return }
        inFlight.insert(id)
        attempts[key] = ((attempts[key]?.count ?? 0) + 1, Date())
        let out = dir.appendingPathComponent("\(id).jpg")
        Task.detached {
            // 片头常是黑场或片商标，取第 3 分钟左右；短片取第 10 秒
            var ok = false
            for ss in ["180", "10"] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ffmpeg)
                p.arguments = ["-v", "error", "-y", "-ss", ss, "-i", video.path, "-frames:v", "1", "-vf", "scale=480:-2", "-q:v", "4", out.path]
                p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
                if p.terminationStatus == 0, let s = try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int, s > 2000 { ok = true; break }
            }
            let img = ok ? NSImage(contentsOf: out) : nil
            await MainActor.run {
                self.inFlight.remove(id)
                if let img { self.images[id] = img }
            }
        }
    }

    func poster(for id: String) -> NSImage? {
        if let img = posters[id] { return img }
        if let img = NSImage(contentsOf: dir.appendingPathComponent("\(id).poster.jpg")) { posters[id] = img; return img }
        return nil
    }

    /// 电影海报：用片名查豆瓣（标题里带年份就按年份挑），取中号海报。每次启动每部只查一次
    func requestPoster(id: String, title: String) {
        guard poster(for: id) == nil, !posterTried.contains(id) else { return }
        posterTried.insert(id)
        let year = title.range(of: #"(19|20)\d{2}"#, options: .regularExpression).map { String(title[$0]) }
        let query = title.replacingOccurrences(of: #"\s*(19|20)\d{2}\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, var c = URLComponents(string: "https://movie.douban.com/j/subject_suggest") else { return }
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let api = c.url else { return }
        let out = dir.appendingPathComponent("\(id).poster.jpg")
        Task.detached {
            struct Hit: Decodable { var img: String?; var type: String?; var year: String?; var title: String?; var sub_title: String? }
            var req = URLRequest(url: api, timeoutInterval: 10)
            req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let hits = try? JSONDecoder().decode([Hit].self, from: data) else { return }
            // 宁缺毋滥：标题带年份就按年份对；没年份就要求中文名或英文名完全一致（防止老片配上同名新片的海报）；豆瓣的默认占位图不要
            let q = query.lowercased()
            let usable = hits.filter { $0.img != nil && !($0.img ?? "").contains("default") && ($0.type == "movie" || $0.type == "tv") }
            let named = usable.filter { h in [h.title, h.sub_title].compactMap { $0?.lowercased() }.contains { $0 == q || $0 == "the " + q } }
            guard let hit = year != nil ? usable.first(where: { $0.year == year }) : (named.count == 1 ? named[0] : nil),   // 同名的不止一部就不猜
                  let src = hit.img?.replacingOccurrences(of: "s_ratio_poster", with: "m_ratio_poster"),
                  let imgURL = URL(string: src) else { return }
            var ir = URLRequest(url: imgURL, timeoutInterval: 15)
            ir.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")   // 豆瓣图片要带来源页
            guard let (img, resp) = try? await URLSession.shared.data(for: ir), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: img) else { return }
            try? img.write(to: out)
            await MainActor.run { self.posters[id] = image }
        }
    }

    func requestRemote(id: String, url: String?) {
        // 有的站（小红书）给的封面是 http://，系统默认拦不加密的地址，换成 https
        guard let raw = url, let u = URL(string: raw.hasPrefix("http://") ? "https://" + raw.dropFirst(7) : raw),
              images[id] == nil, image(for: id) == nil, !inFlight.contains(id), !remoteFailed.contains(id) else { return }
        inFlight.insert(id)
        let out = dir.appendingPathComponent("\(id).jpg")
        Task.detached {
            var img: NSImage?
            if let (data, _) = try? await URLSession.shared.data(from: u), let src = NSImage(data: data),
               let tiff = src.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try? jpg.write(to: out); img = src
            }
            await MainActor.run {
                self.inFlight.remove(id)
                if let img { self.images[id] = img } else { self.remoteFailed.insert(id) }
            }
        }
    }
}
