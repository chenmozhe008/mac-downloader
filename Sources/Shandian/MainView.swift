import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var store: DownloadStore

    var body: some View {
        // 系统原生分栏：侧栏玻璃、红绿灯位置、工具栏都由系统排，和访达一致
        NavigationSplitView {
            Sidebar(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Content(store: store)
                .background(Theme.window)
                .navigationTitle(store.section.title)
                .toolbar { ToolbarItems(store: store) }
                .searchable(text: $store.search, placement: .toolbar, prompt: "搜索")
        }
        .tint(Theme.tint)
        .onDrop(of: [.fileURL, .url, .text], isTargeted: nil) { providers in
            for p in providers {
                if p.canLoadObject(ofClass: URL.self) {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        let s = url.isFileURL ? url.path : url.absoluteString
                        Task { @MainActor in store.add(link: s) }
                    }
                } else {
                    _ = p.loadObject(ofClass: String.self) { text, _ in  // 拖进来一段文字，里面可能有多个链接
                        guard let text else { return }
                        Task { @MainActor in store.add(text: text) }
                    }
                }
            }
            return true
        }
        .sheet(isPresented: $store.showNewSheet) { NewDownloadSheet(store: store) }
    }
}

// MARK: - 侧栏

private struct Sidebar: View {
    @ObservedObject var store: DownloadStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        List(selection: $store.section) {
            row(.active, "bolt")
            row(.done, "checkmark.circle")
            Section("资料库") {
                ForEach(Category.allCases) { c in row(.category(c), c.symbol) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { brand }
        .safeAreaInset(edge: .bottom) { diskStatus }
    }

    /// 侧栏顶部：App 图标 + 名字，点击打开「关于」
    private var brand: some View {
        Button { openWindow(id: "about") } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
                Text("闪电下载").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("关于闪电下载")
        .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 6)
    }

    private func row(_ p: Pane, _ symbol: String) -> some View {
        let n = store.count(p)
        return Label(p.title, systemImage: symbol)
            .badge(n > 0 ? Text("\(n)").monospacedDigit() : nil)
            .tag(p)
    }

    @ViewBuilder private var diskStatus: some View {
        switch store.engineState {
        case .missingDisk:
            Label("移动硬盘未连接", systemImage: "externaldrive.badge.exclamationmark")
                .font(.system(size: 12)).foregroundStyle(Theme.sub)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 12)
        case .failed(let m):
            Label("内核未启动：\(m)", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(Theme.sub)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 12)
        default:
            EmptyView()
        }
    }
}

// MARK: - 右侧内容

private struct Content: View {
    @ObservedObject var store: DownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Banners(store: store)
            switch store.section {
            case .active: ActivePage(store: store)
            case .done: DonePage(store: store, items: store.doneItems).padding(.top, 8)
            case .category(let c): CategoryPage(store: store, category: c)
            }
        }
        .padding(.horizontal, 24).padding(.top, 8)
    }
}

private struct ToolbarItems: ToolbarContent {
    @ObservedObject var store: DownloadStore
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.toggleAll() } label: {
                Label(store.allPaused ? "全部继续" : "全部暂停", systemImage: store.allPaused ? "play.fill" : "pause.fill")
            }
            .help(store.allPaused ? "全部继续" : "全部暂停")
            .disabled(store.items.filter(\.isActive).isEmpty)
            Button { store.showNewSheet = true } label: { Label("新建下载", systemImage: "plus") }
                .help("新建下载（⌘N）")
        }
    }
}

/// 剪贴板发现链接、重复提醒、失败原因：一行，可关闭
private struct Banners: View {
    @ObservedObject var store: DownloadStore
    var body: some View {
        VStack(spacing: 8) {
            if let link = store.clipboardLink {
                bar(icon: "doc.on.clipboard", text: "剪贴板中有链接：" + DownloadStore.displayName(link)) {
                    Button("下载") { store.acceptClipboard() }.buttonStyle(.borderedProminent).tint(Theme.tint).controlSize(.small)
                    Button("忽略") { store.clipboardLink = nil }.buttonStyle(.plain).foregroundStyle(Theme.sub).font(.system(size: 12))
                }
            }
            if let n = store.notice {
                bar(icon: "info.circle", text: n) {
                    Button { store.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.sub)
                }
            }
        }
        .padding(.bottom, store.clipboardLink == nil && store.notice == nil ? 0 : 10)
    }
    private func bar<A: View>(icon: String, text: String, @ViewBuilder actions: () -> A) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.tint)
            Text(text).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
            Spacer()
            actions()
        }
        .padding(.horizontal, 14).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.faint))
    }
}

// MARK: - 正在下载

private struct ActivePage: View {
    @ObservedObject var store: DownloadStore
    var body: some View {
        let items = store.activeItems
        VStack(alignment: .leading, spacing: 0) {
            SpeedHero(store: store).frame(height: 118).padding(.bottom, 12)
            if items.isEmpty {
                EmptyState(store: store)
            } else {
                Text(items.allSatisfy(\.isFailed) ? "未完成" : "进行中").font(.system(size: 13, weight: .semibold)).padding(.bottom, 6)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { TaskRow(store: store, item: $0) }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }
}

private struct SpeedHero: View {
    @ObservedObject var store: DownloadStore
    var body: some View {
        let speed = store.totalSpeed
        let parts = speed.speedText.split(separator: " ")
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Text("当前速度").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.sub)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.first.map(String.init) ?? "0").font(.system(size: 46, weight: .semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(parts.dropFirst().joined(separator: " ")).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.sub)
                }
                .padding(.top, 2)
                HStack(spacing: 14) {
                    let failed = store.activeItems.filter(\.isFailed).count
                    let n = store.activeItems.count - failed
                    Text(n == 0 ? "没有进行中的下载" : "\(n) 项进行中")
                    if failed > 0 { Text("\(failed) 项失败") }
                    let eta = remainingText(store.etaAll).replacingOccurrences(of: "剩 ", with: "")
                    if n > 0, !eta.isEmpty { Text("约 \(eta)全部完成") }
                }
                .font(.system(size: 12)).foregroundStyle(Theme.sub).padding(.top, 8)
            }
            .fixedSize()
            SpeedChart(values: store.speedHistory).frame(maxWidth: 560).padding(.bottom, 6)
                .opacity(store.speedHistory.contains { $0 > 0 } ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 最近 60 秒的速度曲线，越往右越新；左侧淡出
private struct SpeedChart: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = max(values.max() ?? 0, 1_048_576) * 1.25
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: w * CGFloat(i) / CGFloat(max(values.count - 1, 1)), y: h - 4 - CGFloat(v / maxV) * (h - 10))
            }
            let line = Path { p in
                guard let first = pts.first else { return }
                p.move(to: first)
                for i in 1..<pts.count {
                    let a = pts[i - 1], b = pts[i], mx = (a.x + b.x) / 2
                    p.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
                }
            }
            ZStack {
                Path { p in p.addPath(line); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath() }
                    .fill(LinearGradient(colors: [Theme.tint.opacity(0.28), Theme.tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                line.stroke(Theme.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                if let last = pts.last { Circle().fill(Theme.tint).frame(width: 8, height: 8).position(x: last.x - 3, y: last.y) }
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)], startPoint: .leading, endPoint: .trailing))
            .animation(.easeOut(duration: 0.8), value: values)
        }
    }
}

private struct EmptyState: View {
    @ObservedObject var store: DownloadStore
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.circle").font(.system(size: 44, weight: .thin)).foregroundStyle(Theme.tint)
            Text("复制链接后按 ⌘V，即可开始下载").font(.system(size: 15, weight: .medium))
            VStack(spacing: 4) {
                Text("支持磁力、种子文件、ed2k、网盘直链")
                Text("以及 B 站、YouTube 等视频网站")
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.sub)
            Button("新建下载") { store.showNewSheet = true }
                .buttonStyle(.borderedProminent).tint(Theme.tint).controlSize(.large).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 80)
    }
}

// MARK: - 任务行

private struct Thumb: View {
    @ObservedObject var thumbs: Thumbnails
    let item: Item
    var width: CGFloat = 112
    var body: some View {
        let h = width * 9 / 16
        ZStack {
            if let img = thumbs.image(for: item.id) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.faint
                Image(systemName: item.category.symbol).font(.system(size: width / 6, weight: .light)).foregroundStyle(Theme.sub)
            }
        }
        .frame(width: width, height: h)
        .clipShape(RoundedRectangle(cornerRadius: width > 150 ? 10 : 8, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
    }
}

struct TaskRow: View {
    @ObservedObject var store: DownloadStore
    let item: Item
    @StateObject private var hover = HoverBox()

    var body: some View {
        HStack(spacing: 16) {
            Thumb(thumbs: store.thumbs, item: item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle).help(item.rawTitle)
                HStack(spacing: 12) {
                    Text(item.origin)
                    Text(sizeText)
                    if case .failed(let m) = item.status { Text(m).foregroundStyle(Theme.failed) }
                }
                .font(.system(size: 12)).foregroundStyle(Theme.sub).lineLimit(1)
                ProgressBar(value: item.progress, dim: item.status == .paused || item.isResolving)
                    .padding(.top, 7)
            }
            VStack(alignment: .trailing, spacing: 3) {
                Text(primary).font(.system(size: 14, weight: .medium)).monospacedDigit()
                Text(secondary).font(.system(size: 12)).foregroundStyle(Theme.sub).monospacedDigit()
            }
            .frame(width: 120, alignment: .trailing)
            HStack(spacing: 4) {
                if case .engine = item.source {
                    CircleIconButton(symbol: item.status == .paused || item.isFailed ? "play.fill" : "pause.fill",
                                     help: item.status == .paused ? "继续" : "暂停") { store.togglePause(item) }
                } else if item.isFailed {
                    CircleIconButton(symbol: "arrow.clockwise", help: "重试") { store.retry(item) }
                }
                CircleIconButton(symbol: "xmark", help: "移除") { store.remove(item, moveFiles: false) }
            }
            .frame(width: 64, alignment: .trailing)
            .opacity(hover.on ? 1 : 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture(count: 2) { store.reveal(item) }
        .contextMenu { ItemMenu(store: store, item: item) }
    }

    private var sizeText: String {
        if item.total == 0 { return "" }
        return item.downloaded >= item.total ? item.total.bytesText : "\(item.downloaded.bytesText) / \(item.total.bytesText)"
    }
    private var primary: String {
        switch item.status {
        case .running: item.speed.speedText
        case .paused: "已暂停"
        case .waiting: "排队中"
        case .resolving: "正在解析"
        case .failed: "失败"
        case .done: "已完成"
        }
    }
    private var secondary: String {
        switch item.status {
        case .running: item.speed > 0 ? remainingText(Double(item.total - item.downloaded) / Double(item.speed)) : "正在连接"
        case .resolving(let since):
            Date().timeIntervalSince(since) > 180 ? "资源较冷门，仍在尝试" : "正在寻找资源"
        case .paused, .waiting: item.total > 0 ? "\(Int(item.progress * 100))%" : ""
        default: ""
        }
    }
}

private extension Item {
    var isResolving: Bool { if case .resolving = status { return true }; return false }
    var isFailed: Bool { if case .failed = status { return true }; return false }
}

private struct ProgressBar: View {
    let value: Double
    let dim: Bool
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(dim ? Theme.sub : Theme.tint).frame(width: max(0, g.size.width * value))
                    .animation(.easeOut(duration: 0.6), value: value)
            }
        }
        .frame(height: 4)
    }
}

private struct ItemMenu: View {
    @ObservedObject var store: DownloadStore
    let item: Item
    var body: some View {
        if !item.isActive { Button("打开") { store.open(item) } }
        Button("在访达中显示") { store.reveal(item) }
        if case .engine = item.source, item.isActive {
            Button(item.status == .paused ? "继续" : "暂停") { store.togglePause(item) }
        }
        Divider()
        Button("移除任务") { store.remove(item, moveFiles: false) }
        Button("移除任务并将文件移到废纸篓") { store.remove(item, moveFiles: true) }
    }
}

// MARK: - 已完成 / 分类

private struct DonePage: View {
    @ObservedObject var store: DownloadStore
    let items: [Item]
    var subtitle: String?       // 分类页里「已完成」小标题；页面标题在窗口工具栏
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let subtitle { Text(subtitle).font(.system(size: 13, weight: .semibold)).padding(.bottom, 10) }
            if items.isEmpty {
                Text("暂无").font(.system(size: 13)).foregroundStyle(Theme.sub)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 80)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 196, maximum: 240), spacing: 18, alignment: .top)], spacing: 22) {
                        ForEach(items) { DoneCard(store: store, item: $0) }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

private struct DoneCard: View {
    @ObservedObject var store: DownloadStore
    let item: Item
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { g in Thumb(thumbs: store.thumbs, item: item, width: g.size.width) }
                .aspectRatio(16 / 9, contentMode: .fit)
            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle).padding(.top, 8).help(item.rawTitle)
            HStack(spacing: 10) {
                Text(item.total.bytesText)
                Text(item.origin)
            }
            .font(.system(size: 12)).foregroundStyle(Theme.sub).padding(.top, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.open(item) }
        .contextMenu { ItemMenu(store: store, item: item) }
        .help("双击打开")
    }
}

/// 分类页：进行中的用任务行，下完的用画面卡片
private struct CategoryPage: View {
    @ObservedObject var store: DownloadStore
    let category: Category
    var body: some View {
        let all = store.items(in: category)
        let active = all.filter(\.isActive)
        VStack(alignment: .leading, spacing: 0) {
            if !active.isEmpty {
                Text("进行中").font(.system(size: 13, weight: .semibold)).padding(.bottom, 6)
                ForEach(active) { TaskRow(store: store, item: $0) }
                Spacer().frame(height: 20)
                DonePage(store: store, items: all.filter { !$0.isActive }, subtitle: "已完成")
            } else {
                DonePage(store: store, items: all).padding(.top, 8)
            }
        }
    }
}

// MARK: - 新建下载

private struct NewDownloadSheet: View {
    @ObservedObject var store: DownloadStore
    var body: some View {
        let links = LinkKind.extract(from: store.newLinksText)
        VStack(alignment: .leading, spacing: 14) {
            Text("新建下载").font(.system(size: 15, weight: .semibold))
            TextEditor(text: $store.newLinksText)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.faint))
                .overlay(alignment: .topLeading) {
                    if store.newLinksText.isEmpty {
                        Text("粘贴磁力、网盘直链或视频网页链接，一行一个").font(.system(size: 12.5)).foregroundStyle(Theme.sub)
                            .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(links.prefix(5), id: \.self) { l in
                        let kind = LinkKind.of(l)
                        HStack(spacing: 8) {
                            Text(label(kind)).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.sub).frame(width: 64, alignment: .leading)
                            Text(DownloadStore.displayName(l)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("存到 " + folderName(kind)).font(.system(size: 11)).foregroundStyle(Theme.sub)
                        }
                    }
                    if links.count > 5 { Text("等 \(links.count) 个链接").font(.system(size: 11)).foregroundStyle(Theme.sub) }
                }
            }
            HStack {
                Spacer()
                Button("取消") { store.showNewSheet = false }.keyboardShortcut(.cancelAction)
                Button(links.count > 1 ? "下载 \(links.count) 项" : "下载") { store.submitNewSheet() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.tint)
                    .disabled(links.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if store.newLinksText.isEmpty, let s = NSPasteboard.general.string(forType: .string), !LinkKind.extract(from: s).isEmpty {
                store.newLinksText = s
            }
        }
    }
    private func label(_ k: LinkKind?) -> String {
        switch k {
        case .magnet: "磁力"
        case .torrentFile: "种子文件"
        case .ed2k: "ed2k"
        case .videoSite: "视频网站"
        case .http: "直链"
        case nil: "无法识别"
        }
    }
    private func folderName(_ k: LinkKind?) -> String {
        guard let k else { return "—" }
        let d = Folders.directory(for: k)
        if d == Folders.movies { return "移动硬盘 › movies" }
        if d == Folders.downloads { return "下载" }
        return "下载 › " + d.lastPathComponent
    }
}
