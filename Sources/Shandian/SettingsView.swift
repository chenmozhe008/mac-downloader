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
                Toggle("新建任务时显示确认框", isOn: $confirmNew)
                Toggle("复制链接后弹出下载提示", isOn: $watchClipboard)
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
