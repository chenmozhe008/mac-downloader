import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import SwiftUI

/// 偏好设置里的开关（UserDefaults 键集中在这里）
enum Prefs {
    static let maxRunningKey = "maxRunning"
    static let preventSleepKey = "preventSleep"
    static let notifyKey = "notifyOnFinish"
    static let downloadLimitKey = "downloadLimit"   // KB/s，0 不限
    static let autoThunderKey = "autoThunder"
    static var autoThunder: Bool { UserDefaults.standard.object(forKey: autoThunderKey) as? Bool ?? false }   // 10-28 用户：不想用迅雷
    static let autoCloudKey = "autoCloud"
    static var autoCloud: Bool { UserDefaults.standard.object(forKey: autoCloudKey) as? Bool ?? true }
    static var downloadLimit: Int { UserDefaults.standard.integer(forKey: downloadLimitKey) }

    static var maxRunning: Int { let v = UserDefaults.standard.integer(forKey: maxRunningKey); return v > 0 ? v : 5 }
    static var preventSleep: Bool { UserDefaults.standard.object(forKey: preventSleepKey) as? Bool ?? true }
    static var notify: Bool { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }
}

/// 有任务在下时不让 Mac 因闲置睡眠（合盖、手动睡眠照常）；没在下就放开
@MainActor
final class SleepGuard {
    private var assertion: IOPMAssertionID = 0
    private var held = false

    func update(downloading: Bool) {
        let want = downloading && Prefs.preventSleep
        if want, !held {
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "闪电下载正在下载" as CFString, &assertion) == kIOReturnSuccess
        } else if !want, held {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: DownloadStore
    @AppStorage(Prefs.maxRunningKey) private var maxRunning = 5
    @AppStorage(Prefs.preventSleepKey) private var preventSleep = true
    @AppStorage(Prefs.notifyKey) private var notify = true
    @AppStorage(Prefs.downloadLimitKey) private var limit = 0
    @AppStorage(Prefs.autoThunderKey) private var autoThunder = false
    @AppStorage(Prefs.autoCloudKey) private var autoCloud = true
    @State private var pkState = PikPak.loggedInUser
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ClipboardWatcher.enabledKey) private var watchClipboard = true
    @AppStorage(NewTaskPanels.askKey) private var confirmNew = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var dirsVersion = 0   // 改了位置后刷新显示

    var body: some View {
        Form {
            Section("保存位置") {
                dirRow("磁力、种子", key: "dir.movie", current: Folders.movies)
                dirRow("视频网站", key: "dir.video", current: Folders.videos)
                dirRow("其他文件", key: "dir.other", current: Folders.others)
            }
            .id(dirsVersion)

            Section("下载") {
                Picker("同时下载", selection: $maxRunning) {
                    ForEach([1, 2, 3, 5, 8, 10], id: \.self) { Text("\($0) 个任务").tag($0) }
                }
                .onChange(of: maxRunning) { store.reapplyEngineSettings() }
                Picker("下载限速", selection: $limit) {
                    Text("不限速").tag(0)
                    ForEach([512, 1024, 2048, 5120, 10240], id: \.self) { kb in
                        Text(kb < 1024 ? "\(kb) KB/s" : "\(kb / 1024) MB/s").tag(kb)
                    }
                }
                .onChange(of: limit) { store.reapplyEngineSettings() }
                if ThunderBridge.installed {
                    Toggle("磁力、种子太慢时交给迅雷（没登录云盘时）", isOn: $autoThunder)
                        .help("连续 3 分钟几乎没速度时，用本机的迅雷接着下，进度仍显示在闪电下载里")
                }
                Toggle("新建任务时显示确认框", isOn: $confirmNew)
                Toggle("复制链接后弹出下载提示", isOn: $watchClipboard)
            }

            Section("云盘离线（PikPak）") {
                if let u = pkState {
                    LabeledContent("已登录") {
                        HStack { Text(u).foregroundStyle(Theme.sub); Button("退出") { Task { await PikPak.shared.logout(); pkState = nil } } }
                    }
                    Toggle("磁力、种子太慢时自动交给云盘离线", isOn: $autoCloud)
                        .help("BT 网络里几乎没人传的资源，交给 PikPak 服务器下好，再从云盘满速拉回")
                } else {
                    LabeledContent("PikPak 账号") {
                        HStack {
                            // 浏览器里登录着 PikPak：扩展把登录交给闪电下载，什么都不用输
                            // Chrome、Edge 都打开：哪个里登录着 PikPak 就从哪个关联（默认浏览器不一定是登录的那个）
                            Button("从浏览器关联") {
                                let u = URL(string: "https://mypikpak.com/drive/#shandian-link")!
                                for app in ["/Applications/Google Chrome.app", "/Applications/Microsoft Edge.app"] where FileManager.default.fileExists(atPath: app) {
                                    NSWorkspace.shared.open([u], withApplicationAt: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                                }
                            }
                                .buttonStyle(.borderedProminent)
                            Button("在窗口里登录…") { openWindow(id: "pikpak-login"); NSApp.activate(ignoringOtherApps: true) }
                        }
                    }
                    Text("浏览器里已登录 PikPak 时点「从浏览器关联」即可（需装好闪电下载扩展）；关联后浏览器里的 PikPak 网页会退出登录，因为同一份登录不能两边同时用。")
                        .font(.system(size: 12)).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("系统") {
                Toggle("下载时不让 Mac 进入睡眠", isOn: $preventSleep)
                    .help("只阻止闲置睡眠；合上盖子或手动睡眠照常")
                Toggle("下载完成时通知", isOn: $notify)
                Toggle("登录时自动打开闪电下载", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: PikPak.loginChanged)) { _ in pkState = PikPak.loggedInUser }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.tint)
    }

    private func dirRow(_ title: String, key: String, current: URL) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(Folders.displayName(current)).foregroundStyle(Theme.sub).lineLimit(1).truncationMode(.middle)
                    .help(current.path)
                Button("更改…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                    p.directoryURL = current; p.prompt = "选择"
                    if p.runModal() == .OK, let u = p.url { UserDefaults.standard.set(u.path, forKey: key); dirsVersion += 1 }
                }
                if UserDefaults.standard.string(forKey: key) != nil {
                    Button("恢复默认") { UserDefaults.standard.removeObject(forKey: key); dirsVersion += 1 }
                }
            }
        }
    }
}
