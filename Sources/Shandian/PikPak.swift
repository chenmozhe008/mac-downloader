import CryptoKit
import Foundation

/// 云盘离线（PikPak）：BT 网络里几乎没人传的资源（国内热门片常见，都在迅雷用户之间传），
/// 交给 PikPak 的服务器下（热门的常常几秒就好，云端早有现成的），再从云盘按普通链接拉回本地。
/// 用的是用户自己的 PikPak 账号；接口照开源库 PikPakAPI（github.com/Quan666/PikPakAPI）写。
/// 只存登录后的令牌（pikpak.json，600 权限），不存密码。PikPak 在境外，请求走本机代理。
actor PikPak {
    static let shared = PikPak()
    nonisolated static let loginChanged = Notification.Name("PikPakLoginChanged")

    /// 签发 token 的客户端：安卓（账号密码登录）和网页（在 PikPak 网页里登录后取会话）。token 绑定签发它的客户端，刷新要用同一个。
    /// 网页端常量取自开源项目 peach 的 ADR-0093 与 AList（PikPak 改版网页时盐和固定时间戳可能会换）
    struct Profile {
        var clientID: String, clientSecret: String?, version: String, package: String, salts: [String]
        var signTimestamp: String?, refreshHeaders: [String: String] = [:]
    }
    static let android = Profile(clientID: "YNxT9w7GMdWvEOKa", clientSecret: "dbw2OtmVEeuUvIptb1Coyg", version: "1.47.1",
        package: "com.pikcloud.pikpak",
        salts: ["Gez0T9ijiI9WCeTsKSg3SMlx", "zQdbalsolyb1R/", "ftOjr52zt51JD68C3s", "yeOBMH0JkbQdEFNNwQ0RI9T3wU/v",
                "BRJrQZiTQ65WtMvwO", "je8fqxKPdQVJiy1DM6Bc9Nb1", "niV", "9hFCW2R1", "sHKHpe2i96",
                "p7c5E6AcXQ/IJUuAEC9W6", "", "aRv9hjc9P+Pbn+u3krN6", "BzStcgE8qVdqjEH16l4",
                "SqgeZvL5j9zoHP95xWHt", "zVof5yaJkPe3VFpadPof"])
    static let web = Profile(clientID: "YUMx5nI8ZU8Ap8pm", clientSecret: nil, version: "2.0.0", package: "mypikpak.com",
        salts: ["C9qPpZLN8ucRTaTiUMWYS9cQvWOE", "+r6CQVxjzJV6LCV", "F", "pFJRC", "9WXYIDGrwTCz2OiVlgZa90qpECPD6olt",
                "/750aCr4lm/Sly/c", "RB+DT/gZCrbV", "", "CyLsf7hdkIRxRm215hl", "7xHvLi2tOYP0Y92b",
                "ZGTXXxu8E/MIWaEDB+Sm/", "1UI3", "E7fP5Pfijd+7K+t6Tg/NhuLq0eEUVChpJSkrKxpO", "ihtqpG6FMt65+Xk+tWUH2",
                "NhXXU9rg4XXdzo7u5o"],
        signTimestamp: "1790733736477",
        refreshHeaders: ["X-Client-Id": "YUMx5nI8ZU8Ap8pm", "X-Sdk-Version": "8.1.4", "X-Protocol-Version": "301"])

    private var profile: Profile { session?.clientID == Self.web.clientID ? Self.web : Self.android }
    private let userHost = "https://user.mypikpak.com"
    private let apiHost = "https://api-drive.mypikpak.com"

    struct Session: Codable {
        var username: String; var deviceID: String; var accessToken: String; var refreshToken: String; var userID: String
        var clientID: String?
    }
    private var session: Session?
    private static var file: URL { EngineConfig.supportDir.appendingPathComponent("pikpak.json") }

    init() { session = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(Session.self, from: $0) } }

    /// 已登录的账号名（界面显示用）
    nonisolated static var loggedInUser: String? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }?.username
    }

    enum PikPakError: LocalizedError {
        case server(String), notLoggedIn
        var errorDescription: String? {
            switch self { case .server(let m): m; case .notLoggedIn: "还没有登录 PikPak" }
        }
    }

    // MARK: 登录

    func login(username: String, password: String) async throws {
        let device = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var meta: [String: Any] = [:]
        if username.contains("@") { meta["email"] = username }
        else if username.allSatisfy(\.isNumber), username.count >= 11 { meta["phone_number"] = username }
        else { meta["username"] = username }
        let signin = "\(userHost)/v1/auth/signin"
        session = nil
        let captcha = try await captchaInit(action: "POST:\(signin)", meta: meta, device: device)
        let r = try await send("POST", signin, body: ["client_id": Self.android.clientID, "client_secret": Self.android.clientSecret ?? "",
                                                      "username": username, "password": password, "captcha_token": captcha],
                               device: device, auth: false)
        guard let at = r["access_token"] as? String, let rt = r["refresh_token"] as? String else {
            throw PikPakError.server(Self.message(r) ?? "登录失败")
        }
        session = Session(username: username, deviceID: device, accessToken: at, refreshToken: rt, userID: r["sub"] as? String ?? "",
                          clientID: Self.android.clientID)
        save()
    }

    /// 网页登录：在 PikPak 网页里登录后取到的会话（见 PikPakLoginView）。之后只由闪电下载刷新
    func adoptWebSession(clientID: String, deviceID: String, accessToken: String, refreshToken: String, userID: String, name: String) {
        session = Session(username: name, deviceID: deviceID, accessToken: accessToken, refreshToken: refreshToken,
                          userID: userID, clientID: clientID)
        save()
    }

    func logout() {
        session = nil
        try? FileManager.default.removeItem(at: Self.file)
    }

    private func save() {
        guard let s = session, let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: Self.file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }

    private func refresh() async throws {
        guard var s = session else { throw PikPakError.notLoggedIn }
        let r = try await send("POST", "\(userHost)/v1/auth/token",
                               body: ["client_id": profile.clientID, "refresh_token": s.refreshToken, "grant_type": "refresh_token"],
                               device: s.deviceID, auth: false, extraHeaders: profile.refreshHeaders)
        guard let at = r["access_token"] as? String, let rt = r["refresh_token"] as? String else {
            throw PikPakError.server("登录已过期，请在设置里重新登录 PikPak")
        }
        s.accessToken = at; s.refreshToken = rt
        session = s; save()
    }

    // MARK: 离线任务

    struct Task { var id: String; var fileID: String; var phase: String; var progress: Int; var message: String? }

    /// 提交离线下载，返回任务（磁力、种子网址都行）
    func offline(_ link: String) async throws -> Task {
        let r = try await api("POST", "\(apiHost)/drive/v1/files",
                              body: ["kind": "drive#file", "upload_type": "UPLOAD_TYPE_URL", "url": ["url": link], "folder_type": "DOWNLOAD"])
        guard let t = r["task"] as? [String: Any] else { throw PikPakError.server(Self.message(r) ?? "云盘没有接受这个任务") }
        return Self.task(t)
    }

    /// 查任务进度；任务列表里找不到但文件在，就是下完了
    func status(_ taskID: String, fileID: String) async throws -> Task {
        let filters = #"{"phase":{"in":"PHASE_TYPE_RUNNING,PHASE_TYPE_ERROR,PHASE_TYPE_PENDING,PHASE_TYPE_COMPLETE"}}"#
        let q = "type=offline&limit=200&filters=" + (filters.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        let r = try await api("GET", "\(apiHost)/drive/v1/tasks?\(q)", body: nil)
        if let t = (r["tasks"] as? [[String: Any]])?.first(where: { $0["id"] as? String == taskID }) { return Self.task(t) }
        return Task(id: taskID, fileID: fileID, phase: "PHASE_TYPE_COMPLETE", progress: 100, message: nil)
    }

    struct RemoteFile { var name: String; var size: Int64; var url: String }

    /// 下好的文件和下载地址：文件夹就展开（只要视频和字幕，同电影里「只下正片」的规则）
    func files(of fileID: String) async throws -> [RemoteFile] {
        let info = try await api("GET", "\(apiHost)/drive/v1/files/\(fileID)", body: nil)
        var ids: [(String, String, Int64)] = []
        if info["kind"] as? String == "drive#folder" {
            ids = try await list(fileID)
        } else {
            ids = [(fileID, info["name"] as? String ?? "video", Int64(info["size"] as? String ?? "") ?? 0)]
        }
        let entries = ids.map { EngineTask.Meta.File(name: $0.1, path: nil, size: $0.2) }
        let keep = FileSelection.pick(entries) ?? Array(ids.indices)
        var out: [RemoteFile] = []
        for i in keep {
            let (id, name, size) = ids[i]
            let d = try await api("GET", "\(apiHost)/drive/v1/files/\(id)", body: nil, captchaAction: "GET:/drive/v1/files/\(id)")
            let media = ((d["medias"] as? [[String: Any]])?.first?["link"] as? [String: Any])?["url"] as? String
            if let u = d["web_content_link"] as? String ?? media, !u.isEmpty { out.append(RemoteFile(name: name, size: size, url: u)) }
        }
        return out
    }

    /// 拉回本地后删掉云端的文件（免费账号只有 6 GB）：先进回收站再彻底删除
    func deleteForever(_ fileID: String) async {
        _ = try? await api("POST", "\(apiHost)/drive/v1/files:batchTrash", body: ["ids": [fileID]])
        _ = try? await api("POST", "\(apiHost)/drive/v1/files:batchDelete", body: ["ids": [fileID]])
    }

    private func list(_ parent: String, prefix: String = "") async throws -> [(String, String, Int64)] {
        let filters = #"{"trashed":{"eq":false}}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let r = try await api("GET", "\(apiHost)/drive/v1/files?parent_id=\(parent)&limit=500&filters=\(filters)", body: nil)
        var out: [(String, String, Int64)] = []
        for f in r["files"] as? [[String: Any]] ?? [] {
            guard let id = f["id"] as? String, let name = f["name"] as? String else { continue }
            if f["kind"] as? String == "drive#folder" { out += try await list(id, prefix: prefix + name + "/") }
            else { out.append((id, name, Int64(f["size"] as? String ?? "") ?? 0)) }
        }
        return out
    }

    private static func task(_ t: [String: Any]) -> Task {
        Task(id: t["id"] as? String ?? "", fileID: t["file_id"] as? String ?? "", phase: t["phase"] as? String ?? "",
             progress: t["progress"] as? Int ?? Int(t["progress"] as? String ?? "") ?? 0, message: t["message"] as? String)
    }

    // MARK: 请求

    private func api(_ method: String, _ url: String, body: [String: Any]?, captchaAction: String? = nil, retried: Bool = false) async throws -> [String: Any] {
        guard let s = session else { throw PikPakError.notLoggedIn }
        var captcha: String?
        if let a = captchaAction { captcha = try await captchaInit(action: a, meta: nil, device: s.deviceID) }
        let r = try await send(method, url, body: body, device: s.deviceID, auth: true, captcha: captcha)
        if (r["error_code"] as? Int) == 16, !retried {   // 令牌过期
            try await refresh()
            return try await api(method, url, body: body, captchaAction: captchaAction, retried: true)
        }
        if let e = r["error"] as? String, !e.isEmpty { throw PikPakError.server(Self.message(r) ?? e) }
        return r
    }

    private func captchaInit(action: String, meta: [String: Any]?, device: String) async throws -> String {
        var m = meta ?? [:]
        let p = session == nil ? Self.android : profile
        if meta == nil {
            let ts = p.signTimestamp ?? String(Int(Date().timeIntervalSince1970 * 1000))
            var sign = p.clientID + p.version + p.package + device + ts
            for salt in p.salts { sign = Insecure.MD5.hash(data: Data((sign + salt).utf8)).map { String(format: "%02x", $0) }.joined() }
            m = ["captcha_sign": "1." + sign, "client_version": p.version, "package_name": p.package,
                 "user_id": session?.userID ?? "", "timestamp": ts]
        }
        let r = try await send("POST", "\(userHost)/v1/shield/captcha/init",
                               body: ["client_id": p.clientID, "action": action, "device_id": device, "meta": m], device: device, auth: false)
        guard let t = r["captcha_token"] as? String, !t.isEmpty else {
            throw PikPakError.server(Self.message(r) ?? "PikPak 要求人机验证，请先在 PikPak 官网或 App 里登录一次再试")
        }
        return t
    }

    private func send(_ method: String, _ url: String, body: [String: Any]?, device: String, auth: Bool, captcha: String? = nil,
                      extraHeaders: [String: String] = [:]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue(device, forHTTPHeaderField: "X-Device-Id")
        if auth, let t = session?.accessToken { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let captcha { req.setValue(captcha, forHTTPHeaderField: "X-Captcha-Token") }
        if auth, session?.clientID == Self.web.clientID { req.setValue(Self.web.clientID, forHTTPHeaderField: "X-Client-Id") }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = LocalProxy.sessionDictionary(for: url)   // 境外服务，走本机代理
        let (data, _) = try await URLSession(configuration: cfg).data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func message(_ r: [String: Any]) -> String? {
        (r["error_description"] as? String) ?? (r["message"] as? String) ?? (r["error"] as? String)
    }
}
