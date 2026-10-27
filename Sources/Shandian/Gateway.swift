import Foundation
import Network

/// 本机网关 127.0.0.1:6800（只监听本机），让浏览器里的下载也走 App 的规则（存哪、只选正片、片名整理）：
/// - POST /jsonrpc：兼容 Aria2 RPC（LinkSwift 推网盘直链用，aria2.addUri / getVersion），密钥＝内核 token
/// - /api/v1/*：代理 Gopeed 浏览器扩展；新建任务改走 App 的添加流程，其余请求原样转给内核
final class Gateway: @unchecked Sendable {
    static let port: UInt16 = 6800
    private var listener: NWListener?
    private weak var store: DownloadStore?
    private let token: String

    @MainActor init(store: DownloadStore) {
        self.store = store
        token = store.engineToken
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: .global())
        listener = l
    }

    // MARK: 极简 HTTP：读完头和 Content-Length 指定的正文，回一个 JSON

    private func serve(_ c: NWConnection) {
        c.start(queue: .global())
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Request(buf) {
                Task { let (status, body) = await self.handle(req); self.reply(c, status: status, body: body) }
            } else if done || err != nil || buf.count > 8 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func reply(_ c: NWConnection, status: Int, body: Data) {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    struct Request {
        var method: String, path: String, headers: [String: String], body: Data
        init?(_ data: Data) {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)),
                  let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count >= 2 else { return nil }
            var h: [String: String] = [:]
            for l in lines.dropFirst() {
                if let i = l.firstIndex(of: ":") { h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) }
            }
            let len = Int(h["content-length"] ?? "0") ?? 0
            let body = data[end.upperBound...]
            guard body.count >= len else { return nil }
            method = String(first[0]); path = String(first[1]); headers = h; self.body = Data(body.prefix(len))
        }
    }

    private func json(_ obj: Any) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8) }

    private func handle(_ r: Request) async -> (Int, Data) {
        if r.method == "OPTIONS" { return (200, Data()) }
        if r.path.hasPrefix("/jsonrpc") { return (200, await aria2(r.body)) }
        if r.path.hasPrefix("/api/v1/") { return await gopeed(r) }
        return (404, json(["error": "not found"]))
    }

    // MARK: Aria2 RPC

    private func aria2(_ body: Data) async -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: body) else { return json(["jsonrpc": "2.0", "error": ["code": -32700, "message": "Parse error"]]) }
        if let batch = obj as? [[String: Any]] {
            var out: [[String: Any]] = []
            for call in batch { out.append(await aria2Call(call)) }
            return json(out)
        }
        return json(await aria2Call(obj as? [String: Any] ?? [:]))
    }

    private func aria2Call(_ call: [String: Any]) async -> [String: Any] {
        let id = call["id"] ?? NSNull()
        var params = call["params"] as? [Any] ?? []
        func fail(_ code: Int, _ msg: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": msg]] }
        if let first = params.first as? String, first.hasPrefix("token:") {
            guard first.dropFirst(6) == token else { return fail(1, "Unauthorized") }
            params.removeFirst()
        } else { return fail(1, "Unauthorized") }
        switch call["method"] as? String ?? "" {
        case "aria2.getVersion":
            return ["jsonrpc": "2.0", "id": id, "result": ["version": "1.37.0", "enabledFeatures": ["Shandian"]]]
        case "aria2.addUri":
            let uris = params.first as? [String] ?? []
            let opts = params.count > 1 ? params[1] as? [String: Any] ?? [:] : [:]
            guard let url = uris.first else { return fail(1, "No URI") }
            var headers: [String: String] = [:]
            for line in opts["header"] as? [String] ?? [] {
                if let i = line.firstIndex(of: ":") { headers[String(line[..<i])] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces) }
            }
            let name = opts["out"] as? String
            await MainActor.run { store?.add(link: url, headers: headers, name: name); store?.section = .active }
            return ["jsonrpc": "2.0", "id": id, "result": String(format: "%016llx", UInt64.random(in: 0...UInt64.max))]
        case "aria2.tellActive", "aria2.tellWaiting", "aria2.tellStopped":
            return ["jsonrpc": "2.0", "id": id, "result": []]
        default:
            return fail(1, "Method not supported")
        }
    }

    // MARK: Gopeed 扩展

    private func gopeed(_ r: Request) async -> (Int, Data) {
        guard r.headers["x-api-token"] == token else { return (401, json(["code": 1, "msg": "unauthorized"])) }
        let path = r.path.components(separatedBy: "?")[0]
        if r.method == "POST", path == "/api/v1/tasks",
           let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
           let req = obj["req"] as? [String: Any], let url = req["url"] as? String, LinkKind.of(url) != nil {
            let headers = ((req["extra"] as? [String: Any])?["header"] as? [String: String]) ?? [:]
            let name = (obj["opts"] as? [String: Any])?["name"] as? String
            await MainActor.run { store?.add(link: url, headers: headers, name: name); store?.section = .active }
            return (200, json(["code": 0, "msg": "", "data": "shandian-" + UUID().uuidString]))
        }
        guard let store else { return (502, Data()) }
        return await store.forwardToEngine(method: r.method, path: r.path, body: r.body)
    }
}
