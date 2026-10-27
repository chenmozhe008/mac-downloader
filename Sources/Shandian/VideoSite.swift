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

    enum State: String, Codable { case running, done, failed }
}

/// App 自带一份 yt-dlp，放在配置目录、每周自更新。视频站改版快，旧版会直接失效
/// （2026-10-27 实测：brew 里 2025-04 版下 B 站报 412，最新版不登录可下 1080P）。
enum YtDlp {
    static let bundled = EngineConfig.supportDir.appendingPathComponent("bin/yt-dlp")
    static let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    /// 优先用自带的；还没下好时退回 brew 装的
    static var path: String? {
        ([bundled.path, "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 启动时调用：没有就下载，超过 7 天就自更新
    static func ensureFresh() async {
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: bundled.path) {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.connectionProxyDictionary = LocalProxy.sessionDictionary
            guard let (tmp, resp) = try? await URLSession(configuration: cfg).download(from: downloadURL),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            try? fm.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: bundled)
            try? fm.moveItem(at: tmp, to: bundled)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
            return
        }
        let modified = (try? fm.attributesOfItem(atPath: bundled.path)[.modificationDate] as? Date) ?? .distantPast
        guard Date().timeIntervalSince(modified) > 7 * 86400 else { return }
        let p = Process()
        p.executableURL = bundled
        p.arguments = ["-U"] + LocalProxy.ytdlpArguments(for: "https://github.com")
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: bundled.path)  // 已是最新时 -U 不改文件，手动记一下检查时间
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
            "--print", "before_dl:SDTITLE %(title)s",
            "--print", "before_dl:SDTHUMB %(thumbnail)s",
            "--print", "after_move:SDFILE %(filepath)s",
            "--progress-template", "download:SDPROG %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.status)s",
            job.url,
        ]
        p.arguments?.insert(contentsOf: (job.options ?? VideoOptions()).arguments + LocalProxy.ytdlpArguments(for: job.url), at: 0)
        // YouTube 需要 JS 运行环境解签名，没有时部分格式缺失（10-27 实测 44 → 52 个格式）；本机有 Node 就接上
        if let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            p.arguments?.insert(contentsOf: ["--js-runtimes", "node:" + node], at: 0)
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"  // 合并音视频要找到 ffmpeg
        p.environment = env
        let out = Pipe(); p.standardOutput = out
        let err = Pipe(); p.standardError = err

        let state = JobState(job)
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
    var lastError: String?
    private let lock = NSLock()

    init(_ job: VideoJob) { self.job = job }

    func apply(_ line: String) -> VideoJob? {
        lock.withLock {
            if line.hasPrefix("SDTITLE ") { job.title = String(line.dropFirst(8)) }
            else if line.hasPrefix("SDTHUMB ") { let t = String(line.dropFirst(8)); job.thumbnailURL = t == "NA" ? nil : t }
            else if line.hasPrefix("SDFILE ") { job.filePath = String(line.dropFirst(7)) }
            else if line.hasPrefix("SDPROG ") {
                let f = line.split(separator: " ").map(String.init)
                guard f.count >= 6 else { return nil }
                let done = Int64(Double(f[1]) ?? 0)
                let total = Int64(Double(f[2]) ?? Double(f[3]) ?? 0)
                if f[5] == "finished" { finishedBytes += max(total, done); currentTotal = 0 }
                else { currentTotal = total }
                job.downloaded = finishedBytes + (f[5] == "finished" ? 0 : done)
                job.total = max(job.total, finishedBytes + currentTotal)
                job.speed = Int64(Double(f[4]) ?? 0)
            } else { return nil }
            return job
        }
    }

    func finish(ok: Bool) -> VideoJob {
        lock.withLock {
            job.speed = 0
            if ok { job.state = .done; job.downloaded = max(job.downloaded, job.total) }
            else { job.state = .failed; job.error = lastError ?? "下载失败" }
            if let path = job.filePath, let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 {
                job.total = size; if ok { job.downloaded = size }
            }
            return job
        }
    }
}
