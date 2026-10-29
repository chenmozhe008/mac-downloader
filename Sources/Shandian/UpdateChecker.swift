import AppKit
import CryptoKit

/// 检查更新与一键更新（沿用小清）：每天最多查一次 GitHub 最新正式版（不含预发布，Windows 的 `win-v…` 不算）。
/// 有新版时在 App 里下载本机芯片对应的安装包（显示进度）→ 对 GitHub 给的 SHA-256 → 核对 bundle id、版本号和签名 →
/// 旧版移到废纸篓、新版放回原处 → 退出（任务先暂停）后重新打开，下载自动续上。
/// App 自己下载的文件不带隔离标记，Gatekeeper 不会拦新版
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable, Codable {
        let version: String
        let page: URL
        /// The zip to install; nil when the release has none (then the button opens the release page).
        let asset: URL?
        /// "sha256:…" from GitHub's asset listing.
        let digest: String?
        /// Bullets of the release's "更新内容" section.
        let notes: [String]
    }

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case installing
    }

    @Published private(set) var available: Release?
    @Published private(set) var phase: Phase = .idle
    @Published var automatic = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automatic, forKey: Keys.automatic)
            if automatic { checkIfDue() } else { available = nil }
        }
    }

    /// `SHANDIAN_UPDATE_FEED=<url>` stands in for GitHub's answer (a file:// JSON in tests of the install flow).
    private static var latestAPI: URL {
        ProcessInfo.processInfo.environment["SHANDIAN_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/chenmozhe008/shandian-download/releases/latest")!
    }

    private enum Keys {
        static let automatic = "updateAutoCheck"
        static let lastCheck = "updateLastCheck"
        static let latest = "updateLatestRelease"
    }

    /// On launch: use the answer from today's check, or ask GitHub if the last one is a day old.
    func checkIfDue() {
        // `SHANDIAN_PRETEND_UPDATE=9.9.9` shows the notice without a release (screenshots).
        if let pretend = ProcessInfo.processInfo.environment["SHANDIAN_PRETEND_UPDATE"] {
            available = Release(version: pretend, page: URL(string: "https://github.com/chenmozhe008/shandian-download/releases/latest")!,
                                asset: nil, digest: nil, notes: [])
            return
        }
        guard automatic, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Keys.lastCheck) as? Date, Date().timeIntervalSince(last) < 86_400,
           ProcessInfo.processInfo.environment["SHANDIAN_UPDATE_FEED"] == nil {
            if let data = defaults.data(forKey: Keys.latest), let release = try? JSONDecoder().decode(Release.self, from: data) {
                show(release)
            }
            return
        }
        Task { await check() }
    }

    /// Asks GitHub now. Returns nil when offline or GitHub did not answer.
    @discardableResult
    func check() async -> Release? {
        var request = URLRequest(url: Self.latestAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200,
              let release = Self.parse(data) else { return nil }
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: Keys.lastCheck)
        defaults.set(try? JSONEncoder().encode(release), forKey: Keys.latest)
        show(release)
        // `SHANDIAN_AUTO_INSTALL=1` (tests only, with SHANDIAN_UPDATE_FEED): install without the confirmation dialog.
        if ProcessInfo.processInfo.environment["SHANDIAN_AUTO_INSTALL"] != nil, let available { install(available) }
        return release
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        // 按芯片分包：Shandian-<版本>-AppleSilicon.zip / -Intel.zip（Rosetta 下 uname 不准，看 hw.optional.arm64）
        let chip = isAppleSilicon ? "-AppleSilicon.zip" : "-Intel.zip"
        let zip = assets.first { ($0["name"] as? String)?.hasPrefix("Shandian-") == true && ($0["name"] as? String)?.hasSuffix(chip) == true }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page,
                       asset: (zip?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                       digest: zip?["digest"] as? String,
                       notes: notes(json["body"] as? String ?? ""))
    }

    /// The "- " lines under the release's "更新内容" heading.
    nonisolated static func notes(_ body: String) -> [String] {
        var inSection = false
        var lines: [String] = []
        for line in body.components(separatedBy: .newlines) {
            if line.hasPrefix("#") { inSection = line.contains("更新内容"); continue }
            if inSection, line.hasPrefix("- ") { lines.append(String(line.dropFirst(2))) }
        }
        return lines
    }

    /// The menu's 检查更新…: asks now and says what it found.
    func checkFromMenu() {
        Task {
            let release = await check()
            if let release, Self.isNewer(release.version, than: AppInfo.version) {
                offer(release)
            } else {
                let alert = NSAlert()
                alert.messageText = release == nil ? "无法检查更新" : "闪电全能下载已是最新版本"
                alert.informativeText = release == nil ? "未能连接 GitHub，请检查网络后重试。" : "当前版本 \(AppInfo.version)。"
                alert.runModal()
            }
        }
    }

    /// The top bar's 新版本 button.
    func offerAvailable() {
        if let available, phase == .idle { offer(available) }
    }

    /// What is new, and one button that downloads, installs and reopens.
    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "新版本 \(release.version) 可用"
        var text = "当前版本 \(AppInfo.version)。下载完成后自动更新并重新打开；正在下载的任务会先暂停，重新打开后继续。"
        if !release.notes.isEmpty {
            text += "\n\n" + release.notes.prefix(6).map { "• " + $0 }.joined(separator: "\n")
        }
        alert.informativeText = text
        alert.addButton(withTitle: release.asset == nil ? "前往下载" : "更新并重新打开")
        alert.addButton(withTitle: "以后")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if release.asset == nil { NSWorkspace.shared.open(release.page) } else { install(release) }
    }

    // MARK: Installing

    func install(_ release: Release) {
        guard phase == .idle, let asset = release.asset else { return }
        phase = .downloading(0)
        Task {
            do {
                let zip = try await Self.download(asset) { fraction in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.phase { self?.phase = .downloading(fraction) }
                    }
                }
                phase = .installing
                let app = try await Task.detached { try Self.prepare(zip, release: release) }.value
                try Self.swapAndRelaunch(with: app)
                NSApp.terminate(nil)
            } catch {
                phase = .idle
                let alert = NSAlert()
                alert.messageText = "未能完成更新"
                alert.informativeText = "\(error.localizedDescription)\n\n可以前往 GitHub 下载与本机芯片对应的安装包，手动替换「应用程序」中的闪电全能下载。"
                alert.addButton(withTitle: "前往下载")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
            }
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private nonisolated static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    /// Unpacks the download and makes sure it is the app it claims to be, ready to put in place.
    private nonisolated static func prepare(_ zip: URL, release: Release) throws -> URL {
        if let digest = release.digest, digest.hasPrefix("sha256:") {
            let data = try Data(contentsOf: zip, options: .mappedIfSafe)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == digest.dropFirst("sha256:".count).lowercased() else { throw UpdateError("下载的文件不完整或已损坏。") }
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "shandian-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) else { throw UpdateError("无法解压下载的文件。") }
        let apps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" }), let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError("下载的文件不是闪电全能下载 \(release.version)。")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else { throw UpdateError("新版本的签名校验未通过。") }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Moves the running app to the Trash (macOS allows this; the process keeps running), puts the new one in
    /// its place, and leaves a small script to open it once this process has quit. A failed move puts the old app back.
    private static func swapAndRelaunch(with app: URL) throws {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError("没有权限替换「\(target.deletingLastPathComponent().path)」中的闪电全能下载。")
        }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: target, resultingItemURL: &trashed)
        do {
            try FileManager.default.moveItem(at: app, to: target)
        } catch {
            if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: target) }
            throw UpdateError("无法替换闪电全能下载：\(error.localizedDescription)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\"",
                             "shandian-update", String(getpid()), target.path]
        try process.run()
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    nonisolated static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    private func show(_ release: Release) {
        available = automatic && Self.isNewer(release.version, than: AppInfo.version) ? release : nil
    }

    /// Numeric, part by part: 1.10.0 is newer than 1.9.2. A development build ("开发版") never asks.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parse = { (value: String) in value.split(separator: ".").map { Int($0) } }
        let new = parse(candidate), old = parse(current)
        guard !new.contains(nil), !old.contains(nil), !old.isEmpty else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index]! : 0
            let b = index < old.count ? old[index]! : 0
            if a != b { return a > b }
        }
        return false
    }
}

/// Reports download progress and hands back the finished file (moved out of URLSession's temporary spot,
/// which is deleted as soon as the callback returns).
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?

    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            continuation?.resume(throwing: UpdateChecker.UpdateError("下载失败（HTTP \(status)）。"))
            continuation = nil
            return
        }
        let kept = FileManager.default.temporaryDirectory.appending(path: "shandian-update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: UpdateChecker.UpdateError("下载中断：\(error.localizedDescription)"))
        continuation = nil
    }
}
