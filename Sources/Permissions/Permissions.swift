import AppKit
import ApplicationServices

/// 权限：只碰「辅助功能」与（M4 的）「麦克风」
/// 约定：缺权限不崩、不静默失败——一律返回状态，由 UI 显示
enum Permissions {

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// 弹系统授权框（只会弹一次，之后要用户自己去设置里勾）
    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
