import AppKit
import SwiftUI

/// 自带浏览器扩展（仓库 `browser-extension/`）。打包进 App，启动时拷到 Application Support：
/// 浏览器记的是「已解压扩展」所在路径，放在 App 包里每次重新打包都会变。
/// Chrome / Edge 不允许第三方程序静默安装扩展，只能用户在扩展页打开开发者模式、把文件夹拖进去，一次就好。
enum BrowserExtension {
    static let folder = EngineConfig.supportDir.appendingPathComponent("BrowserExtension")

    static func install() {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension") else { return }
        let fm = FileManager.default
        let old = try? Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        let new = try? Data(contentsOf: src.appendingPathComponent("manifest.json"))
        let oldJS = try? Data(contentsOf: folder.appendingPathComponent("background.js"))
        let newJS = try? Data(contentsOf: src.appendingPathComponent("background.js"))
        guard new != nil, old != new || oldJS != newJS else { return }
        // 逐个文件覆盖，不删整个目录：浏览器正开着这个扩展
        for f in (try? fm.subpathsOfDirectory(atPath: src.path)) ?? [] {
            let s = src.appendingPathComponent(f), d = folder.appendingPathComponent(f)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: s.path, isDirectory: &isDir)
            if isDir.boolValue { try? fm.createDirectory(at: d, withIntermediateDirectories: true); continue }
            try? fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: d)
            try? fm.copyItem(at: s, to: d)
        }
    }

    /// 扩展连上过 App 的浏览器（Chrome / Edge），设置页据此显示「已连接」
    @MainActor static func markConnected(_ browser: String) {
        var seen = Set(UserDefaults.standard.stringArray(forKey: "extensionSeen") ?? [])
        if seen.insert(browser).inserted { UserDefaults.standard.set(Array(seen).sorted(), forKey: "extensionSeen") }
    }
}

/// 「浏览器扩展」设置页
struct BrowserSetupView: View {
    let token: String
    @State private var seen: [String] = []
    @State private var copied = ""
    @State private var showPan = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("浏览器扩展").font(.system(size: 20, weight: .bold))
                Text("装好后，在浏览器里点下载会直接交给闪电下载；右键链接可选「用闪电下载」。闪电下载没打开时，浏览器照常下载。")
                    .font(.system(size: 13)).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                step(1, "打开扩展管理页", "在要用的浏览器里打开") {
                    Button("Chrome") { openPage("chrome://extensions", app: "Google Chrome") }.controlSize(.small)
                    Button("Edge") { openPage("edge://extensions", app: "Microsoft Edge") }.controlSize(.small)
                }
                step(2, "打开「开发者模式」", "Chrome 在页面右上角，Edge 在左侧栏") { EmptyView() }
                step(3, "把扩展文件夹拖进页面", "拖进去即安装完成，以后自动更新") {
                    Button("显示文件夹") { BrowserExtension.install(); NSWorkspace.shared.activateFileViewerSelecting([BrowserExtension.folder]) }
                        .controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: seen.isEmpty ? "circle.dashed" : "checkmark.circle.fill")
                    .foregroundStyle(seen.isEmpty ? Theme.sub : Color.green)
                Text(seen.isEmpty ? "尚未连接。装好后此处会显示已连接的浏览器。" : "已连接：" + seen.joined(separator: "、"))
                    .font(.system(size: 13)).foregroundStyle(seen.isEmpty ? Theme.sub : Theme.text)
            }
            DisclosureGroup(isExpanded: $showPan) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("百度网盘等需要在网页里先取得直链。可另装篡改猴和 LinkSwift 脚本，把直链推送给闪电下载。")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("篡改猴（Chrome）") { open("https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo", app: "Google Chrome") }
                        Button("篡改猴（Edge）") { open("https://microsoftedge.microsoft.com/addons/detail/iikmkjmpaadaobahmlepeloendndfphd", app: "Microsoft Edge") }
                        Button("LinkSwift 脚本") { NSWorkspace.shared.open(URL(string: "https://greasyfork.org/scripts/583582-linkswift")!) }
                    }
                    .controlSize(.small)
                    Text(verbatim: "LinkSwift 设置 → Aria2 RPC：地址 http://127.0.0.1，端口 \(Gateway.port)，路径 /jsonrpc，密钥填下面的 Token。")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    field("密钥 / Token", token)
                }
                .padding(.top, 8)
            } label: {
                Text("网盘直链（可选）").font(.system(size: 14, weight: .semibold))
            }
        }
        .padding(26)
        .frame(width: 560)
        .background(Theme.window)
        .tint(Theme.tint)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in reload() }
    }

    private func reload() { seen = UserDefaults.standard.stringArray(forKey: "extensionSeen") ?? [] }

    private func step<Trailing: View>(_ n: Int, _ title: String, _ detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(Theme.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.sub)
            }
            Spacer()
            trailing()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.sub).frame(width: 84, alignment: .leading)
            Text(String(repeating: "•", count: 16)).font(.system(size: 12.5, design: .monospaced)).lineLimit(1)
            Spacer()
            Button(copied == value ? "已复制" : "复制") { AppInfo.copy(value); copied = value }.controlSize(.small)
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.faint))
    }

    /// chrome:// / edge:// 页面不能当普通网址打开，用 AppleScript 让浏览器自己开新标签
    private func openPage(_ url: String, app: String) {
        let src = "tell application \"\(app)\" to open location \"\(url)\"\ntell application \"\(app)\" to activate"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    private func open(_ url: String, app: String) {
        let appURL = URL(fileURLWithPath: "/Applications/\(app).app")
        NSWorkspace.shared.open([URL(string: url)!], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
