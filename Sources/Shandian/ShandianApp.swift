import AppKit
import SwiftUI

@main
struct ShandianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = DownloadStore()

    var body: some Scene {
        // 单个 Window：关掉窗口下载照常进行（菜单栏还在），点 Dock 图标或菜单栏「打开」叫回来
        Window("闪电下载", id: "main") {
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
        }

        Window("关于闪电下载", id: "about") {
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

private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("关于闪电下载") { openWindow(id: "about") } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: DownloadStore?

    private var keyMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 窗口里任何地方按 ⌘V 都能下载；焦点在输入框（搜索、新建下载）时照常粘贴文字
    func applicationDidFinishLaunching(_ notification: Notification) {
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

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { store?.shutdown() }
    }

    /// 磁力链接、.torrent 文件用本 App 打开时走这里
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for u in urls { store?.add(link: u.isFileURL ? u.path : u.absoluteString) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: DownloadStore
    var body: some View {
        let speed = store.totalSpeed
        if speed > 0 {
            Text("↓ " + speed.speedText).monospacedDigit()
        } else {
            Image(systemName: "bolt.fill")
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
        Button("打开闪电下载") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(store.allPaused ? "全部继续" : "全部暂停") { store.toggleAll() }.disabled(active.isEmpty)
        Divider()
        Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
