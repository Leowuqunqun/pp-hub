import Cocoa

/// 悬浮提示条：不抢焦点、全空间可见、鼠标穿透
final class HUD {
    private var panel: NSPanel?
    private var view: HUDView?

    private let size = NSSize(width: 360, height: 84)

    func show() {
        if panel == nil { build() }
        position()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel?.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    func set(level: Float) { view?.level = CGFloat(level) }
    func set(state: String) { view?.state = state }
    func set(text: String) { view?.text = text }

    private func build() {
        let v = HUDView(frame: NSRect(origin: .zero, size: size))
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentView = v
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        panel = p
        view = v
    }

    private func position() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - size.width / 2
        let y = frame.minY + 110
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }
}

final class HUDView: NSView {
    var level: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var state: String = "聆听中…" {
        didSet { needsDisplay = true }
    }
    var text: String = "" {
        didSet { needsDisplay = true }
    }

    private var bars: [CGFloat] = Array(repeating: 0.06, count: 16)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        NSColor(calibratedWhite: 0.08, alpha: 0.82).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
        path.lineWidth = 1
        path.stroke()

        // 电平条：随机轻微抖动 + 电平驱动，产生"在说话"的观感
        let barCount = bars.count
        let barW: CGFloat = 3
        let gap: CGFloat = 4
        let totalW = CGFloat(barCount) * barW + CGFloat(barCount - 1) * gap
        let startX = (bounds.width - totalW) / 2
        let midY: CGFloat = 30
        let maxH: CGFloat = 22

        for i in 0..<barCount {
            let target = max(0.06, min(1, level * (0.55 + 0.45 * CGFloat.random(in: 0...1))))
            bars[i] = bars[i] * 0.55 + target * 0.45
            let h = max(3, maxH * bars[i])
            let x = startX + CGFloat(i) * (barW + gap)
            let r = NSRect(x: x, y: midY - h / 2, width: barW, height: h)
            let barPath = NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5)
            NSColor(calibratedRed: 0.36, green: 0.72, blue: 1.0, alpha: 0.95).setFill()
            barPath.fill()
        }

        // 状态
        let stateAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.55)
        ]
        let stateStr = NSAttributedString(string: state, attributes: stateAttrs)
        let stateSize = stateStr.size()
        stateStr.draw(at: NSPoint(x: (bounds.width - stateSize.width) / 2, y: midY + 18))

        // 文本（单行，尾部省略）
        guard !text.isEmpty else { return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = .center
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.92),
            .paragraphStyle: para
        ]
        NSAttributedString(string: text, attributes: textAttrs)
            .draw(in: NSRect(x: 16, y: midY + 36, width: bounds.width - 32, height: 18))
    }
}
