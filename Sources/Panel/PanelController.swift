import AppKit
import SwiftUI

/// 能成为 key window 的无边框面板（否则里面的输入框收不到键盘）
final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 面板控制器：**预建复用**，热键只做 orderFront，不重建视图（这是 150ms 的来源）
/// 面板的两种用途：启动器 / 剪贴板历史
enum PanelMode {
    case launcher
    case clipboard
}

final class PanelController {
    private let panel: SearchPanel
    private let hosting: NSHostingView<PanelRoot>
    private let clipHosting: NSHostingView<ClipRoot>

    var window: NSWindow { panel }

    init() {
        let rect = NSRect(x: 0, y: 0, width: 640, height: 420)
        panel = SearchPanel(contentRect: rect,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        hosting = NSHostingView(rootView: PanelRoot())
        hosting.frame = rect
        clipHosting = NSHostingView(rootView: ClipRoot())
        clipHosting.frame = rect
        panel.contentView = hosting

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(hideFromNotification),
                                               name: .ppHubHide,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didResignKey(_:)),
                                               name: NSWindow.didResignKeyNotification,
                                               object: panel)
    }

    // MARK: - 显示 / 隐藏

    /// 当前展示的是哪种模式（用于"按同一个键关掉"）
    private(set) var mode: PanelMode = .launcher

    func toggle(_ wanted: PanelMode = .launcher) {
        // 已经开着同一种 → 收起；开着另一种 → 直接切过去
        if panel.isVisible && mode == wanted { hide(); return }
        show(wanted)
    }

    func show(_ wanted: PanelMode = .launcher) {
        mode = wanted
        panel.contentView = (wanted == .launcher) ? hosting : clipHosting
        positionOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        Log.write("panel: 显示 \(wanted == .launcher ? "启动器" : "剪贴板")")
        NotificationCenter.default.post(
            name: wanted == .launcher ? .ppHubShown : .ppClipShown,
            object: nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    @objc private func hideFromNotification() { hide() }

    @objc private func didResignKey(_ note: Notification) {
        // 点到别处就收起；与「启动器」的肌肉记忆一致
        DispatchQueue.main.async { [weak self] in self?.hide() }
    }

    /// 居中偏上：视觉重心在屏幕上方 1/3 处，符合「抬头找东西」的习惯
    private func positionOnActiveScreen() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let x = screen.midX - size.width / 2
        let y = screen.maxY - size.height - screen.height * 0.18
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
