import AppKit
import SwiftUI
@preconcurrency import UserNotifications

@main
struct ShandianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = DownloadStore()

    var body: some Scene {
        // 单个 Window：关掉窗口下载照常进行（菜单栏还在），点 Dock 图标或菜单栏「打开」叫回来
        Window("闪电全能下载", id: "main") {
            MainView(store: store)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { delegate.store = store }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutMenuButton() }
            CommandGroup(replacing: .newItem) {
                Button("新建下载…") { store.showNewSheet = true }.keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .pasteboard) {
                Button("粘贴并下载") {
                    if let s = NSPasteboard.general.string(forType: .string) { store.add(text: s) }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appSettings) { BrowserMenuButton() }
        }

        Settings {
            SettingsView(store: store)
        }

        Window("浏览器扩展", id: "browser") {
            BrowserSetupView(token: store.engineToken)
        }
        .windowResizability(.contentSize)

        Window("登录 PikPak", id: "pikpak-login") {
            PikPakLoginWindow()
        }
        .windowResizability(.contentSize)

        Window("关于闪电全能下载", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
    }
}

/// 「监听剪贴板」开关（菜单栏「闪电全能下载」和状态栏菜单里都有）
struct ClipboardToggle: View {
    @AppStorage(ClipboardWatcher.enabledKey) private var on = true
    var body: some View { Toggle("复制链接后弹出下载提示", isOn: $on) }
}

struct BrowserMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("浏览器扩展…") { openWindow(id: "browser"); NSApp.activate(ignoringOtherApps: true) } }
}

private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("关于闪电全能下载") { AppInfo.showAbout(.intro, openWindow) }
        Button("更新记录") { AppInfo.showAbout(.changelog, openWindow) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var store: DownloadStore?

    private var keyMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 明确同意退出：不写这个时，脚本发来的「退出」（osascript quit）会被 SwiftUI 回成「用户已取消」，菜单退出不受影响（10-28 查到）
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }

    /// 窗口里任何地方按 ⌘V 都能下载；焦点在输入框（搜索、新建下载）时照常粘贴文字
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        DownloadStore.registerNotificationActions()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  !(event.window?.firstResponder is NSTextView),
                  event.window?.sheets.isEmpty ?? true,
                  let text = NSPasteboard.general.string(forType: .string) else { return event }
            MainActor.assumeIsolated { self?.store?.add(text: text) }
            return nil
        }
    }

    /// 完成通知：点「打开」打开文件，「在访达中显示」定位文件，点通知本身打开主窗口
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let path, FileManager.default.fileExists(atPath: path) else { NSApp.activate(ignoringOtherApps: true); return }
            let url = URL(fileURLWithPath: path)
            switch action {
            case "open": NSWorkspace.shared.open(url)
            case "reveal": NSWorkspace.shared.activateFileViewerSelecting([url])
            default: NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// App 在前台时也显示通知
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { store?.shutdown() }
    }

    /// 磁力链接、.torrent 文件用本 App 打开时走这里；
    /// 另有 shandian://add?url=<链接>（可多个 url，加 confirm=0 不弹确认框），给脚本、skill、书签用：`open -g "shandian://add?url=…"` 不抢焦点
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for u in urls {
                if u.scheme == "shandian" {
                    let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let links = items.filter { $0.name == "url" }.compactMap(\.value)
                    // confirm=0：脚本 / skill 批量投递，不弹确认框，按默认规则直接下
                    if items.contains(where: { $0.name == "confirm" && $0.value == "0" }) {
                        links.forEach { store?.start(link: $0) }
                    } else {
                        store?.request(links)
                    }
                } else {
                    store?.add(link: u.isFileURL ? u.path : u.absoluteString)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: DownloadStore
    var body: some View {
        // 图标常在；有速度时跟在图标右边
        let speed = store.totalSpeed
        HStack(spacing: 4) {
            Image(nsImage: BrandGlyph.image(height: 18))  // 15 点太细（10-29 用户：跟闪电说并排显得虚）
            if speed > 0 { Text(speed.speedText).monospacedDigit() }
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var store: DownloadStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let active = store.items.filter(\.isActive)
        if active.isEmpty { Text("没有进行中的下载") }
        ForEach(active.prefix(6)) { i in
            Text("\(i.title)　\(Int(i.progress * 100))%")
        }
        Divider()
        Button("打开闪电全能下载") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(store.allPaused ? "全部继续" : "全部暂停") { store.toggleAll() }.disabled(active.isEmpty)
        Divider()
        ClipboardToggle()
        BrowserMenuButton()
        Divider()
        Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
