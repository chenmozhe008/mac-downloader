import AppKit
import SwiftUI

/// 「浏览器扩展」设置页：要装的扩展、在 Chrome / Edge 中打开商店页、复制网关地址和密钥。
/// 商店页面浏览器不允许自动化点击，「添加到浏览器」只能用户自己点。
struct BrowserSetupView: View {
    let token: String
    @State private var copied = ""

    private struct Ext: Identifiable {
        let id: String, name: String, purpose: String, chrome: String, edge: String
    }
    private let exts = [
        Ext(id: "gopeed", name: "Gopeed 扩展", purpose: "接管浏览器下载，右键「使用 Gopeed 下载」",
            chrome: "https://chromewebstore.google.com/detail/gopeed/mijpgljlfcapndmchhjffkpckknofcnd",
            edge: "https://microsoftedge.microsoft.com/addons/detail/dkajnckekendchdleoaenoophcobooce"),
        Ext(id: "tm", name: "篡改猴 Tampermonkey", purpose: "运行 LinkSwift 脚本",
            chrome: "https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo",
            edge: "https://microsoftedge.microsoft.com/addons/detail/iikmkjmpaadaobahmlepeloendndfphd"),
        Ext(id: "ls", name: "LinkSwift 脚本", purpose: "在网盘页面获取直链（装好篡改猴后再装）",
            chrome: "https://greasyfork.org/scripts/583582-linkswift",
            edge: "https://greasyfork.org/scripts/583582-linkswift"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("浏览器扩展").font(.system(size: 20, weight: .bold))
                Text("装好后，浏览器里的下载和网盘直链会交给闪电下载，按同样的规则保存。")
                    .font(.system(size: 13)).foregroundStyle(Theme.sub)
            }
            VStack(spacing: 10) {
                ForEach(Array(exts.enumerated()), id: \.element.id) { i, e in
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(Circle().fill(Theme.tint))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(.system(size: 14, weight: .semibold))
                            Text(e.purpose).font(.system(size: 12)).foregroundStyle(Theme.sub)
                        }
                        Spacer()
                        Button("Chrome") { open(e.chrome, app: "Google Chrome") }.controlSize(.small)
                        Button("Edge") { open(e.edge, app: "Microsoft Edge") }.controlSize(.small)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("连接设置").font(.system(size: 15, weight: .bold))
                field("服务器地址", "http://127.0.0.1:\(Gateway.port)")
                field("密钥 / Token", token, secret: true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Gopeed 扩展：设置 → 远程下载 → 开启，添加服务器，填入上面的地址和 Token。")
                    Text(verbatim: "LinkSwift：在网盘页面打开其设置 → Aria2 RPC，地址 http://127.0.0.1，端口 \(Gateway.port)，路径 /jsonrpc，密钥填 Token。")
                    Text("Chrome 中的篡改猴需在扩展详情页打开「允许用户脚本」。")
                }
                .font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(26)
        .frame(width: 560)
        .background(Theme.window)
        .tint(Theme.tint)
    }

    private func field(_ label: String, _ value: String, secret: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.sub).frame(width: 84, alignment: .leading)
            Text(secret ? String(repeating: "•", count: 16) : value)
                .font(.system(size: 12.5, design: .monospaced)).lineLimit(1)
            Spacer()
            Button(copied == value ? "已复制" : "复制") { AppInfo.copy(value); copied = value }.controlSize(.small)
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.faint))
    }

    private func open(_ url: String, app: String) {
        let appURL = URL(fileURLWithPath: "/Applications/\(app).app")
        NSWorkspace.shared.open([URL(string: url)!], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
