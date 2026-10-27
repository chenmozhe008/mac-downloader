import AppKit
import SwiftUI

/// App 图标里的「闪电箭头」（闪电组成下载箭头 + 底部托盘线），侧栏、空状态、菜单栏统一用它。
/// 路径与 Resources/icon/icon.html 一致（1024 画布中 x 300–724、y 196–876 的部分）。
enum BrandGlyph {
    private static let box = CGRect(x: 300, y: 196, width: 424, height: 680)
    private static let arrow: [CGPoint] = [(560, 196), (410, 470), (520, 470), (452, 610), (330, 610), (512, 806),
                                           (694, 610), (566, 610), (640, 452), (534, 452), (652, 196)].map { CGPoint(x: $0.0, y: $0.1) }
    private static let tray = CGRect(x: 300, y: 842, width: 424, height: 34)

    /// 模板图（跟随文字颜色、选中时自动变白），height 为点数
    static func image(height: CGFloat) -> NSImage {
        let width = height * box.width / box.height
        let img = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            let s = rect.height / box.height
            let p = NSBezierPath()
            for (i, pt) in arrow.enumerated() {
                let q = NSPoint(x: (pt.x - box.minX) * s, y: (pt.y - box.minY) * s)
                i == 0 ? p.move(to: q) : p.line(to: q)
            }
            p.close()
            let t = tray.offsetBy(dx: -box.minX, dy: -box.minY)
            p.append(NSBezierPath(roundedRect: NSRect(x: t.minX * s, y: t.minY * s, width: t.width * s, height: t.height * s),
                                  xRadius: t.height * s / 2, yRadius: t.height * s / 2))
            NSColor.black.setFill()
            p.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
