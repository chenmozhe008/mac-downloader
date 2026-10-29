import CryptoKit
import Foundation

/// 下载内核（Gopeed headless）的位置与鉴权。内核二进制和任务库在移动硬盘，token 在 App 配置目录。
enum EngineConfig {
    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ShandianDownload")
    /// 内核放本机（10-28 用户同意从移动硬盘挪过来）：退出 App 时内核不关，放硬盘上会让硬盘推不出
    static var engineDir: URL { supportDir.appendingPathComponent("engine") }
    static var binary: URL { engineDir.appendingPathComponent("gopeed") }
    /// 旧位置（移动硬盘），第一次启动新版时从这里拷内核和任务库过来；旧文件不删
    static let legacyDir = URL(fileURLWithPath: "/Volumes/Jack Feng/Applications/MacDownloader")
    static var configFile: URL { supportDir.appendingPathComponent("engine.json") }

    struct Stored: Codable { var token: String; var port: Int }

    /// 读 token；没有就生成一份（第一次运行）
    static func load() -> Stored {
        if let data = try? Data(contentsOf: configFile),
           let s = try? JSONDecoder().decode(Stored.self, from: data) { return s }
        let s = Stored(token: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), port: 9999)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: configFile)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        }
        return s
    }
}

// MARK: - 内核返回的数据

struct EngineTask: Decodable {
    struct Meta: Decodable {
        struct Req: Decodable { var url: String }
        struct File: Decodable { var name: String; var path: String?; var size: Int64 }
        struct Res: Decodable { var name: String?; var size: Int64?; var files: [File]?; var hash: String? }
        struct Opts: Decodable { var name: String?; var path: String?; var selectFiles: [Int]? }
        var req: Req
        var res: Res?
        var opts: Opts?
    }
    struct Progress: Decodable { var speed: Int64; var downloaded: Int64 }
    var id: String
    var `protocol`: String?
    var name: String?
    var status: String
    var meta: Meta
    var progress: Progress
    var createdAt: String?
    var updatedAt: String?
    var shandianError: String?   // 内核补丁：最近一次失败的原因

    /// 失败原因翻译成人话（内核原话如 http request fail, code:429 / connection 2 failed: retries=3, status=403）
    var failureText: String {
        let e = (shandianError ?? "").lowercased()
        let code = e.range(of: #"(code:|status=)\s*([0-9]{3})"#, options: .regularExpression)
            .flatMap { Int(e[$0].filter(\.isNumber)) }
        switch code {
        case 429?: return "服务器限制了下载频率，过一会儿再试"
        case 401?: return "需要登录才能下载"
        case 403?: return "服务器拒绝下载（链接可能已过期，或需要登录）"
        case 404?, 410?: return "文件不存在或链接已失效"
        case let c? where c >= 500: return "服务器出错（\(c)），过一会儿再试"
        case let c?: return "服务器返回错误（\(c)）"
        case nil: break
        }
        if e.contains("no space left") { return "磁盘空间不足" }
        if e.contains("no such host") { return "找不到服务器（网址有误或网络不通）" }
        if e.contains("timeout") || e.contains("deadline exceeded") { return "连接服务器超时" }
        if e.contains("connection refused") || e.contains("connection reset") || e.contains("eof") { return "和服务器的连接断开了" }
        if e.contains("permission denied") || e.contains("operation not permitted") { return "没有权限写入保存位置" }
        return "下载出错"
    }
}

struct ResolvedResource {
    var name: String
    var files: [EngineTask.Meta.File]
}

enum EngineError: LocalizedError {
    case server(String)
    var errorDescription: String? { if case .server(let m) = self { return m }; return nil }
}

// MARK: - REST 客户端

final class EngineClient: @unchecked Sendable {
    private let base: URL
    private let token: String
    private let session: URLSession

    init(stored: EngineConfig.Stored) {
        base = URL(string: "http://127.0.0.1:\(stored.port)/api/v1/")!
        token = stored.token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]  // 本机接口，绕开系统代理
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    private struct Envelope<T: Decodable>: Decodable { var code: Int; var msg: String; var data: T? }

    private func call<T: Decodable>(_ method: String, _ path: String, body: Any? = nil, timeout: TimeInterval = 15) async throws -> T? {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue(token, forHTTPHeaderField: "X-Api-Token")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await session.data(for: req)
        let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        guard env.code == 0 else { throw EngineError.server(env.msg) }
        return env.data
    }

    func isAlive() async -> Bool {
        struct Info: Decodable { var version: String? }
        return ((try? await call("GET", "info") as Info?) ?? nil) != nil
    }

    func tasks() async throws -> [EngineTask] { try await call("GET", "tasks") ?? [] }

    /// 解析链接拿文件列表（磁力要先从网络拿到种子信息，可能要等一会）。
    /// 直链带上和真正下载时一样的代理、浏览器请求头，否则要登录 / 防盗链 / 境外的链接在这一步就失败；
    /// 直链用 probe=1（内核补丁）：只要名字和大小，不在后台把整个文件预下载一遍
    func resolve(url: String, headers: [String: String] = [:]) async throws -> ResolvedResource {
        struct R: Decodable { struct Res: Decodable { var name: String?; var files: [EngineTask.Meta.File]? }; var res: Res }
        var req: [String: Any] = ["url": url]
        let http = url.lowercased().hasPrefix("http")
        if http { req["proxy"] = LocalProxy.engineRequest(for: url) }
        if !headers.isEmpty { req["extra"] = ["header": headers] }
        guard let r: R = try await call("POST", http ? "resolve?probe=1" : "resolve", body: ["req": req], timeout: 300) else {
            throw EngineError.server("解析失败")
        }
        return ResolvedResource(name: r.res.name ?? "", files: r.res.files ?? [])
    }

    /// 新建任务。注意参数名是 opts（写成 opt 不报错但设置不生效）
    @discardableResult
    func create(url: String, directory: String, selectFiles: [Int]? = nil, headers: [String: String] = [:], name: String? = nil) async throws -> String {
        var opts: [String: Any] = ["path": directory]
        if let selectFiles { opts["selectFiles"] = selectFiles }
        if let name, !name.isEmpty { opts["name"] = name }
        var req: [String: Any] = ["url": url]
        // 磁力 / 种子不设：内核全局代理已关，BT 直连
        if url.lowercased().hasPrefix("http") { req["proxy"] = LocalProxy.engineRequest(for: url) }
        if !headers.isEmpty { req["extra"] = ["header": headers] }  // 网盘直链要带浏览器的 Cookie、UA、Referer
        return try await call("POST", "tasks", body: ["req": req, "opts": opts]) ?? ""
    }

    /// 原样转发给内核（网关代理 Gopeed 浏览器扩展的其它请求用）
    func forward(method: String, path: String, body: Data?) async -> (Int, Data) {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)  // path 以 / 开头，按主机根路径解析
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-Api-Token")
        if let body, !body.isEmpty { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        guard let (data, resp) = try? await session.data(for: req) else { return (502, Data()) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 502, data)
    }

    func pause(_ id: String) async throws { let _: String? = try await call("PUT", "tasks/\(id)/pause") }
    func resume(_ id: String) async throws { let _: String? = try await call("PUT", "tasks/\(id)/continue") }
    /// 边下边送的播放地址（内核补丁 /play/{id}/{key}/{文件名}）；key 由 token 和任务 id 派生，和内核里 shandian.PlayKey 一致
    func playURL(id: String, fileName: String) -> URL? {
        let digest = SHA256.hash(data: Data("shandian-play:\(token):\(id)".utf8)).map { String(format: "%02x", $0) }.joined()
        let name = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "video"
        return URL(string: "/play/\(id)/\(digest.prefix(24))/\(name)", relativeTo: base)?.absoluteURL  // 以 / 开头，落在主机根路径，不在 /api/v1 下
    }

    /// 边下边播（闪电全能下载给内核加的接口）
    func stream(_ id: String) async throws { let _: String? = try await call("PUT", "tasks/\(id)/stream") }
    func pauseAll() async throws { let _: String? = try await call("PUT", "tasks/pause") }
    func resumeAll() async throws { let _: String? = try await call("PUT", "tasks/continue") }
    func delete(_ id: String, withFiles: Bool) async throws {
        let _: String? = try await call("DELETE", "tasks/\(id)?force=\(withFiles)")
    }
}

// MARK: - 内核进程托管

/// App 启动时确保内核在跑；是 App 拉起的，App 退出时一起关掉。
final class EngineHost: @unchecked Sendable {
    let stored = EngineConfig.load()
    lazy var client = EngineClient(stored: stored)
    private var process: Process?

    enum StartResult { case running, failed(String) }

    /// App 里带的（打过补丁的）内核和本机装的不一样
    var bundledEngineIsNewer: Bool {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("gopeed"),
              let a = try? Data(contentsOf: bundled, options: .mappedIfSafe) else { return false }
        guard let b = try? Data(contentsOf: EngineConfig.binary, options: .mappedIfSafe) else { return true }
        return a != b
    }

    /// 换上 App 里带的内核（调用前内核要已停）
    func installBundledEngine() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("gopeed") else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: EngineConfig.engineDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: EngineConfig.binary)
        try? fm.copyItem(at: bundled, to: EngineConfig.binary)
    }

    func start() async -> StartResult {
        if await client.isAlive() { return .running }
        migrateFromDisk()
        if bundledEngineIsNewer { installBundledEngine() }
        guard FileManager.default.isExecutableFile(atPath: EngineConfig.binary.path) else { return .failed("内核程序缺失") }
        let dataDir = EngineConfig.engineDir.appendingPathComponent("data")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = EngineConfig.binary
        p.currentDirectoryURL = EngineConfig.engineDir
        p.arguments = ["-A", "127.0.0.1", "-P", "\(stored.port)", "-T", stored.token,
                       "-d", dataDir.path, "-c", dataDir.appendingPathComponent("server.json").path]
        let log = EngineConfig.supportDir.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); p.standardOutput = h; p.standardError = h }
        do { try p.run() } catch { return .failed(error.localizedDescription) }
        process = p
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if await client.isAlive() { return .running }
        }
        return .failed("内核没有响应")
    }

    /// 内核程序和任务库（gopeed.db、server.json）从移动硬盘拷到本机，只在本机还没有时做一次
    private func migrateFromDisk() {
        let fm = FileManager.default
        let legacyBin = EngineConfig.legacyDir.appendingPathComponent("gopeed")
        guard !fm.fileExists(atPath: EngineConfig.binary.path), fm.fileExists(atPath: legacyBin.path) else { return }
        try? fm.createDirectory(at: EngineConfig.engineDir.appendingPathComponent("data"), withIntermediateDirectories: true)
        for f in ["data/gopeed.db", "data/server.json"] {
            let src = EngineConfig.legacyDir.appendingPathComponent(f)
            if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: EngineConfig.engineDir.appendingPathComponent(f)) }
        }
        try? fm.copyItem(at: legacyBin, to: EngineConfig.binary)
    }

    /// 内核进程有没有开着这块盘上的文件（lsof 只查内核一个进程，很快）
    func holdsFiles(on volume: String) -> Bool {
        let pg = Process()
        pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pg.arguments = ["-f", EngineConfig.binary.path]
        let pipe = Pipe(); pg.standardOutput = pipe
        try? pg.run(); pg.waitUntilExit()
        let pids = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(separator: "\n").map(String.init) ?? []
        guard !pids.isEmpty else { return false }
        let ls = Process()
        ls.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        ls.arguments = ["-Fn", "-p", pids.joined(separator: ",")]
        let out = Pipe(); ls.standardOutput = out; ls.standardError = FileHandle.nullDevice
        try? ls.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ls.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").contains { $0.hasPrefix("n" + volume + "/") }
    }

    /// 结束内核进程（不管是不是这次启动的），等它退出：推出硬盘前用，内核退了文件才关
    func kill() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", EngineConfig.binary.path]
        try? p.run(); p.waitUntilExit()
        for _ in 0..<20 {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            check.arguments = ["-f", EngineConfig.binary.path]
            check.standardOutput = FileHandle.nullDevice
            try? check.run(); check.waitUntilExit()
            if check.terminationStatus != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// 退出 App 时只暂停任务，内核留着：内核一重启就要把没下完的部分整个重新校验（见 CLAUDE.md），
    /// 留着它下次打开能直接接着下。暂停时内核会关掉文件，不挡移动硬盘推出
    func suspend() {
        let done = DispatchSemaphore(value: 0)
        Task { try? await client.pauseAll(); done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }
}

// MARK: - 下载设置（与 script/engine.sh configure 保持一致，改值两边一起改）

extension EngineClient {
    private func rawConfig() async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "config", relativeTo: base)!)
        req.setValue(token, forHTTPHeaderField: "X-Api-Token")
        let (data, _) = try await session.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["data"] as? [String: Any] ?? [:]
    }

    /// 全局代理关（HTTP 任务按域名单独走代理）、HTTP 8 连接（国内镜像 16 线程会被封）、BT 固定端口 6881、每次启动更新 tracker（拉取失败保留旧列表）
    func applySettings(defaultDir: String) async {
        guard var cfg = try? await rawConfig() else { return }
        cfg["downloadDir"] = defaultDir
        cfg["maxRunning"] = Prefs.maxRunning
        // 限速（闪电全能下载给内核加的，BT 和直链共用），0 为不限
        var extra = cfg["extra"] as? [String: Any] ?? [:]
        extra["shandianDownloadLimit"] = Prefs.downloadLimit
        cfg["extra"] = extra
        // 全局代理关：开着时 BT 连接也走 Clash（见 LocalProxy 说明）；HTTP 任务各自带代理设置
        cfg["proxy"] = ["enable": false, "system": false, "scheme": "http", "host": "\(LocalProxy.host):\(LocalProxy.port)", "usr": "", "pwd": ""]
        var proto = cfg["protocolConfig"] as? [String: Any] ?? [:]
        var http = proto["http"] as? [String: Any] ?? [:]; http["connections"] = 8
        // 不冒充浏览器：Go 的 TLS 握手配 Chrome UA 会被识别为伪装爬虫 403（10-27 中科大实测，内核默认 Chrome 116 / 改 141 都 403，
        // 如实写下载工具名则 200）。需要浏览器身份的下载（网盘、登录站）由浏览器插件/LinkSwift 带上真实 UA 和 Cookie
        http["userAgent"] = Self.userAgent
        proto["http"] = http
        var bt = proto["bt"] as? [String: Any] ?? [:]; bt["listenPort"] = 6881
        let trackers = await Self.fetchTrackers()
        if !trackers.isEmpty { bt["trackers"] = trackers }
        proto["bt"] = bt; cfg["protocolConfig"] = proto
        var req = URLRequest(url: URL(string: "config", relativeTo: base)!)
        req.httpMethod = "PUT"
        req.setValue(token, forHTTPHeaderField: "X-Api-Token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: cfg)
        _ = try? await session.data(for: req)
    }

    static let userAgent = "ShandianDownload/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (Macintosh)"

    static func fetchTrackers() async -> [String] {
        let sources = ["https://cf.trackerslist.com/best.txt",
                       "https://cdn.jsdelivr.net/gh/ngosang/trackerslist@master/trackers_best.txt"]
        var out: [String] = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = LocalProxy.sessionDictionary  // jsDelivr 在国内时好时坏，有代理就走代理
        cfg.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfg)
        for s in sources {
            guard let (data, _) = try? await session.data(from: URL(string: s)!),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.contains("announce"), !out.contains(t) { out.append(t) }
            }
        }
        return out
    }
}
