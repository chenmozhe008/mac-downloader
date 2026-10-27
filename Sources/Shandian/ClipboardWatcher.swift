import AppKit
import SwiftUI

/// 复制即弹（参考迅雷）：后台每 0.7 秒看一次剪贴板计数，发现可下载的新链接就在屏幕右上角弹一个不抢焦点的小浮窗。
/// App 在前台时不弹浮窗，由窗口里的剪贴板提示条处理。
@MainActor
final class ClipboardWatcher {
    static let enabledKey = "watchClipboard"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private weak var store: DownloadStore?
    private var lastCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var panel: NSPanel?
    private var closeTask: Task<Void, Never>?

    init(store: DownloadStore) {
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let count = NSPasteboard.general.changeCount
        guard count != lastCount else { return }
        lastCount = count
        guard Self.enabled, !NSApp.isActive, let store,
              let text = NSPasteboard.general.string(forType: .string) else { return }
        let links = store.newClipboardLinks(in: text).filter(LinkKind.worthPopup)
        guard !links.isEmpty else { return }
        store.markSeen(links)
        show(links)
    }

    private func show(_ links: [String]) {
        close()
        let view = ClipboardPopup(links: links,
                                  onDownload: { [weak self] in self?.store?.addFromPopup(links); self?.close() },
                                  onIgnore: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let p = NSPanel(contentRect: host.frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.maxX - host.frame.width - 16, y: screen.maxY - host.frame.height - 12))
        }
        p.orderFrontRegardless()
        panel = p
        closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { self?.close() }
        }
    }

    func close() {
        closeTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ClipboardPopup: View {
    let links: [String]
    let onDownload: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        let first = links[0]
        let kind = LinkKind.of(first)
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(links.count > 1 ? "检测到 \(links.count) 个下载链接" : "检测到下载链接")
                    .font(.system(size: 13, weight: .semibold))
                Text(PrettyTitle.clean(DownloadStore.displayName(first)))
                    .font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                if let kind {
                    Text("\(kind.label)　存到「\(Folders.displayName(Folders.directory(for: kind)))」")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Button(links.count > 1 ? "全部下载" : "下载", action: onDownload)
                        .buttonStyle(.borderedProminent).tint(Theme.tint).controlSize(.small)
                    Button("忽略", action: onIgnore).controlSize(.small)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}
