import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var store: DownloadStore

    var body: some View {
        // 系统原生分栏：侧栏玻璃、红绿灯位置、工具栏都由系统排，和访达一致
        NavigationSplitView {
            Sidebar(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 260)
        } detail: {
            Content(store: store)
                .background {
                    // 左上角一点琥珀暖光（v3 定稿的辨识点，换成原生分栏后补回）
                    ZStack {
                        Theme.window
                        RadialGradient(colors: [Theme.glow, .clear], center: .topLeading, startRadius: 0, endRadius: 620)
                    }
                    .ignoresSafeArea()
                }
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
        // 移除一律先确认，默认只移除任务、文件保留
        .alert(store.removalTarget.map { "移除「\($0.title)」？" } ?? "",
               isPresented: Binding(get: { store.removalTarget != nil }, set: { if !$0 { store.removalTarget = nil } }),
               presenting: store.removalTarget) { item in
            Button("移除任务") { store.remove(item, moveFiles: false) }
            Button("移除并将文件移到废纸篓", role: .destructive) { store.remove(item, moveFiles: true) }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text(item.isActive ? "下载将停止。选择「移除任务」时，已下载的部分保留在原位置。" : "选择「移除任务」时，文件保留在原位置。")
        }
    }
}

// MARK: - 侧栏

private struct Sidebar: View {
    @ObservedObject var store: DownloadStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        List(selection: $store.section) {
            row(.active, Image(systemName: "arrow.down.circle"))  // 闪电箭头只用在品牌位（App 图标、侧栏顶部、菜单栏），这里和其它行一样用线条图标
            row(.done, Image(systemName: "checkmark.circle"))
            Section("资料库") {
                ForEach(Category.allCases) { c in row(.category(c), Image(systemName: c.symbol)) }
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .large)
        .safeAreaInset(edge: .top, spacing: 0) { brand }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                diskStatus
                versionRow
            }
            .padding(.bottom, 12)
        }

    }

    /// 侧栏顶部：App 图标 + 名字，只做标识（「关于」入口在底部，不重复）
    private var brand: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
            Text("闪电下载").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 6)
    }

    /// 侧栏底部：「关于闪电下载」+ 版本号，一个入口；打开是介绍页，更新记录、反馈在里面切换
    private var versionRow: some View {
        Button { AppInfo.showAbout(.intro, openWindow) } label: {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("关于闪电下载")
                Spacer()
                Text(AppInfo.version).monospacedDigit()
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.sub)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
    }

    private func row(_ p: Pane, _ icon: Image) -> some View {
        let n = store.count(p)
        // 图标颜色交给系统：未选中用 App 强调色（Assets 里的 AccentColor），选中时变白
        return Label { Text(p.title) } icon: { icon }
            .badge(n > 0 ? Text("\(n)").monospacedDigit() : nil)
            .tag(p)
    }

    @ViewBuilder private var diskStatus: some View {
        switch store.engineState {
        case .missingDisk:
            Label("移动硬盘未连接", systemImage: "externaldrive.badge.exclamationmark")
                .font(.system(size: 12.5)).foregroundStyle(Theme.sub)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
        case .failed(let m):
            Label("内核未启动：\(m)", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12.5)).foregroundStyle(Theme.sub)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
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
            Button { store.showNewSheet = true } label: {
                Label("新建下载", systemImage: "plus").labelStyle(.titleAndIcon).font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .help("新建下载（⌘N）")
        }
    }
}

/// 剪贴板发现链接、重复提醒、失败原因：一行，可关闭
private struct Banners: View {
    @ObservedObject var store: DownloadStore
    var body: some View {
        VStack(spacing: 8) {
            if let links = store.clipboardLinks {
                bar(icon: "doc.on.clipboard", text: links.count > 1 ? "剪贴板中有 \(links.count) 个链接" : "剪贴板中有链接：" + DownloadStore.displayName(links[0])) {
                    Button("下载") { store.acceptClipboard() }.buttonStyle(.borderedProminent).tint(Theme.tint).controlSize(.small)
                    Button("忽略") { store.clipboardLinks = nil }.buttonStyle(.plain).foregroundStyle(Theme.sub).font(.system(size: 12))
                }
            }
            if let n = store.notice {
                bar(icon: "info.circle", text: n) {
                    Button { store.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.sub)
                }
            }
        }
        .padding(.bottom, store.clipboardLinks == nil && store.notice == nil ? 0 : 10)
    }
    private func bar<A: View>(icon: String, text: String, @ViewBuilder actions: () -> A) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.tint)
            Text(text).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
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
            // 没有任务时不显示速度区，只留空状态
            if items.isEmpty {
                EmptyState(store: store)
            } else {
                SpeedHero(store: store).frame(height: 156).padding(.top, 8).padding(.bottom, 20)
                Text(items.allSatisfy(\.isFailed) ? "未完成" : "进行中").font(.system(size: 15, weight: .semibold)).padding(.bottom, 6)
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

/// 速度横幅：速度曲线铺满整幅当背景，大号速度压在上面
private struct SpeedHero: View {
    @ObservedObject var store: DownloadStore
    var body: some View {
        let speed = store.totalSpeed
        let moving = store.activeItems.contains { $0.status == .running || $0.status == .waiting || $0.isResolving }
        let parts = moving ? speed.speedText.split(separator: " ") : ["已暂停"]
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(LinearGradient(colors: [Theme.tint.opacity(0.10), Theme.tint.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
            SpeedChart(values: store.speedHistory)
                .padding(.top, 34)
                .opacity(store.speedHistory.contains { $0 > 0 } ? 1 : 0.0)
                .clipShape(shape)
            VStack(alignment: .leading, spacing: 0) {
                Text("当前速度").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.sub)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.first.map(String.init) ?? "0").font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(parts.dropFirst().joined(separator: " ")).font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(Theme.sub)
                }
                HStack(spacing: 14) {
                    let failed = store.activeItems.filter(\.isFailed).count
                    let n = store.activeItems.count - failed
                    if n > 0 { Text("\(n) 项进行中") }
                    if failed > 0 { Text("\(failed) 项失败") }
                    let eta = remainingText(store.etaAll).replacingOccurrences(of: "剩余 ", with: "")
                    if moving, !eta.isEmpty { Text("预计 \(eta)后全部完成") }
                }
                .font(.system(size: 13)).foregroundStyle(Theme.sub).padding(.top, 4)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
        }
        .overlay(shape.strokeBorder(Theme.tint.opacity(0.18), lineWidth: 1))
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
                line.stroke(Theme.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .shadow(color: Theme.tint.opacity(0.5), radius: 6)
                if let last = pts.last { Circle().fill(Theme.tint).frame(width: 8, height: 8).position(x: last.x - 3, y: last.y) }
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0.15), .init(color: .black, location: 0.55)], startPoint: .leading, endPoint: .trailing))
            .animation(.easeOut(duration: 0.8), value: values)
        }
    }
}

/// 空闲页：带暖光的放置区（⌘V 或拖入），下面列支持的来源和累计下载
private struct EmptyState: View {
    @ObservedObject var store: DownloadStore
    private let sources = ["磁力", "种子", "ed2k", "直链", "网盘", "B 站", "YouTube", "X", "微博"]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 18) {
            VStack(spacing: 14) {
                Image(nsImage: BrandGlyph.image(height: 60)).foregroundStyle(Theme.tint)
                    .shadow(color: Theme.tint.opacity(0.45), radius: 14)
                Text("复制链接后按 ⌘V 开始下载").font(.system(size: 20, weight: .bold))
                Text("也可以把链接或种子文件拖到这里").font(.system(size: 13.5)).foregroundStyle(Theme.sub)
                HStack(spacing: 6) {
                    ForEach(sources, id: \.self) { s in
                        Text(s).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text.opacity(0.75))
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Capsule().fill(Theme.faint))
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 48)
            .background(
                shape.fill(RadialGradient(colors: [Theme.tint.opacity(0.12), Theme.tint.opacity(0.02)], center: .top, startRadius: 0, endRadius: 420))
            )
            .overlay(shape.strokeBorder(Theme.tint.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [7, 6])))
            let done = store.items.filter { !$0.isActive }
            if !done.isEmpty {
                Text("已完成 \(done.count) 项，共 \(done.reduce(Int64(0)) { $0 + $1.total }.bytesText)")
                    .font(.system(size: 13)).foregroundStyle(Theme.sub).monospacedDigit()
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
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
                LinearGradient(colors: [Theme.tint.opacity(0.16), Theme.tint.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: item.category.symbol).font(.system(size: width / 6, weight: .light)).foregroundStyle(Theme.tint.opacity(0.7))
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
                Text(item.title).font(.system(size: 15, weight: .medium)).lineLimit(1).truncationMode(.middle).help(item.rawTitle)
                HStack(spacing: 12) {
                    Text(item.origin)
                    Text(sizeText)
                    if case .failed(let m) = item.status { Text(m).foregroundStyle(Theme.failed) }
                }
                .font(.system(size: 13)).foregroundStyle(Theme.sub).lineLimit(1)
                ProgressBar(value: item.progress, dim: item.status == .paused || item.isResolving)
                    .padding(.top, 7)
            }
            VStack(alignment: .trailing, spacing: 3) {
                Text(primary).font(.system(size: 15, weight: .medium)).monospacedDigit()
                Text(secondary).font(.system(size: 13)).foregroundStyle(Theme.sub).monospacedDigit()
            }
            .frame(width: 140, alignment: .trailing)
            HStack(spacing: 6) {
                if case .engine = item.source {
                    CircleIconButton(symbol: item.status == .paused || item.isFailed ? "play.fill" : "pause.fill",
                                     help: item.status == .paused ? "继续" : "暂停") { store.togglePause(item) }
                } else if item.isFailed {
                    CircleIconButton(symbol: "arrow.clockwise", help: "重试") { store.retry(item) }
                }
                CircleIconButton(symbol: "xmark", help: "移除") { store.removalTarget = item }
            }
            .frame(width: 80, alignment: .trailing)
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
                Capsule()
                    .fill(dim ? AnyShapeStyle(Theme.sub) : AnyShapeStyle(LinearGradient(colors: [Theme.tint.opacity(0.65), Theme.tint], startPoint: .leading, endPoint: .trailing)))
                    .frame(width: max(0, g.size.width * value))
                    .shadow(color: dim ? .clear : Theme.tint.opacity(0.45), radius: 4)
                    .animation(.easeOut(duration: 0.6), value: value)
            }
        }
        .frame(height: 5)
    }
}

private struct ItemMenu: View {
    @ObservedObject var store: DownloadStore
    let item: Item
    var body: some View {
        if !item.isActive { Button("打开") { store.open(item) } }
        Button("在访达中显示") { store.reveal(item) }
        if item.isFailed {
            Button("重试") { store.retry(item) }
        } else if case .engine = item.source, item.isActive {
            Button(item.status == .paused ? "继续" : "暂停") { store.togglePause(item) }
        }
        Divider()
        Button("移除…") { store.removalTarget = item }
    }
}

// MARK: - 已完成 / 分类

private struct DonePage: View {
    @ObservedObject var store: DownloadStore
    let items: [Item]
    var subtitle: String?       // 分类页里「已完成」小标题；页面标题在窗口工具栏
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let subtitle { Text(subtitle).font(.system(size: 15, weight: .semibold)).padding(.bottom, 10) }
            if items.isEmpty {
                Text("暂无").font(.system(size: 14)).foregroundStyle(Theme.sub)
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
            Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle).padding(.top, 8).help(item.rawTitle)
            HStack(spacing: 10) {
                Text(item.total.bytesText)
                Text(item.origin)
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.sub).padding(.top, 2)
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
                Text("进行中").font(.system(size: 15, weight: .semibold)).padding(.bottom, 6)
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
    @State private var options = VideoOptions.current
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
            // 有视频网站链接时才出现；选项会记住，之后 ⌘V 也按它下载
            if links.contains(where: { LinkKind.of($0) == .videoSite }) {
                Divider()
                HStack(spacing: 18) {
                    HStack(spacing: 8) {
                        Text("画质").font(.system(size: 12.5)).foregroundStyle(Theme.sub)
                        Picker("", selection: $options.maxHeight) {
                            Text("最高").tag(0)
                            Text("1080P").tag(1080)
                            Text("720P").tag(720)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                        .disabled(options.audioOnly)
                    }
                    Toggle("下载字幕", isOn: $options.subtitles).disabled(options.audioOnly)
                    Toggle("仅音频", isOn: $options.audioOnly)
                }
                .font(.system(size: 12.5))
                .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("取消") { store.showNewSheet = false }.keyboardShortcut(.cancelAction)
                Button(links.count > 1 ? "下载 \(links.count) 项" : "下载") { VideoOptions.current = options; store.submitNewSheet() }
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
