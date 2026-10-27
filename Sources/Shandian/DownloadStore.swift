import AppKit
import DiskArbitration
import SwiftUI
import Foundation
@preconcurrency import UserNotifications

/// 界面上的一条下载，内核任务和视频站任务统一成这一种
struct Item: Identifiable, Equatable {
    enum Source: Equatable { case engine(String), video(UUID), pending }
    enum Status: Equatable { case resolving(Date), running, waiting, paused, done, failed(String) }

    var id: String
    var source: Source
    var title: String
    var rawTitle: String        // 原始发布名，悬停时显示
    var origin: String          // 磁力 / 种子文件 / B 站 / 夸克网盘 / 域名
    var category: Category
    var status: Status
    var downloaded: Int64
    var total: Int64
    var speed: Int64
    var file: URL?              // 主文件（截图、打开都用它）
    var createdAt: Date
    var thumbRemote: String?
    var linkKey: String         // 去重用：磁力 hash 或原始链接
    var location: URL? = nil    // 移到废纸篓时扔这个：多文件种子是整个文件夹，其余同 file
    var checking = false        // 重启后内核在校验已下载部分：进度从 0 涨回去，那段「速度」是读本地硬盘，不算下载
    var fileGone = false        // 下完后文件被用户在访达里删了或移走（硬盘没插不算）
    var avgSpeed: Int64 = 0     // 平滑后的速度，算剩余时间用；瞬时速度跳得厉害，行内和顶部估算会对不上

    var progress: Double { total > 0 ? min(1, Double(downloaded) / Double(total)) : 0 }
    var isActive: Bool { if case .done = status { return false }; return true }
}

enum Pane: Hashable {
    case active, done, category(Category)
    var title: String {
        switch self {
        case .active: "正在下载"
        case .done: "已完成"
        case .category(let c): c.rawValue
        }
    }
}

enum EngineState: Equatable { case starting, running, failed(String) }

@MainActor
final class DownloadStore: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var speedHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var engineState: EngineState = .starting
    @Published var section: Pane = .active
    @Published var search = ""
    @Published var showNewSheet = false
    @Published var newLinksText = ""
    @Published var clipboardLinks: [String]?     // 剪贴板里发现的新链接（一段文字里可能有多个）
    /// 顶部一行提示（重复链接、失败原因），6 秒后自动收起
    @Published var notice: String? {
        didSet {
            noticeTimer?.cancel()
            guard notice != nil else { return }
            noticeTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !Task.isCancelled { self?.notice = nil }
            }
        }
    }
    private var noticeTimer: Task<Void, Never>?
    @Published var hoveredID: String?
    @Published var removalTarget: Item?          // 等待确认移除的任务
    @Published var selectedID: String?           // 列表里单击选中的任务（高亮、键盘操作对象）

    let thumbs = Thumbnails()
    private var watcher: ClipboardWatcher?
    private var gateway: Gateway?
    private let host = EngineHost()
    private let videoRunner = VideoSiteRunner()
    private let sleepGuard = SleepGuard()
    private var videoJobs: [VideoJob] = []
    private var pending: [Item] = []
    private var engineItems: [Item] = []
    private var lastStatus: [String: Item.Status] = [:]
    private var engineSeeded = false   // 启动后第一次拿到内核任务列表之前，已完成的都是老任务，不发通知
    private var smoothSpeed: [String: Double] = [:]
    private var autoRetries: [String: (count: Int, at: Date)] = [:]
    /// 退出时各 BT 任务已下的量；重启后低于它就是在校验
    private var checkFloor: [String: Int64] = (UserDefaults.standard.dictionary(forKey: "progressAtQuit") as? [String: Int64]) ?? [:]
    private var seenClipboard = Set<String>()
    private var pollTask: Task<Void, Never>?
    private let videosFile = EngineConfig.supportDir.appendingPathComponent("videos.json")

    nonisolated static let panHosts: [(String, String)] = [("baidupcs.com", "百度网盘"), ("baidu.com", "百度网盘"), ("quark.cn", "夸克网盘"),
        ("aliyundrive", "阿里云盘"), ("alipan", "阿里云盘"), ("123pan", "123 云盘"), ("123684", "123 云盘"), ("189.cn", "天翼云盘"),
        ("ctyunxs", "天翼云盘"), ("139.com", "移动云盘"), ("uc.cn", "UC 网盘"), ("xunlei.com", "迅雷云盘")]

    @Published private(set) var diskMounted = Folders.diskMounted
    private var pausedForEject = Set<String>()

    /// 推出硬盘：内核暂停后仍开着那块盘上的文件，盘会推不出。用 DiskArbitration 在系统批准推出前先处理：
    /// 记下要续的任务 → 全部暂停 → 结束内核（文件随之关闭）→ 批准推出 → 2 秒后重启内核，不在这块盘上的任务接着下
    private var daSession: DASession?

    private func watchVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.volumesChanged() }
            }
        }
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        daSession = session
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskUnmountApprovalCallback(session, nil, { disk, ctx in
            guard let ctx, let desc = DADiskCopyDescription(disk) as? [CFString: Any],
                  let url = desc[kDADiskDescriptionVolumePathKey] as? URL else { return nil }
            let store = Unmanaged<DownloadStore>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { store.releaseVolume(url.path) }
            return nil   // 批准
        }, ctx)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func releaseVolume(_ vol: String) {
        // 直接看内核开着哪些文件：任务删了、完成了，内核也可能还开着
        // 刚启动、内核状态还没就绪时也要处理，只看内核实际开着的文件
        guard host.holdsFiles(on: vol) else { return }
        let running = engineItems.filter { $0.isActive && $0.status != .paused }
        for i in running { if case .engine(let id) = i.source { pausedForEject.insert(id) } }
        host.suspend()
        host.kill()
        engineState = .starting
        notice = "已为推出硬盘暂停下载，硬盘插回后接着下"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await startEngine()
            volumesChanged()   // 不在被推出的盘上的任务马上续
        }
    }

    private func volumesChanged() {
        diskMounted = Folders.diskMounted
        guard !pausedForEject.isEmpty, engineState == .running else { return }
        Task {
            guard let tasks = try? await host.client.tasks() else { return }
            for t in tasks where pausedForEject.contains(t.id) && Self.volumeAvailable(t.meta.opts?.path) {
                try? await host.client.resume(t.id); pausedForEject.remove(t.id)
            }
        }
    }

    /// 路径所在的盘插着没有（本机路径总是在）
    nonisolated static func volumeAvailable(_ path: String?) -> Bool {
        guard let path else { return true }
        let c = URL(fileURLWithPath: path).pathComponents
        guard c.count > 2, c[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/" + c[2])
    }

    init() {
        loadVideos()
        watchVolumes()
        Task { await boot() }
        watcher = ClipboardWatcher(store: self)
        gateway = Gateway(store: self); gateway?.start()
        Task.detached { await YtDlp.ensureFresh() }
        BrowserExtension.install()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkClipboard() }
        }
    }

    // MARK: 启动与轮询

    func boot() async {
        await startEngine()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    var engineToken: String { host.stored.token }

    /// 偏好设置改了同时下载数等，重新写进内核
    func reapplyEngineSettings() {
        guard engineState == .running else { return }
        Task { await host.client.applySettings(defaultDir: Folders.downloads.path) }
    }
    func forwardToEngine(method: String, path: String, body: Data?) async -> (Int, Data) {
        await host.client.forward(method: method, path: path, body: body)
    }

    /// 退出时暂停所有任务（内核不关），记下正在下的，下次打开接着下
    func shutdown() {
        let running = engineItems.filter { $0.isActive && $0.status != .paused }.compactMap { i -> String? in
            if case .engine(let id) = i.source { return id }; return nil
        }
        UserDefaults.standard.set(running, forKey: "resumeOnLaunch")
        var floor: [String: Int64] = [:]
        // 取较大的：还在校验时退出，内核报的是校验进度，比真实已下的少
        for i in engineItems where i.isActive { floor[i.id] = max(i.downloaded, checkFloor[i.id] ?? 0) }
        UserDefaults.standard.set(floor, forKey: "progressAtQuit")
        videoRunner.cancelAll()
        host.suspend()
    }

    private func startEngine() async {
        engineState = .starting
        await LocalProxy.check()
        switch await host.start() {
        case .running:
            engineState = .running
            await host.client.applySettings(defaultDir: Folders.downloads.path)
            // 存在没插着的硬盘上的不续，等插上（diskMounted 通知）再续
            let ids = UserDefaults.standard.stringArray(forKey: "resumeOnLaunch") ?? []
            if let tasks = try? await host.client.tasks() {
                for t in tasks where ids.contains(t.id) {
                    if Self.volumeAvailable(t.meta.opts?.path) { try? await host.client.resume(t.id) } else { pausedForEject.insert(t.id) }
                }
            }
            UserDefaults.standard.removeObject(forKey: "resumeOnLaunch")
        case .failed(let m): engineState = .failed(m)
        }
    }

    private func poll() async {
        var firstLoad = false
        if engineState == .running, let tasks = try? await host.client.tasks() {
            firstLoad = !engineSeeded
            engineItems = tasks.map(Self.item(from:))
            for k in engineItems.indices {
                let id = engineItems[k].id
                guard let floor = checkFloor[id] else { continue }
                if engineItems[k].status == .running, engineItems[k].downloaded < floor - floor / 50 {
                    engineItems[k].checking = true; engineItems[k].speed = 0
                    engineItems[k].downloaded = floor  // 进度条停在退出前的位置，不往回跳
                } else if !engineItems[k].isActive || engineItems[k].downloaded > floor + 50 << 20 {
                    // 刚启动时内核先报退出前的值、过几秒才掉到 0 开始校验，所以要明显超过才算校验完
                    checkFloor[id] = nil
                }
            }
        }
        // 指数平滑，约 5 次轮询的窗口；行内剩余时间和顶部「全部完成」用同一个值
        var next: [String: Double] = [:]
        for i in engineItems + videoJobs.map(Self.item(from:)) where i.status == .running {
            next[i.id] = smoothSpeed[i.id].map { $0 * 0.8 + Double(i.speed) * 0.2 } ?? Double(i.speed)
        }
        smoothSpeed = next
        rebuild()
        if firstLoad { engineSeeded = true }
        sleepGuard.update(downloading: items.contains { $0.status == .running })
        autoRetry()
        let total = items.reduce(Int64(0)) { $0 + ($1.isActive ? $1.speed : 0) }
        speedHistory.append(Double(total)); speedHistory.removeFirst(speedHistory.count - 60)
    }

    private func rebuild() {
        let videos = videoJobs.map(Self.item(from:))
        var all = pending + engineItems + videos
        all.sort { $0.createdAt > $1.createdAt }
        for k in all.indices {
            all[k].avgSpeed = Int64(smoothSpeed[all[k].id] ?? 0)
            if !all[k].isActive, let f = all[k].location ?? all[k].file { all[k].fileGone = Self.isGone(f) }
        }
        // 从未完成变成完成；小文件一个轮询周期就下完，第一次出现就是完成的也算（启动时已有的老任务除外）
        for i in all where i.status == .done && (lastStatus[i.id].map { $0 != .done } ?? engineSeeded) { didFinish(i) }
        for i in all { lastStatus[i.id] = i.status }
        for i in all where i.category == .movie || i.category == .other {
            if let f = i.file, FileSelection.videoExt.contains(f.pathExtension.lowercased()) {
                thumbs.requestFrame(id: i.id, video: f, progress: i.progress)
            }
        }
        for i in all where i.thumbRemote != nil { thumbs.requestRemote(id: i.id, url: i.thumbRemote) }
        if all != items { items = all }
    }

    /// 内核任务失败（断网、服务器临时出错）自动重试，间隔 30 秒、最多 3 次；还不行就留给用户手动重试
    private func autoRetry() {
        for i in engineItems {
            guard case .failed = i.status, case .engine(let id) = i.source else { continue }
            let r = autoRetries[i.id] ?? (0, .distantPast)
            guard r.count < 3, Date().timeIntervalSince(r.at) > 30 else { continue }
            autoRetries[i.id] = (r.count + 1, Date())
            Task { try? await host.client.resume(id) }
        }
    }

    /// 文件不在了才算；所在的移动硬盘没插上时不算，免得一拔硬盘满屏「已删除」
    private static func isGone(_ f: URL) -> Bool {
        let comps = f.pathComponents
        if comps.count > 2, comps[1] == "Volumes", !FileManager.default.fileExists(atPath: "/Volumes/" + comps[2]) { return false }
        return !FileManager.default.fileExists(atPath: f.path)
    }

    // MARK: 视图用

    var totalSpeed: Int64 { items.reduce(0) { $0 + ($1.isActive ? $1.speed : 0) } }
    var activeItems: [Item] { filtered(items.filter(\.isActive)) }
    var doneItems: [Item] { filtered(items.filter { !$0.isActive }) }
    func items(in c: Category) -> [Item] { filtered(items.filter { $0.category == c }) }
    func count(_ s: Pane) -> Int {
        switch s {
        case .active: items.filter(\.isActive).count
        case .done: items.filter { !$0.isActive }.count
        case .category(let c): items.filter { $0.category == c }.count
        }
    }
    private func filtered(_ list: [Item]) -> [Item] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? list : list.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    /// 剩余时间按最近 5 秒的平均速度估，不跟着瞬时速度乱跳
    var etaAll: Double {
        let left = items.filter(\.isActive).reduce(Int64(0)) { $0 + max(0, $1.total - $1.downloaded) }
        let avg = items.filter(\.isActive).reduce(Int64(0)) { $0 + $1.avgSpeed }
        return avg > 0 ? Double(left) / Double(avg) : .infinity
    }

    /// 当前页面里按显示顺序排列的任务（键盘上下移动用）
    var visibleItems: [Item] {
        switch section {
        case .active: activeItems
        case .done: doneItems
        case .category(let c): items(in: c).filter(\.isActive) + items(in: c).filter { !$0.isActive }
        }
    }

    /// 双击 / 回车：下载中的暂停或继续，失败的重试，下完的打开
    func primaryAction(_ item: Item) {
        if item.fileGone { return }
        if !item.isActive { open(item); return }
        if case .failed = item.status { retry(item); return }
        togglePause(item)
    }

    /// 键盘：↑↓ 选择，空格 / 回车 暂停继续（下完的打开），Delete 移除（先确认）
    func handleKey(_ key: KeyEquivalent) -> Bool {
        let list = visibleItems
        guard !list.isEmpty else { return false }
        let i = list.firstIndex { $0.id == selectedID }
        switch key {
        case .downArrow: selectedID = list[min((i ?? -1) + 1, list.count - 1)].id
        case .upArrow: selectedID = list[max((i ?? list.count) - 1, 0)].id
        case .space, .return: if let i { primaryAction(list[i]) } else { return false }
        case .delete, .deleteForward: if let i { removalTarget = list[i] } else { return false }
        default: return false
        }
        return true
    }

    // MARK: 添加

    /// 粘贴、拖入、浏览器传来的都走这里；一段文字里有多个链接就逐个加
    func add(text: String) {
        let links = LinkKind.of(text) != nil ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : LinkKind.extract(from: text)
        guard !links.isEmpty else { notice = "没有识别到可下载的链接"; return }
        request(links)
        section = .active
    }

    func add(link: String) { add(link: link, headers: [:], name: nil) }

    /// headers/name 来自浏览器（自带扩展、LinkSwift 经网关传来），网盘直链靠它们鉴权
    func add(link: String, headers: [String: String], name: String?) { request([link], headers: headers, name: name) }

    /// 所有入口都走这里：去掉已在列表里的，再弹新建任务确认框（关掉询问时直接下载）
    func request(_ links: [String], headers: [String: String] = [:], name: String? = nil) {
        var fresh: [String] = []
        for l in links where LinkKind.of(l) != nil {
            seenClipboard.insert(l)
            if let existing = items.first(where: { $0.linkKey == Self.linkKey(l) }) { notice = "「\(existing.title)」已在列表中"; continue }
            if !fresh.contains(l) { fresh.append(l) }
        }
        guard !fresh.isEmpty else { return }
        if fresh.contains(where: { LinkKind.of($0) != .videoSite }), engineState != .running {
            notice = "下载内核未运行"
            return
        }
        if NewTaskPanels.ask {
            NewTaskPanels.shared.present(links: fresh, headers: headers, name: name, store: self)
        } else {
            fresh.forEach { start(link: $0, headers: headers, name: fresh.count == 1 ? name : nil) }
        }
    }

    /// 确认框里预读文件名、大小、种子文件列表；网页上的种子先取回
    func resolveForPanel(_ link: String, headers: [String: String]) async -> ResolvedResource? {
        guard let kind = LinkKind.of(link) else { return nil }
        var url = link
        if kind == .torrentFile {
            if link.lowercased().hasPrefix("http") {
                guard let data = await Self.fetchTorrent(link) else { return nil }
                url = "data:application/x-bittorrent;base64," + data.base64EncodedString()
            } else { url = Self.torrentDataURL(link) ?? link }
        }
        return try? await host.client.resolve(url: url)
    }

    /// 真正开始下载。dir / selectFiles 来自确认框；不给就按默认规则（按类型存、种子只选正片）
    func start(link: String, headers: [String: String] = [:], name: String? = nil, dir chosen: URL? = nil, selectFiles chosenFiles: [Int]? = nil) {
        guard let kind = LinkKind.of(link) else { return }
        let key = Self.linkKey(link)
        if items.contains(where: { $0.linkKey == key }) { return }
        let dir = chosen ?? Folders.directory(for: kind)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if kind == .videoSite {
            let job = VideoJob(url: link, title: link, site: VideoSiteRunner.siteName(link), options: VideoOptions.current)
            videoJobs.append(job); saveVideos(); rebuild()
            selectedID = job.id.uuidString
            notice = "已添加：\(VideoSiteRunner.siteName(link)) 视频"
            videoRunner.start(job, into: dir) { [weak self] updated in
                Task { @MainActor in self?.updateVideo(updated) }
            }
            return
        }

        let localTorrent = kind == .torrentFile && !link.lowercased().hasPrefix("http")
        let url = localTorrent ? Self.torrentDataURL(link) ?? link : link
        if kind == .magnet || kind == .torrentFile {
            // 先解析文件列表，只勾主视频和字幕；磁力要先从网络拿到种子信息
            let placeholder = Item(id: "pending-" + UUID().uuidString, source: .pending, title: PrettyTitle.clean(Self.displayName(link)), rawTitle: Self.displayName(link),
                                   origin: kind == .magnet ? "磁力" : "种子文件", category: .movie, status: .resolving(Date()),
                                   downloaded: 0, total: 0, speed: 0, file: nil, createdAt: Date(), thumbRemote: nil, linkKey: key)
            pending.append(placeholder); rebuild()
            selectedID = placeholder.id
            notice = "已添加：\(placeholder.title)"
            Task {
                // 网页上的种子链接：内核会把它当普通文件下载，先取回种子再按本地种子交给内核
                var url = url
                if kind == .torrentFile, !localTorrent {
                    guard let data = await Self.fetchTorrent(link) else {
                        notice = "无法获取种子文件"
                        pending.removeAll { $0.id == placeholder.id }; rebuild(); return
                    }
                    url = "data:application/x-bittorrent;base64," + data.base64EncodedString()
                }
                let select: [Int]?
                if let chosenFiles { select = chosenFiles } else {
                    let resolved = try? await host.client.resolve(url: url)
                    select = resolved.flatMap { FileSelection.pick($0.files) }
                }
                guard pending.contains(where: { $0.id == placeholder.id }) else { return }  // 解析期间被移除了
                do {
                    let id = try await host.client.create(url: url, directory: dir.path, selectFiles: select)
                    if selectedID == placeholder.id { selectedID = id }
                } catch { notice = "添加失败：\(error.localizedDescription)" }
                pending.removeAll { $0.id == placeholder.id }
                await poll()
            }
        } else {
            Task {
                do {
                    selectedID = try await host.client.create(url: url, directory: dir.path, headers: headers, name: name)
                    notice = "已添加：\(name ?? Self.displayName(link))"
                } catch { notice = "添加失败：\(error.localizedDescription)" }
                await poll()
            }
        }
    }

    func submitNewSheet() {
        let text = newLinksText
        newLinksText = ""; showNewSheet = false
        add(text: text)
    }

    // MARK: 操作

    func togglePause(_ item: Item) {
        guard case .engine(let id) = item.source else { return }
        Task {
            if item.status == .paused || { if case .failed = item.status { return true }; return false }() {
                try? await host.client.resume(id)
            } else { try? await host.client.pause(id) }
            await poll()
        }
    }

    var allPaused: Bool { !items.contains { $0.status == .running || $0.status == .waiting } }

    func toggleAll() {
        Task {
            if allPaused { try? await host.client.resumeAll() } else { try? await host.client.pauseAll() }
            await poll()
        }
    }

    /// 移除任务；moveFiles 为真时把文件移到废纸篓（不直接删除）
    func remove(_ item: Item, moveFiles: Bool) {
        let file = item.location ?? item.file
        switch item.source {
        case .engine(let id):
            Task {
                try? await host.client.delete(id, withFiles: false)
                if moveFiles, let f = file { Self.trash(f) }
                await poll()
            }
        case .video(let id):
            videoRunner.cancel(id)
            videoJobs.removeAll { $0.id == id }; saveVideos()
            if moveFiles, let f = file { Self.trash(f) }
            rebuild()
        case .pending:
            pending.removeAll { $0.id == item.id }; rebuild()
        }
    }

    func reveal(_ item: Item) {
        guard let f = item.file else { return }
        if FileManager.default.fileExists(atPath: f.path) { NSWorkspace.shared.activateFileViewerSelecting([f]) }
        else { NSWorkspace.shared.open(f.deletingLastPathComponent()) }
    }

    func open(_ item: Item) {
        guard let f = item.file, FileManager.default.fileExists(atPath: f.path) else { reveal(item); return }
        NSWorkspace.shared.open(f)
    }

    // MARK: 剪贴板

    func checkClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        let links = newClipboardLinks(in: s)
        guard !links.isEmpty else { return }
        markSeen(links)
        clipboardLinks = links
    }

    /// 一段文字里还没提示过、也不在列表中的链接
    func newClipboardLinks(in text: String) -> [String] {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count < 20000 else { return [] }
        let found = LinkKind.of(s) != nil ? [s] : LinkKind.extract(from: s)
        return found.filter { l in !seenClipboard.contains(l) && !items.contains { $0.linkKey == Self.linkKey(l) } }
    }

    func markSeen(_ links: [String]) { links.forEach { seenClipboard.insert($0) } }

    /// 剪贴板浮窗点「下载」
    func addFromPopup(_ links: [String]) {
        request(links)
        section = .active
    }

    func acceptClipboard() {
        if let l = clipboardLinks { request(l) }
        clipboardLinks = nil
        section = .active
    }

    // MARK: 完成通知

    static let doneCategory = "done"

    /// 通知上带「打开」「在访达中显示」两个按钮（AppDelegate 里处理点击）
    static func registerNotificationActions() {
        let open = UNNotificationAction(identifier: "open", title: "打开", options: [])
        let reveal = UNNotificationAction(identifier: "reveal", title: "在访达中显示", options: [])
        UNUserNotificationCenter.current().setNotificationCategories(
            [UNNotificationCategory(identifier: doneCategory, actions: [open, reveal], intentIdentifiers: [])])
    }

    private func didFinish(_ item: Item) {
        guard Prefs.notify else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "下载完成"
            c.body = item.title
            c.sound = .default
            c.categoryIdentifier = Self.doneCategory
            if let f = item.file { c.userInfo = ["path": f.path] }
            center.add(UNNotificationRequest(identifier: item.id, content: c, trigger: nil))
        }
    }

    // MARK: 视频站记录

    private func updateVideo(_ job: VideoJob) {
        guard let i = videoJobs.firstIndex(where: { $0.id == job.id }) else { return }
        videoJobs[i] = job
        if job.state != .running { saveVideos() }
        rebuild()
    }

    private func loadVideos() {
        guard let data = try? Data(contentsOf: videosFile),
              let list = try? JSONDecoder().decode([VideoJob].self, from: data) else { return }
        // 上次没下完的进程已经不在了，标成失败让用户重试
        videoJobs = list.map { var j = $0; if j.state == .running { j.state = .failed; j.error = "上次未完成"; j.speed = 0 }; return j }
    }

    private func saveVideos() {
        if let data = try? JSONEncoder().encode(videoJobs) { try? data.write(to: videosFile) }
    }

    func retry(_ item: Item) {
        switch item.source {
        case .video(let id):
            // 原地重新开始；先删再 add 会被去重挡掉，任务直接消失
            guard let i = videoJobs.firstIndex(where: { $0.id == id }) else { return }
            videoJobs[i].state = .running; videoJobs[i].error = nil
            videoJobs[i].downloaded = 0; videoJobs[i].total = 0; videoJobs[i].speed = 0
            saveVideos(); rebuild()
            videoRunner.start(videoJobs[i], into: Folders.videos) { [weak self] updated in
                Task { @MainActor in self?.updateVideo(updated) }
            }
        case .engine: togglePause(item)
        case .pending: break
        }
    }

    // MARK: 映射

    private static func item(from t: EngineTask) -> Item {
        let url = t.meta.req.url
        let dir = URL(fileURLWithPath: t.meta.opts?.path ?? Folders.downloads.path)
        let files = t.meta.res?.files ?? []
        let selected = (t.meta.opts?.selectFiles?.isEmpty == false ? t.meta.opts!.selectFiles! : Array(files.indices)).filter { $0 < files.count }
        let total = selected.isEmpty ? (t.meta.res?.size ?? 0) : selected.reduce(Int64(0)) { $0 + files[$1].size }
        let resName = t.meta.res?.name ?? ""

        // 主文件：选中文件里最大的那个
        var main: URL?
        if let idx = selected.max(by: { files[$0].size < files[$1].size }) {
            let f = files[idx]
            let rel = [f.path ?? "", f.name].filter { !$0.isEmpty }.joined(separator: "/")
            let candidates = [dir.appendingPathComponent(resName).appendingPathComponent(rel), dir.appendingPathComponent(rel)]
            main = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? (files.count > 1 ? candidates[0] : candidates[1])
        } else if !resName.isEmpty { main = dir.appendingPathComponent(resName) }
        let location = files.count > 1 && !resName.isEmpty ? dir.appendingPathComponent(resName) : main

        let lower = url.lowercased()
        let host = URL(string: url)?.host?.lowercased() ?? ""
        let pan = lower.hasPrefix("http") ? panHosts.first { host.contains($0.0) }?.1 : nil
        let origin: String = lower.hasPrefix("magnet:") ? "磁力" : lower.hasPrefix("data:") ? "种子文件"
            : lower.hasPrefix("ed2k:") ? "ed2k" : pan ?? host
        let isVideo = main.map { FileSelection.videoExt.contains($0.pathExtension.lowercased()) } ?? false
        let category: Category = pan != nil ? .cloud : (t.protocol == "bt" || lower.hasPrefix("ed2k:") || isVideo) ? .movie : .other

        let status: Item.Status = switch t.status {
        case "running": .running
        case "pause": .paused
        case "done": .done
        case "error": .failed("下载出错")
        default: .waiting
        }
        let created = ISO8601DateFormatter.flexible.date(from: t.createdAt ?? "") ?? .distantPast
        let rawTitle = t.name?.isEmpty == false ? t.name! : resName.isEmpty ? displayName(url) : resName
        return Item(id: t.id, source: .engine(t.id), title: PrettyTitle.clean(rawTitle), rawTitle: rawTitle,
                    origin: origin, category: category, status: status, downloaded: min(t.progress.downloaded, max(total, t.progress.downloaded)),
                    total: total, speed: status == .running ? t.progress.speed : 0, file: main, createdAt: created, thumbRemote: nil,
                    linkKey: linkKey(lower.hasPrefix("magnet:") || t.meta.res?.hash == nil ? url : "btih:" + (t.meta.res?.hash ?? "")),
                    location: location)
    }

    private static func item(from j: VideoJob) -> Item {
        let status: Item.Status = switch j.state {
        case .running: .running
        case .done: .done
        case .failed: .failed(j.error ?? "下载失败")
        }
        return Item(id: j.id.uuidString, source: .video(j.id), title: j.title != j.url ? j.title : j.state == .running ? "正在读取视频信息" : displayName(j.url), rawTitle: j.title,
                    origin: j.site, category: .video, status: status, downloaded: j.downloaded, total: j.total, speed: j.speed,
                    file: j.filePath.map { URL(fileURLWithPath: $0) }, createdAt: j.createdAt, thumbRemote: j.thumbnailURL,
                    linkKey: linkKey(j.url))
    }

    /// 磁力按 hash 去重（同一资源不同 tracker 参数算同一个）
    static func linkKey(_ link: String) -> String {
        let l = link.lowercased()
        if let r = l.range(of: "btih:") { return "btih:" + l[r.upperBound...].prefix(40) }
        return l
    }

    static func displayName(_ link: String) -> String {
        if let comps = URLComponents(string: link), let dn = comps.queryItems?.first(where: { $0.name == "dn" })?.value, !dn.isEmpty { return dn }
        if link.lowercased().hasSuffix(".torrent") { return (link as NSString).lastPathComponent.replacingOccurrences(of: ".torrent", with: "") }
        return URL(string: link)?.lastPathComponent.removingPercentEncoding ?? link
    }

    /// 取回网页上的种子文件；海外站点走代理（常被墙），国内站直连
    static func fetchTorrent(_ link: String) async -> Data? {
        guard let u = URL(string: link) else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = LocalProxy.sessionDictionary(for: link)
        cfg.timeoutIntervalForRequest = 30
        guard let (data, resp) = try? await URLSession(configuration: cfg).data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200, data.first == UInt8(ascii: "d") else { return nil }  // 种子是 bencode 字典，以 d 开头
        return data
    }

    static func torrentDataURL(_ path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return "data:application/x-bittorrent;base64," + d.base64EncodedString()
    }

    static func trash(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { _, _ in }
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
