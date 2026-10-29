import AppKit
import SwiftUI

extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// 效果图 v3（2026-10-27 定稿）：整体黑白灰，唯一的颜色是琥珀色（呼应「闪电」），只用在侧栏图标、进度条、速度曲线
enum Theme {
    static let tint = Color.adaptive(light: rgb(232, 154, 0), dark: rgb(255, 181, 38))
    static let window = Color.adaptive(light: rgb(251, 250, 248), dark: rgb(27, 27, 29))
    static let text = Color.adaptive(light: rgb(29, 29, 31), dark: rgb(245, 245, 247))
    static let sub = Color.adaptive(light: rgb(138, 138, 142), dark: rgb(152, 152, 157))
    static let line = Color.adaptive(light: rgb(0, 0, 0, 0.07), dark: rgb(255, 255, 255, 0.07))
    static let faint = Color.adaptive(light: rgb(0, 0, 0, 0.045), dark: rgb(255, 255, 255, 0.06))
    static let track = Color.adaptive(light: rgb(0, 0, 0, 0.07), dark: rgb(255, 255, 255, 0.10))
    static let glow = Color.adaptive(light: rgb(232, 154, 0, 0.13), dark: rgb(255, 181, 38, 0.14))
    static let raised = Color.adaptive(light: rgb(255, 255, 255), dark: rgb(44, 44, 47))   // 卡片
    static let failed = Color.adaptive(light: rgb(215, 58, 46), dark: rgb(255, 105, 97))
}

extension View {
    /// macOS 26 液态玻璃；更早的系统用磨砂材质
    @ViewBuilder
    func glassPanel(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.line, lineWidth: 0.5))
        }
    }
}

/// 鼠标悬停状态放在单独的小对象里，只让这一行重画
final class HoverBox: ObservableObject { @Published var on = false }

/// 小圆形图标按钮（暂停、移除）
struct CircleIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text.opacity(0.8))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.primary.opacity(0.09)))  // Theme.faint 在暖色背景上太淡
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
