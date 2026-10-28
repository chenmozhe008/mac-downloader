import AppKit
import SwiftUI

/// 「关于闪电下载」：介绍 / 更新记录 / 反馈。结构沿用小清。
/// 介绍里只写功能事实和本机实测；不写竞品对比数字（单次测试不能当结论，10-27 用户指出）
enum AppInfo {
    static let author = "@沉默者之二"
    static let feedbackEmail = "327529709@qq.com"

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-" }

    /// 附在反馈邮件里，便于复现
    static var diagnostics: String {
        "闪电下载 \(version)（\(build)），macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// 打开「关于」并停在指定页
    @MainActor static func showAbout(_ tab: AboutTab, _ openWindow: OpenWindowAction) {
        AboutState.shared.tab = tab
        openWindow(id: "about")
        NSApp.activate(ignoringOtherApps: true)
    }

    static func sendFeedback() {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = feedbackEmail
        c.queryItems = [URLQueryItem(name: "subject", value: "闪电下载反馈 v\(version)"),
                        URLQueryItem(name: "body", value: "\n\n（请在此描述遇到的问题，并附上截图）\n\(diagnostics)")]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum AboutTab: String, CaseIterable { case intro = "介绍", changelog = "更新记录", feedback = "反馈" }

/// 窗口开着时从菜单、侧栏切页也要生效，所以用共享对象（@AppStorage 不会响应）
final class AboutState: ObservableObject {
    @MainActor static let shared = AboutState()
    @Published var tab: AboutTab = .intro
}

struct AboutView: View {
    @ObservedObject private var state = AboutState.shared

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Picker("", selection: $state.tab) {
                ForEach(AboutTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 270).padding(.vertical, 16)
            ScrollView {
                switch state.tab {
                case .intro: IntroPage()
                case .changelog: ChangelogPage()
                case .feedback: FeedbackPage()
                }
            }
        }
        .frame(width: 680, height: 720)
        .background(Theme.window)
        .tint(Theme.tint)
    }
}

/// 琥珀渐变标题区：图标、名字、一句话定位、版本与作者
private struct Header: View {
    var body: some View {
        HStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 5) {
                Text("闪电下载").font(.system(size: 26, weight: .bold))
                Text("磁力、种子、网盘与视频网站，一个窗口下载").font(.system(size: 14, weight: .medium))
                Text("版本 \(AppInfo.version)（\(AppInfo.build)）　作者 \(AppInfo.author)")
                    .font(.system(size: 12)).opacity(0.75).monospacedDigit().padding(.top, 2)
            }
            .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 28).padding(.top, 44).padding(.bottom, 24)
        .background(
            LinearGradient(colors: [Color(red: 1.0, green: 0.72, blue: 0.20), Color(red: 0.93, green: 0.48, blue: 0.0)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(RadialGradient(colors: [.white.opacity(0.25), .clear], center: .topTrailing, startRadius: 0, endRadius: 320))
        )
    }
}

/// 分区小标题：琥珀色竖条 + 标题
private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(Theme.tint).frame(width: 4, height: 16)
            Text(text).font(.system(size: 15, weight: .bold))
        }
    }
}

/// 白底卡片（深色模式下是略亮的灰），带细边和轻阴影
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }
}

/// 琥珀渐变图标块
private struct IconTile: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.74, blue: 0.25), Color(red: 0.94, green: 0.52, blue: 0.0)],
                                     startPoint: .top, endPoint: .bottom)))
    }
}

private struct IntroPage: View {
    private let points: [(String, String, String)] = [
        ("globe", "海外资源可连接", "下载经本机代理连接，可访问海外的 Tracker 和下载服务器。"),
        ("bolt.fill", "磁力更快找到来源", "启动时更新公共 Tracker 列表，使用固定监听端口，连接更多来源。"),
        ("film.stack", "只下载需要的文件", "种子只选正片和字幕，跳过样片、海报；同一影片多种格式只下一个。"),
        ("play.rectangle.fill", "视频网站最高画质", "默认最高分辨率，优先 H.264，可直接导入剪辑软件；可选字幕和仅音频。"),
        ("photo.on.rectangle", "影片一目了然", "自动整理影片名称，显示影片画面或视频封面。"),
        ("checkmark.seal.fill", "无广告，无需账号", "下载核心为开源项目 Gopeed 和 yt-dlp，视频网站组件每周自动更新。"),
    ]
    private let sources = ["磁力", "种子", "ed2k", "HTTP 直链", "网盘直链", "B 站", "YouTube", "X", "微博"]
    private let notes: [(String, String)] = [
        ("doc.on.clipboard", "复制链接后在窗口中按 ⌘V 即可下载，也可拖入链接或种子文件；装好浏览器扩展后，网页上点下载会直接交给闪电下载。"),
        ("externaldrive", "电影默认存到移动硬盘；硬盘未连接时暂存到「下载 › 电影」。推出硬盘前会自动暂停存在上面的任务。"),
        ("play.tv", "下载中的电影可「边下边播」：先下片头，用 IINA 或 VLC 打开。"),
        ("cloud", "网盘下载需先在浏览器中获取直链，速度受网盘自身限速影响。"),
        ("gauge.with.dots.needle.33percent", "下载速度取决于资源热度、来源数量和网络环境。"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("它是什么")
                Text("闪电下载是一款 Mac 下载工具。磁力链接、种子文件、ed2k、HTTP 直链、网盘直链，以及 B 站、YouTube 等视频网站的内容，都在同一个窗口下载。链接类型自动识别，文件按类型保存到不同位置；关闭窗口后下载继续，菜单栏显示当前速度。")
                    .font(.system(size: 13.5)).foregroundStyle(Theme.text).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("核心优势")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(points, id: \.1) { p in
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                IconTile(symbol: p.0)
                                Text(p.1).font(.system(size: 14, weight: .bold))
                                Text(p.2).font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.72)).lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("支持的来源")
                FlowChips(items: sources)
                Text("抖音暂不支持（网页版视频加密，开源工具目前都下不了）；小红书在浏览器登录后，用扩展「下载这个视频」。").font(.system(size: 12.5)).foregroundStyle(Theme.sub)
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("使用说明")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(notes, id: \.1) { n in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: n.0).font(.system(size: 13)).foregroundStyle(Theme.tint).frame(width: 18)
                            Text(n.1).font(.system(size: 13)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 28)
    }
}

/// 一行排不下自动换行的标签
private struct FlowChips: View {
    let items: [String]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { s in
                Text(s).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.tint)
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .background(Capsule().fill(Theme.tint.opacity(0.12)))
            }
        }
    }
}

private struct Bullet: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Theme.tint).frame(width: 5, height: 5).offset(y: -2)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ChangelogPage: View {
    private struct Release: Identifiable { var id: String; var notes: [String] }

    /// 解析 App 里的 CHANGELOG.md（「## 版本 · 日期」标题、「- 」条目），唯一的版本记录来源
    private var releases: [Release] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [Release] = []
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("## ") { out.append(Release(id: String(line.dropFirst(3)), notes: [])) }
            else if line.hasPrefix("- "), !out.isEmpty { out[out.count - 1].notes.append(String(line.dropFirst(2))) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(releases.enumerated()), id: \.element.id) { i, r in
                let parts = r.id.components(separatedBy: " · ")
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("v" + (parts.first ?? r.id)).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).frame(height: 24)
                                .background(Capsule().fill(Theme.tint))
                            if i == 0 {
                                Text("最新").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.tint)
                                    .padding(.horizontal, 8).frame(height: 22)
                                    .background(Capsule().strokeBorder(Theme.tint, lineWidth: 1))
                            }
                            Spacer()
                            if parts.count > 1 { Text(parts[1]).font(.system(size: 12)).foregroundStyle(Theme.sub).monospacedDigit() }
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(r.notes, id: \.self) { Bullet(text: $0) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28).padding(.bottom, 28)
    }
}

private struct FeedbackPage: View {
    @State private var copied = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("使用中遇到问题，欢迎反馈").font(.system(size: 17, weight: .bold))
                    Text("请描述问题并附上截图，便于定位。").font(.system(size: 13)).foregroundStyle(Theme.sub)
                    HStack(spacing: 10) {
                        Button { AppInfo.sendFeedback() } label: { Label("发反馈邮件", systemImage: "envelope.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Button { AppInfo.copy(AppInfo.feedbackEmail); copied = AppInfo.feedbackEmail } label: {
                            Label(copied == AppInfo.feedbackEmail ? "已复制邮箱" : AppInfo.feedbackEmail,
                                  systemImage: copied == AppInfo.feedbackEmail ? "checkmark" : "doc.on.doc")
                        }
                        .controlSize(.large)
                    }
                    .padding(.top, 6)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("反馈时请尽量包括").font(.system(size: 14, weight: .semibold))
                Bullet(text: "出现问题的链接，或链接类型（磁力、视频网站等）")
                Bullet(text: "任务行显示的状态或失败原因")
                Bullet(text: "版本信息（「发反馈邮件」会自动附上，也可在下方复制）")
            }
            HStack {
                Text(AppInfo.diagnostics).font(.system(size: 12)).foregroundStyle(Theme.sub).textSelection(.enabled)
                Spacer()
                Button(copied == AppInfo.diagnostics ? "已复制" : "复制") { AppInfo.copy(AppInfo.diagnostics); copied = AppInfo.diagnostics }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 26)
    }
}
