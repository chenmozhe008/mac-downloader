import AppKit
import SwiftUI

/// 「关于闪电下载」：介绍（优势）/ 更新记录。更新记录直接读 App 里的 CHANGELOG.md
struct AboutView: View {
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 80, height: 80)
                Text("闪电下载").font(.system(size: 22, weight: .bold))
                Text(AppInfo.versionText).font(.system(size: 12)).foregroundStyle(Theme.sub).monospacedDigit()
            }
            .padding(.top, 28).padding(.bottom, 16)
            Picker("", selection: $tab) {
                Text("介绍").tag(0)
                Text("更新记录").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200).padding(.bottom, 14)
            ScrollView {
                if tab == 0 { IntroPage() } else { ChangelogPage() }
            }
        }
        .frame(width: 520, height: 600)
        .background(Theme.window)
        .tint(Theme.tint)
    }
}

enum AppInfo {
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "—"
        let b = info["CFBundleVersion"] as? String ?? "—"
        return "版本 \(v)（\(b)）"
    }
}

private struct IntroPage: View {
    private let points: [(String, String, String)] = [
        ("globe", "海外资源更快", "下载经本机代理连接海外资源。同一海外种子实测 8–10 MB/s，迅雷为 0。"),
        ("bolt", "磁力起速快", "自动补全 tracker、固定监听端口。实测磁力链接 5 秒开始下载，迅雷为 64 秒。"),
        ("square.stack", "一个窗口，全部渠道", "磁力、种子、ed2k、直链、网盘直链，以及 B 站、YouTube、微博等视频网站。"),
        ("film", "只下需要的文件", "种子自动选择正片和字幕，跳过样片和广告文件。影片名称自动整理，显示影片画面。"),
        ("checkmark.seal", "无广告，无会员", "下载核心为开源项目 Gopeed 与 yt-dlp。视频网站组件每周自动更新。"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(points, id: \.1) { p in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: p.0).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.tint).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.1).font(.system(size: 14, weight: .semibold))
                        Text(p.2).font(.system(size: 13)).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.faint))
            }
            Text("测速数据为 2026 年 10 月公开片源实测，结果因资源和网络而异。")
                .font(.system(size: 12)).foregroundStyle(Theme.sub).padding(.top, 4)
        }
        .padding(.horizontal, 28).padding(.bottom, 24)
    }
}

private struct ChangelogPage: View {
    private struct Release: Identifiable { var id: String; var notes: [String] }

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
        VStack(alignment: .leading, spacing: 22) {
            ForEach(releases) { r in
                VStack(alignment: .leading, spacing: 7) {
                    Text(r.id).font(.system(size: 14, weight: .semibold))
                    ForEach(r.notes, id: \.self) { n in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Theme.sub).frame(width: 4, height: 4).offset(y: -3)
                            Text(n).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28).padding(.bottom, 24)
    }
}
