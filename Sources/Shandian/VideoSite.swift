import Foundation

/// 视频网站下载选项（参考 Downie：默认直接下最高画质，选项记住后 ⌘V 也按它来）
struct VideoOptions: Codable, Equatable {
    var maxHeight = 0          // 0 = 最高；否则不超过这个分辨率
    var subtitles = false      // 下载字幕并嵌入视频
    var audioOnly = false      // 只下音频（m4a）

    private static let key = "videoOptions"
    static var current: VideoOptions {
        get { (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode(VideoOptions.self, from: $0) } ?? VideoOptions() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// 对应的 yt-dlp 参数
    var arguments: [String] {
        if audioOnly { return ["-f", "ba/b", "-x", "--audio-format", "m4a"] }
        // 先比分辨率，同分辨率优先 H.264/AAC：默认会挑体积最小的 AV1，剪映、老 Mac 兼容差
        var a = ["-f", "bv*+ba/b", "-S", (maxHeight > 0 ? "res:\(maxHeight)" : "res") + ",vcodec:h264,acodec:aac", "--merge-output-format", "mp4"]
        if subtitles { a += ["--write-subs", "--sub-langs", "zh.*,en.*,ai-zh", "--embed-subs"] }
        return a
    }
}

/// 视频网站的一条下载（yt-dlp 进程）。完成的记录存到 videos.json，重开 App 还在。
struct VideoJob: Codable, Identifiable {
    var id = UUID()
    var url: String
    var title: String
    var site: String
    var thumbnailURL: String?
    var filePath: String?
    var downloaded: Int64 = 0
    var total: Int64 = 0
    var speed: Int64 = 0
    var state: State = .running
    var error: String?
    var createdAt = Date()
    var options: VideoOptions?     // 旧记录没有这一项，按默认处理
    var stage: Stage?              // 下载中处在哪一步，界面据此显示（旧记录没有）

    enum State: String, Codable { case running, done, failed }
    /// 解析网页 → 下视频 → 下音频 → 合并（或只下音频 → 转换）。解析和合并时没有字节进度，界面不能停在 0
    enum Stage: String, Codable { case preparing, video, audio, merging, converting }
}

/// App 自带一份 yt-dlp，放在配置目录、每周检查新版。视频站改版快，旧版会直接失效
/// （2026-10-27 实测：brew 里 2025-04 版下 B 站报 412，最新版不登录可下 1080P）。
/// 用官方「目录版」yt-dlp_macos.zip：单文件版 yt-dlp_macos 每次启动都要解包到临时目录、系统再扫一遍，
/// 10-29 实测每条视频白等 16 秒；目录版只有装好后第一次 16 秒，之后 0.3 秒。目录版不支持 -U，更新靠重新下载。
enum YtDlp {
    static let dir = EngineConfig.supportDir.appendingPathComponent("bin/yt-dlp_macos")
    static let bundled = dir.appendingPathComponent("yt-dlp_macos")
    static let legacy = EngineConfig.supportDir.appendingPathComponent("bin/yt-dlp")   // 0.14 及以前的单文件版
    static let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip")!
    static let latestAPI = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!

    /// 优先用自带的；还没下好时退回旧的单文件版、brew 装的
    static var path: String? {
        ([bundled.path, legacy.path, "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 启动时调用：没有就下载，超过 7 天查一次新版
    static func ensureFresh() async {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: bundled.path) else { await install(); return }
        let modified = (try? fm.attributesOfItem(atPath: bundled.path)[.modificationDate] as? Date) ?? .distantPast
        guard Date().timeIntervalSince(modified) > 7 * 86400 else { return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = LocalProxy.sessionDictionary
        if let (data, _) = try? await URLSession(configuration: cfg).data(from: latestAPI),
           let tag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String,
           tag != run(["--version"]) {
            await install()
        } else {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: bundled.path)  // 已是最新：记一下检查时间
        }
    }

    /// 下载目录版、解压后整个换上；成功后删掉旧的单文件版，并空跑一次让系统先扫描完（否则第一条视频要多等 16 秒）
    private static func install() async {
        let fm = FileManager.default
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = LocalProxy.sessionDictionary
        guard let (zip, resp) = try? await URLSession(configuration: cfg).download(from: downloadURL),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        let staging = dir.deletingLastPathComponent().appendingPathComponent(".yt-dlp-new")
        try? fm.removeItem(at: staging)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, staging.path]
        try? unzip.run(); unzip.waitUntilExit()
        try? fm.removeItem(at: zip)
        let exe = staging.appendingPathComponent("yt-dlp_macos")
        guard unzip.terminationStatus == 0, fm.fileExists(atPath: exe.path) else { try? fm.removeItem(at: staging); return }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try? fm.removeItem(at: dir)
        guard (try? fm.moveItem(at: staging, to: dir)) != nil else { return }
        try? fm.removeItem(at: legacy)
        _ = run(["--version"])
    }

    /// 同步跑一次，返回去掉首尾空白的输出
    @discardableResult
    static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = bundled
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class VideoSiteRunner: @unchecked Sendable {
    private var processes: [UUID: Process] = [:]
    private let lock = NSLock()

    static func siteName(_ url: String) -> String {
        let host = URL(string: url)?.host?.lowercased() ?? ""
        let names: [(String, String)] = [("bilibili", "B 站"), ("b23.tv", "B 站"), ("youtu", "YouTube"), ("douyin", "抖音"),
                                         ("xiaohongshu", "小红书"), ("xhslink", "小红书"), ("kuaishou", "快手"), ("weibo", "微博"),
                                         ("ixigua", "西瓜视频"), ("vimeo", "Vimeo"), ("x.com", "X"), ("twitter", "X")]
        return names.first { host.contains($0.0) }?.1 ?? host
    }

    /// 启动下载；进度、标题、封面、成品路径通过 update 回调（在后台线程）
    func start(_ job: VideoJob, into dir: URL, update: @escaping @Sendable (VideoJob) -> Void) {
        guard let bin = YtDlp.path else {
            var j = job; j.state = .failed; j.error = "未安装 yt-dlp"; update(j); return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = [
            "-P", dir.path, "-o", "%(title).80s [%(id)s].%(ext)s",
            "--no-playlist",
            "--newline", "--no-colors",
            "--progress",   // --print 默认开安静模式、不输出进度（10-29 用户：一直 0 然后突然下好）
            // 分片并发：YouTube 单连接被限速，10-29 实测默认 1.4–1.6 MiB/s，-N 4 为 3.4–4.1；8、16 不比 4 明显快。
            // B 站等整文件的站不分片，这个参数不起作用也无害
            "--concurrent-fragments", "4",
            "--print", "before_dl:SDTITLE %(title)s",
            "--print", "before_dl:SDFMT %(format_id)s",
            "--print", "before_dl:SDSIZE %(filesize,filesize_approx)s",
            "--print", "before_dl:SDTHUMB %(thumbnail)s",
            "--print", "after_move:SDFILE %(filepath)s",
            "--progress-template", "download:SDPROG %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.status)s",
            job.url,
        ]
        p.arguments?.insert(contentsOf: (job.options ?? VideoOptions()).arguments + LocalProxy.ytdlpArguments(for: job.url)
                                     + SiteCookies.ytdlpArguments(for: job.url), at: 0)
        // YouTube 需要 JS 运行环境解签名，没有时部分格式缺失（10-27 实测 44 → 52 个格式）；本机有 Node 就接上
        if let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            p.arguments?.insert(contentsOf: ["--js-runtimes", "node:" + node], at: 0)
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"  // 合并音视频要找到 ffmpeg
        p.environment = env
        let out = Pipe(); p.standardOutput = out
        let err = Pipe(); p.standardError = err

        var first = job; first.stage = .preparing; update(first)
        let state = JobState(first)
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) { if let j = state.apply(String(line)) { update(j) } }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if let text = String(data: data, encoding: .utf8), let last = text.split(whereSeparator: \.isNewline).last(where: { $0.contains("ERROR") }) {
                state.lastError = String(last).replacingOccurrences(of: "ERROR: ", with: "")
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            update(state.finish(ok: proc.terminationStatus == 0))
            self?.lock.withLock { self?.processes[job.id] = nil }
        }
        do { try p.run() } catch {
            var j = job; j.state = .failed; j.error = error.localizedDescription; update(j); return
        }
        lock.withLock { processes[job.id] = p }
    }

    func cancel(_ id: UUID) { lock.withLock { processes[id] }?.terminate() }
    func cancelAll() { lock.withLock { Array(processes.values) }.forEach { $0.terminate() } }
}

/// 解析 yt-dlp 输出。视频和音频是分两段下的，前一段下完的字节累加进 finishedBytes。
private final class JobState: @unchecked Sendable {
    private var job: VideoJob
    private var finishedBytes: Int64 = 0
    private var currentTotal: Int64 = 0
    private var parts = 1          // 视频+音频分开下时是 2
    private var finishedParts = 0
    private var knownTotal: Int64 = 0  // 开下前 yt-dlp 给的整体大小（估算），有它总大小就不会中途变大、进度条不往回跳
    // 速度按最近 3 秒实际下到的字节自己算：yt-dlp 每个新分块都从头估，开头几个包能报出 200 MB/s（10-29 实测）
    private var samples: [(Date, Int64)] = []
    private var lastEmit = Date.distantPast
    var lastError: String?
    private let lock = NSLock()

    init(_ job: VideoJob) { self.job = job }

    func apply(_ line: String) -> VideoJob? {
        lock.withLock {
            if line.hasPrefix("SDTITLE ") { job.title = String(line.dropFirst(8)) }
            else if line.hasPrefix("SDTHUMB ") { let t = String(line.dropFirst(8)); job.thumbnailURL = t == "NA" ? nil : t }
            else if line.hasPrefix("SDFILE ") { job.filePath = String(line.dropFirst(7)) }
            else if line.hasPrefix("SDFMT ") { parts = line.dropFirst(6).split(separator: "+").count }
            else if line.hasPrefix("SDSIZE ") { knownTotal = Int64(Double(line.dropFirst(7)) ?? 0); job.total = max(job.total, knownTotal) }
            else if line.hasPrefix("SDPROG ") {
                let f = line.split(separator: " ").map(String.init)
                guard f.count >= 6 else { return nil }
                let done = Int64(Double(f[1]) ?? 0)
                let total = Int64(Double(f[2]) ?? Double(f[3]) ?? 0)
                if f[5] == "finished" { finishedBytes += max(total, done); currentTotal = 0; finishedParts += 1 }
                else { currentTotal = total }
                job.downloaded = finishedBytes + (f[5] == "finished" ? 0 : done)
                job.total = max(knownTotal, finishedBytes + currentTotal, job.total)
                let now = Date()
                samples.append((now, job.downloaded))
                samples.removeAll { now.timeIntervalSince($0.0) > 3 }
                if let first = samples.first, now.timeIntervalSince(first.0) > 0.5 {
                    job.speed = max(0, Int64(Double(job.downloaded - first.1) / now.timeIntervalSince(first.0)))
                }
                let stage = job.stage
                let audioOnly = job.options?.audioOnly ?? false
                if finishedParts >= parts { job.stage = audioOnly ? .converting : parts > 1 ? .merging : job.stage; job.speed = 0 }
                else { job.stage = audioOnly || finishedParts > 0 ? .audio : .video }
                // yt-dlp 每秒报几十次：只在换阶段时立即刷新，其余最多每 0.5 秒一次
                guard job.stage != stage || now.timeIntervalSince(lastEmit) >= 0.5 else { return nil }
                lastEmit = now
            } else { return nil }
            return job
        }
    }

    func finish(ok: Bool) -> VideoJob {
        lock.withLock {
            job.speed = 0; job.stage = nil
            if ok { job.state = .done; job.downloaded = max(job.downloaded, job.total) }
            else {
                job.state = .failed
                // 抖音、小红书没带登录信息时 yt-dlp 的报错看不懂，直接告诉怎么办
                // 抖音只能由扩展从页面里取直链，yt-dlp 必然失败（要签名）：直接告诉怎么办
                job.error = (URL(string: job.url)?.host ?? "").hasSuffix("douyin.com")
                    ? "请在浏览器里打开这个抖音视频，点扩展里的「下载这个视频」"
                    : SiteCookies.site(of: job.url) != nil && SiteCookies.ytdlpArguments(for: job.url).isEmpty
                    ? "需要在浏览器里登录后，右键「用闪电全能下载这个视频」" : (lastError ?? "下载失败")
            }
            if let path = job.filePath, let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 {
                job.total = size; if ok { job.downloaded = size }
            }
            return job
        }
    }
}
