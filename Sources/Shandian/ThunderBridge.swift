import AppKit
@preconcurrency import ApplicationServices

/// 迅雷通道：国内热门资源常在迅雷用户之间传，BT 网络里几乎没人（10-28 实测同一部片 BT 0、迅雷不开会员 3–5 MB/s）。
/// 慢了就交给本机装着的迅雷下。不碰迅雷的协议和会员：只像用户一样用迅雷打开链接、点「立即下载」（辅助功能），
/// 再看它写进硬盘的文件算进度，任务照样显示在闪电下载里。
struct ThunderJob: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var link: String
    var dir: String              // 交给迅雷时的保存位置
    var folder: String?          // 迅雷建的任务文件夹（找到后记下）
    var hash: String?            // 磁力的 infohash（大写），迅雷在文件夹里放 .<hash>.js 进度文件，靠它认
    var total: Int64
    var createdAt: Date
    var done = false
    var bytes: Int64 = 0
    var speed: Int64 = 0
    var measuredAt: Date?
}

@MainActor
enum ThunderBridge {
    static let app = URL(fileURLWithPath: "/Applications/Thunder.app")
    static var installed: Bool { FileManager.default.fileExists(atPath: app.path) }
    static var store: URL { EngineConfig.supportDir.appendingPathComponent("thunder.json") }

    static func load() -> [ThunderJob] {
        guard let d = try? Data(contentsOf: store) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([ThunderJob].self, from: d)) ?? []
    }

    static func save(_ jobs: [ThunderJob]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(jobs) { try? d.write(to: store) }
    }

    /// 磁力里的 infohash，统一成 40 位大写十六进制（base32 的也换算）
    static func infoHash(_ link: String) -> String? {
        guard let r = link.range(of: #"btih:([A-Za-z0-9]+)"#, options: .regularExpression) else { return nil }
        let h = String(link[r].dropFirst(5))
        if h.count == 40 { return h.uppercased() }
        guard h.count == 32 else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = "", out = ""
        for ch in h.uppercased() {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            bits += String(v, radix: 2).leftPad(5)
        }
        for i in stride(from: 0, to: 160, by: 4) {
            let s = bits.index(bits.startIndex, offsetBy: i)
            out += String(Int(bits[s..<bits.index(s, offsetBy: 4)], radix: 2)!, radix: 16)
        }
        return out.uppercased()
    }

    /// 用迅雷打开链接（保存位置预设好），再替用户点迅雷新建任务窗口里的「立即下载」
    static func open(link: String, saveDir: String, onClicked: @escaping (Bool) -> Void) {
        UserDefaults(suiteName: "com.xunlei.Thunder")?.set(saveDir, forKey: "LastSavePath")
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        Task {
            // 第一次会请求「辅助功能」权限；没给就只能让用户自己在迅雷里点
            guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
                onClicked(false); return
            }
            for _ in 0..<40 {
                if pressDownload() { onClicked(true); return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            onClicked(false)
        }
    }

    /// 在迅雷的「新建下载任务 / 新建 BT 任务」窗口里找「立即下载」按钮按下
    private static func pressDownload() -> Bool {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.xunlei.Thunder").first?.processIdentifier
        else { return false }
        let appEl = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else { return false }
        for w in wins where (attr(w, kAXTitleAttribute) ?? "").hasPrefix("新建") {
            if let b = findButton(w, title: "立即下载", depth: 0) {
                return AXUIElementPerformAction(b, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func findButton(_ e: AXUIElement, title: String, depth: Int) -> AXUIElement? {
        if attr(e, kAXRoleAttribute) == kAXButtonRole, attr(e, kAXTitleAttribute) == title { return e }
        guard depth < 8 else { return nil }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success,
              let list = kids as? [AXUIElement] else { return nil }
        for k in list { if let b = findButton(k, title: title, depth: depth + 1) { return b } }
        return nil
    }

    /// 量一次进度：迅雷边下边写，文件实际占用的空间就是已下的量；隐藏的 .js 是迅雷的进度文件，没了就是下完
    static func measure(_ job: inout ThunderJob) {
        let fm = FileManager.default
        if job.folder == nil {
            // 按 .<hash>.js 找迅雷建的文件夹；没 hash 的只能按创建时间找最新的
            let dir = URL(fileURLWithPath: job.dir)
            let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [])) ?? []
            if let h = job.hash {
                // 迅雷里已有同一个任务时它不另存，会沿用原来的位置：在「下载」里（两层内）也找一下
                let downloads = (try? fm.contentsOfDirectory(at: Folders.downloads, includingPropertiesForKeys: nil)) ?? []
                let deeper = downloads.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
                job.folder = (kids + downloads + deeper).first { fm.fileExists(atPath: $0.appendingPathComponent(".\(h).js").path) }?.path
            } else {
                job.folder = kids.filter { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > job.createdAt }
                    .max { a, b in
                        ((try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                            < ((try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                    }?.path
            }
        }
        guard let folder = job.folder else { return }
        var bytes: Int64 = 0, hiddenProgress = 0
        let en = fm.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        while let f = en?.nextObject() as? URL {
            if f.lastPathComponent.hasPrefix(".") {
                if f.pathExtension == "js" { hiddenProgress += 1 }
                continue
            }
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { bytes += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        let now = Date()
        if let t = job.measuredAt, now.timeIntervalSince(t) > 0.5 {
            let s = Double(max(0, bytes - job.bytes)) / now.timeIntervalSince(t)
            job.speed = Int64(Double(job.speed) * 0.6 + s * 0.4)
        }
        job.bytes = bytes; job.measuredAt = now
        if hiddenProgress == 0, bytes > 0 { job.done = true; job.speed = 0; if job.total == 0 { job.total = bytes } }
    }

    /// 任务文件夹里最大的那个文件（截图、播放用）
    static func mainFile(_ job: ThunderJob) -> URL? {
        guard let folder = job.folder else { return nil }
        let fm = FileManager.default
        let files = (fm.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        return files.max { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}
