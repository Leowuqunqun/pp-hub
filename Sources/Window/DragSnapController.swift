import AppKit
import ApplicationServices

/// 拖到屏幕边缘 → 吸附
/// 判定链：按下时鼠标落在某窗口的标题栏带内 → 认定为"拖窗口" → 拖到边缘出现预览 →
/// 松手时才真正改窗口。每一步都可中断，任何一环不满足就当普通拖拽，不干预。
final class DragSnapController {

    private var downMonitor: Any?
    private var dragMonitor: Any?
    private var upMonitor: Any?

    private var candidateWindow: AXUIElement?
    private var candidateFrame: NSRect = .zero
    private var isWindowDrag = false
    private var downPoint: NSPoint = .zero
    private var pending: (layout: SnapLayout, rect: NSRect)?
    private var preview: NSWindow?

    private let edgeThreshold: CGFloat = 8
    private let titleBarBand: CGFloat = 40

    func start() {
        stop()
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.handleDown()
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            self?.handleDrag()
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.handleUp()
        }
        Log.write("dragsnap: 已启动（边缘触发阈值 \(Int(edgeThreshold))px）")
    }

    func stop() {
        [downMonitor, dragMonitor, upMonitor].forEach { if let m = $0 { NSEvent.removeMonitor(m) } }
        downMonitor = nil; dragMonitor = nil; upMonitor = nil
        hidePreview()
    }

    // MARK: - 事件

    private func handleDown() {
        candidateWindow = nil
        isWindowDrag = false
        pending = nil
        downPoint = NSEvent.mouseLocation

        guard let win = SnapManager.window(at: downPoint) else { return }
        guard let frame = SnapManager.frameForDrag(win) else { return }
        // 只有按在窗口顶部标题带才算是"拖窗口"，否则是拖内容（选文字、拖文件）
        guard downPoint.y <= frame.maxY, downPoint.y >= frame.maxY - titleBarBand else { return }

        candidateWindow = win
        candidateFrame = frame
        isWindowDrag = true
    }

    private func handleDrag() {
        guard isWindowDrag, let win = candidateWindow else { return }
        let p = NSEvent.mouseLocation
        guard hypot(p.x - downPoint.x, p.y - downPoint.y) > 6 else { return }   // 抖动不算拖拽

        guard let zone = edgeZone(at: p) else {
            pending = nil
            hidePreview()
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
        let rect = SnapManager.targetRect(for: zone, screen: screen, current: candidateFrame)
        pending = (zone, rect)
        showPreview(rect, on: screen)
        _ = win
    }

    private func handleUp() {
        defer {
            hidePreview()
            isWindowDrag = false
            candidateWindow = nil
            pending = nil
        }
        guard isWindowDrag, let (layout, _) = pending, let win = candidateWindow else { return }
        Log.write("dragsnap: 吸附 \(layout.title)")
        SnapManager.applyToWindow(layout, window: win)
    }

    // MARK: - 边缘判定

    private func edgeZone(at p: NSPoint) -> SnapLayout? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) else { return nil }
        let f = screen.frame
        let nearLeft = p.x <= f.minX + edgeThreshold
        let nearRight = p.x >= f.maxX - edgeThreshold
        let nearTop = p.y >= f.maxY - edgeThreshold

        if nearTop && nearLeft { return .topLeft }
        if nearTop && nearRight { return .topRight }
        if nearLeft { return .leftHalf }
        if nearRight { return .rightHalf }
        if nearTop { return .maximize }
        return nil
    }

    // MARK: - 预览框

    private func showPreview(_ rect: NSRect, on screen: NSScreen) {
        if preview == nil {
            let w = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.hasShadow = false
            let view = PreviewView(frame: NSRect(origin: .zero, size: rect.size))
            view.autoresizingMask = [.width, .height]
            w.contentView = view
            preview = w
        }
        preview?.setFrame(rect, display: true)
        preview?.orderFront(nil)
    }

    private func hidePreview() {
        preview?.orderOut(nil)
    }
}

/// 半透明高亮框：让用户松手前就知道会变成什么样
private final class PreviewView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
