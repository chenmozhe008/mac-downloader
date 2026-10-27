import AppKit
import SwiftUI

/// 新建任务确认框（参考迅雷）：浏览器、复制即弹、粘贴、拖入进来的链接都先到这里，
/// 看清名字、大小、存哪、剩余空间，种子可以勾选文件，再开始下载。
/// 「以后不再询问」后直接下载，偏好设置里可改回。
@MainActor
final class NewTaskPanels {
    static let shared = NewTaskPanels()
    static let askKey = "confirmNewTask"
    static var ask: Bool {
        get { UserDefaults.standard.object(forKey: askKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: askKey) }
    }

    private var panels: [NSPanel] = []

    func present(links: [String], headers: [String: String], name: String?, store: DownloadStore) {
        let model = NewTaskModel(links: links, headers: headers, name: name, store: store)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        model.close = { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.panels.removeAll { $0 === panel }
        }
        let host = NSHostingView(rootView: NewTaskView(model: model))
        panel.contentView = host
        panel.title = "新建下载任务"
        panel.titleVisibility = .hidden  // 标题画在内容里居中，和迅雷一致
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false  // 切回浏览器时框别消失，否则以为没反应
        panel.setContentSize(host.fittingSize)
        panel.center()
        // 连续来了几个，错开一点，别叠在一起看不出来
        if let last = panels.last { panel.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24)) }
        panels.append(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class NewTaskModel: ObservableObject {
    let links: [String]
    let headers: [String: String]
    let kind: LinkKind?
    weak var store: DownloadStore?
    var close: () -> Void = {}

    @Published var title: String
    @Published var size: Int64 = 0
    @Published var files: [EngineTask.Meta.File] = []
    @Published var selected = Set<Int>()
    @Published var resolving = false
    @Published var resolveFailed = false
    @Published var dir: URL
    @Published var dontAsk = false
    @Published var video = VideoOptions.current

    private let nameFromBrowser: String?
    private let defaultDir: URL

    init(links: [String], headers: [String: String], name: String?, store: DownloadStore) {
        self.links = links
        self.headers = headers
        self.store = store
        nameFromBrowser = name
        kind = LinkKind.of(links[0])
        defaultDir = kind.map(Folders.directory(for:)) ?? Folders.downloads
        dir = defaultDir
        title = links.count > 1 ? "" : (name ?? PrettyTitle.clean(DownloadStore.displayName(links[0])))
        if links.count == 1, kind != .videoSite { Task { await resolve() } }
    }

    var single: Bool { links.count == 1 }
    var isTorrent: Bool { kind == .magnet || kind == .torrentFile }
    var selectedSize: Int64 {
        files.isEmpty ? size : selected.reduce(Int64(0)) { $0 + ($1 < files.count ? files[$1].size : 0) }
    }
    var free: Int64? {
        (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
    var notEnoughSpace: Bool { if let free, selectedSize > 0 { return selectedSize > free }; return false }

    /// 下拉里的位置：默认位置 + 最近用过的（最多 5 个）
    var dirChoices: [URL] {
        var list = [defaultDir]
        for p in UserDefaults.standard.stringArray(forKey: "recentDirs") ?? [] {
            let u = URL(fileURLWithPath: p)
            if !list.contains(u), FileManager.default.fileExists(atPath: p) { list.append(u) }
        }
        if !list.contains(dir) { list.append(dir) }
        return list
    }

    private func resolve() async {
        guard let store else { return }
        resolving = true
        defer { resolving = false }
        guard let r = await store.resolveForPanel(links[0], headers: headers) else { resolveFailed = true; return }
        if isTorrent {
            files = r.files
            selected = Set(FileSelection.pick(r.files) ?? Array(r.files.indices))
            if !r.name.isEmpty { title = PrettyTitle.clean(r.name) }
        } else {
            size = r.files.reduce(0) { $0 + $1.size }
            if nameFromBrowser == nil, let n = r.files.first?.name, !n.isEmpty { title = n }
        }
    }

    /// 位置菜单：在鼠标处弹出系统菜单
    func showDirMenu() {
        let menu = NSMenu()
        for d in dirChoices {
            let item = NSMenuItem(title: Folders.displayName(d), action: nil, keyEquivalent: "")
            item.state = d == dir ? .on : .off
            item.toolTip = d.path
            menu.addItem(ClosureMenuItem.make(item) { [weak self] in self?.dir = d })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem.make(NSMenuItem(title: "选择其他文件夹…", action: nil, keyEquivalent: "")) { [weak self] in self?.chooseFolder() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = dir; p.prompt = "选择"
        if p.runModal() == .OK, let u = p.url { dir = u }
    }

    func download() {
        guard let store else { return }
        if dir != defaultDir {
            var recent = UserDefaults.standard.stringArray(forKey: "recentDirs") ?? []
            recent.removeAll { $0 == dir.path }; recent.insert(dir.path, at: 0)
            UserDefaults.standard.set(Array(recent.prefix(5)), forKey: "recentDirs")
        }
        if dontAsk { NewTaskPanels.ask = false }
        if kind == .videoSite { VideoOptions.current = video }
        let rename = single && !isTorrent && title != (nameFromBrowser ?? "") && !title.isEmpty ? title : nameFromBrowser
        for l in links {
            store.start(link: l, headers: headers, name: single ? rename : nil, dir: dir,
                        selectFiles: single && isTorrent && !files.isEmpty ? selected.sorted() : nil)
        }
        close()
    }
}

enum FileGroup: CaseIterable {
    case video, subtitle, other
    static func of(_ name: String) -> FileGroup {
        let e = (name as NSString).pathExtension.lowercased()
        if FileSelection.videoExt.contains(e) { return .video }
        if FileSelection.subtitleExt.contains(e) { return .subtitle }
        return .other
    }
    var label: String { switch self { case .video: "视频"; case .subtitle: "字幕"; case .other: "其他" } }
    var symbol: String { switch self { case .video: "play.rectangle.fill"; case .subtitle: "captions.bubble.fill"; case .other: "doc.fill" } }
}

/// 版式参照迅雷「新建 BT 任务」：标题居中、文件表带类型和大小、按类型快速勾选、底部只有一个醒目的「立即下载」
struct NewTaskView: View {
    @ObservedObject var model: NewTaskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(heading).font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity)
            header
            if model.single, model.isTorrent, !model.files.isEmpty { fileTable }
            if model.kind == .videoSite { videoOptions }
            if !model.single { linkList }
            location
            footer
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 20)
        .frame(width: 560)
        .background(Theme.window)
        .tint(Theme.tint)
    }

    private var heading: String {
        if !model.single { return "批量下载（\(model.links.count) 个）" }
        switch model.kind {
        case .magnet, .torrentFile: return "新建 BT 任务"
        case .videoSite: return "新建视频任务"
        default: return "新建下载任务"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isTorrent ? "folder.fill" : model.kind == .videoSite ? "play.rectangle.fill" : "doc.fill")
                .font(.system(size: 26)).foregroundStyle(Theme.tint).frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                if model.single && !model.isTorrent && model.kind != .videoSite {
                    TextField("文件名", text: $model.title).textFieldStyle(.roundedBorder).font(.system(size: 14))
                } else {
                    Text(model.single ? model.title : "\(model.links.count) 个下载链接")
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    if let k = model.kind { Text(k.label) }
                    if model.resolving {
                        ProgressView().controlSize(.mini)
                        Text(model.kind == .magnet ? "正在获取文件列表，磁力可能需要一会儿，也可以直接下载" : "正在读取文件信息")
                    } else if !model.isTorrent, model.size > 0 {
                        Text(model.size.bytesText)
                    } else if model.resolveFailed {
                        Text("暂时读不到文件信息，可以直接下载")
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(Theme.sub).lineLimit(1)
            }
        }
    }

    /// 种子里的文件：按「只下正片」预先勾好；大的在上
    private var fileTable: some View {
        let order = model.files.indices.sorted { model.files[$0].size > model.files[$1].size }
        return VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                HStack {
                    Text("文件名称").frame(maxWidth: .infinity, alignment: .leading)
                    Text("类型").frame(width: 56, alignment: .leading)
                    Text("大小").frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.sub)
                .padding(.horizontal, 12).frame(height: 28)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(order, id: \.self) { i in row(i) }
                    }
                }
                .frame(height: min(CGFloat(model.files.count) * 28 + 4, 196))
            }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line))
            HStack(spacing: 14) {
                Toggle("全选", isOn: groupBinding(nil))
                ForEach(FileGroup.allCases, id: \.self) { g in
                    if model.files.contains(where: { FileGroup.of($0.name) == g }) { Toggle(g.label, isOn: groupBinding(g)) }
                }
                Button("只选正片") { model.selected = Set(FileSelection.pick(model.files) ?? Array(model.files.indices)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.tint)
                Spacer()
                Text("已选 \(model.selected.count) 个，共 \(model.selectedSize.bytesText)").foregroundStyle(Theme.sub)
            }
            .toggleStyle(.checkbox).font(.system(size: 12.5))
        }
    }

    private func row(_ i: Int) -> some View {
        let f = model.files[i]
        let g = FileGroup.of(f.name)
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { model.selected.contains(i) },
                                     set: { if $0 { model.selected.insert(i) } else { model.selected.remove(i) } }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(systemName: g.symbol).font(.system(size: 12)).foregroundStyle(g == .video ? Theme.tint : Theme.sub).frame(width: 16)
            Text(f.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Text((f.name as NSString).pathExtension.lowercased()).foregroundStyle(Theme.sub).frame(width: 56, alignment: .leading)
            Text(f.size.bytesText).foregroundStyle(Theme.sub).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).frame(height: 28)
        .contentShape(Rectangle())
        .onTapGesture { if model.selected.contains(i) { model.selected.remove(i) } else { model.selected.insert(i) } }
    }

    /// 全选 / 某一类全选；勾上是加进来，取消是去掉
    private func groupBinding(_ g: FileGroup?) -> Binding<Bool> {
        let members = Set(model.files.indices.filter { g == nil || FileGroup.of(model.files[$0].name) == g })
        return Binding(get: { !members.isEmpty && members.isSubset(of: model.selected) },
                       set: { if $0 { model.selected.formUnion(members) } else { model.selected.subtract(members) } })
    }

    private var videoOptions: some View {
        HStack(spacing: 16) {
            Text("画质").font(.system(size: 13)).foregroundStyle(Theme.sub)
            Picker("", selection: $model.video.maxHeight) {
                Text("最高").tag(0)
                Text("1080P").tag(1080)
                Text("720P").tag(720)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            .disabled(model.video.audioOnly)
            Toggle("下载字幕", isOn: $model.video.subtitles).toggleStyle(.checkbox).disabled(model.video.audioOnly)
            Toggle("仅音频", isOn: $model.video.audioOnly).toggleStyle(.checkbox)
        }
        .font(.system(size: 13))
    }

    private var linkList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.links, id: \.self) { l in
                    Text(PrettyTitle.clean(DownloadStore.displayName(l))).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .frame(height: min(CGFloat(model.links.count) * 20 + 20, 140))
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line))
    }

    /// 保存位置：整行就是一个按钮，点哪儿都弹出位置菜单（最近用过的 + 选择其他文件夹）；剩余空间放在行尾
    private var location: some View {
        Button { model.showDirMenu() } label: {
            HStack(spacing: 10) {
                Image(systemName: model.dir.path.hasPrefix("/Volumes/") ? "externaldrive.fill" : "folder.fill")
                    .font(.system(size: 16)).foregroundStyle(Theme.tint).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("保存到 \(Folders.displayName(model.dir))").font(.system(size: 13.5, weight: .medium))
                    Text((model.dir.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.sub).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Group {
                    if let free = model.free {
                        Text(model.notEnoughSpace ? "空间不足，需 \(model.selectedSize.bytesText)" : "剩余 \(free.bytesText)")
                            .foregroundStyle(model.notEnoughSpace ? Theme.failed : Theme.text)
                    } else {
                        Text("硬盘未连接").foregroundStyle(Theme.failed)
                    }
                }
                .font(.system(size: 13, weight: .medium)).monospacedDigit()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.sub)
            }
            .padding(.horizontal, 12).frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(model.notEnoughSpace || model.free == nil ? Theme.failed.opacity(0.6) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击更改保存位置")
        .accessibilityLabel("保存位置")
    }

    private var footer: some View {
        HStack {
            Toggle("以后不再询问，直接下载", isOn: $model.dontAsk).toggleStyle(.checkbox).font(.system(size: 12.5))
            Spacer()
            // 取消用左上角关闭或 Esc；底部只留一个主按钮，和迅雷一样不让人犹豫点哪个
            Button("取消") { model.close() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0)
            Button { model.download() } label: {
                Text("立即下载").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 140, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(disabled ? AnyShapeStyle(Theme.sub.opacity(0.5)) : AnyShapeStyle(Theme.tint)))
                    .shadow(color: disabled ? .clear : Theme.tint.opacity(0.35), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("立即下载")
            .keyboardShortcut(.defaultAction)
            .disabled(disabled)
        }
    }

    private var disabled: Bool { model.single && model.isTorrent && !model.files.isEmpty && model.selected.isEmpty }
}

/// NSMenuItem 用闭包回调（SwiftUI 里弹系统菜单用）
final class ClosureMenuItem: NSObject {
    private let action: () -> Void
    private init(_ action: @escaping () -> Void) { self.action = action }
    @objc private func run() { action() }
    @MainActor private static var keep: [ClosureMenuItem] = []

    @MainActor static func make(_ item: NSMenuItem, _ action: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureMenuItem(action)
        keep.append(target)
        if keep.count > 50 { keep.removeFirst(keep.count - 50) }
        item.target = target
        item.action = #selector(run)
        return item
    }
}
