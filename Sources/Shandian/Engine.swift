import Foundation

/// 下载内核（Gopeed headless）的位置与鉴权。内核二进制和任务库在移动硬盘，token 在 App 配置目录。
enum EngineConfig {
    static let engineDir = URL(fileURLWithPath: "/Volumes/Jack Feng/Applications/MacDownloader")
    static var binary: URL { engineDir.appendingPathComponent("gopeed") }
    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ShandianDownload")
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

    /// 解析链接拿文件列表（磁力要先从网络拿到种子信息，可能要等一会）
    func resolve(url: String) async throws -> ResolvedResource {
        struct R: Decodable { struct Res: Decodable { var name: String?; var files: [EngineTask.Meta.File]? }; var res: Res }
        guard let r: R = try await call("POST", "resolve", body: ["req": ["url": url]], timeout: 300) else {
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

    enum StartResult { case running, missingDisk, failed(String) }

    func start() async -> StartResult {
        if await client.isAlive() { return .running }
        guard FileManager.default.isExecutableFile(atPath: EngineConfig.binary.path) else { return .missingDisk }
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

    /// 先让内核把任务都暂停（暂停时会落盘保存进度），再结束进程。
    /// 10-28《求救信号》重启内核后已下的 1.8 GB 没了，没能复现出原因；直接 SIGTERM 是唯一可疑的环节，先加这道保险
    func stop() {
        guard let process else { return }
        let done = DispatchSemaphore(value: 0)
        Task { try? await client.pauseAll(); done.signal() }
        _ = done.wait(timeout: .now() + 3)
        Thread.sleep(forTimeInterval: 0.5)
        process.terminate()
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
