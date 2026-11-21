import AppKit
import ApplicationServices

/// 窗口布局
enum SnapLayout {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftTwoThirds, rightTwoThirds, leftThird, rightThird
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center

    /// 稳定标识（菜单项 representedObject 用）
    var key: String {
        switch self {
        case .leftHalf: return "left"; case .rightHalf: return "right"
        case .leftTwoThirds: return "left2"; case .rightTwoThirds: return "right2"
        case .leftThird: return "left3"; case .rightThird: return "right3"
        case .topHalf: return "top"; case .bottomHalf: return "bottom"
        case .topLeft: return "tl"; case .topRight: return "tr"
        case .bottomLeft: return "bl"; case .bottomRight: return "br"
        case .maximize: return "max"; case .center: return "center"
        }
    }

    static let all: [SnapLayout] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .maximize, .center,
    ]

    /// 菜单里的展示顺序与键位提示
    static let menuItems: [(String, String)] = [
        ("左半屏  ⌃⌥←", SnapLayout.leftHalf.key),
        ("右半屏  ⌃⌥→", SnapLayout.rightHalf.key),
        ("上半屏  ⌃⌥↑", SnapLayout.topHalf.key),
        ("下半屏  ⌃⌥↓", SnapLayout.bottomHalf.key),
        ("左上角  ⌃⌥U", SnapLayout.topLeft.key),
        ("右上角  ⌃⌥I", SnapLayout.topRight.key),
        ("左下角  ⌃⌥J", SnapLayout.bottomLeft.key),
        ("右下角  ⌃⌥K", SnapLayout.bottomRight.key),
        ("最大化  ⌃⌥↩", SnapLayout.maximize.key),
        ("居中", SnapLayout.center.key),
    ]

    var title: String {
        switch self {
        case .leftTwoThirds: return "左 2/3"
        case .rightTwoThirds: return "右 2/3"
        case .leftThird: return "左 1/3"
        case .rightThird: return "右 1/3"
        case .leftHalf: return "左半屏"
        case .rightHalf: return "右半屏"
        case .topHalf: return "上半屏"
        case .bottomHalf: return "下半屏"
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        case .maximize: return "最大化"
        case .center: return "居中"
        }
    }
}

/// 窗口吸附：用辅助功能 API 直接改目标窗口的 frame
/// 注意坐标系：AX 用「屏幕左上角为原点、y 向下」，NSScreen 用「左下角为原点、y 向上」，
/// 两者必须换算，否则窗口会跑到屏幕外面（这是这类工具最常见的 bug）。
enum SnapManager {

    @discardableResult
    static func apply(_ layout: SnapLayout) -> Bool {
        guard let window = focusedWindow() else {
            Log.write("snap: 取不到前台窗口（\(layout.title)）")
            return false
        }
        if isFullScreen(window) {
            Log.write("snap: 全屏窗口跳过（\(layout.title)）")
            return false
        }

        guard let current = frame(of: window) else {
            Log.write("snap: 读不到窗口 frame")
            return false
        }

        let screen = screen(for: current)
        let visible = screen.visibleFrame
        let target = rect(for: layout, in: visible, current: current)
        return setFrame(window, to: target)
    }

    // MARK: - 目标矩形

    /// 注意：`internal` 而非 `private`，是为了让 `--selftest snaps` 能验证几何而不复制一份算法
    static func rect(for layout: SnapLayout, in v: NSRect, current: NSRect) -> NSRect {
        let w = v.width, h = v.height
        let gap: CGFloat = 0

        switch layout {
        case .leftHalf:     return NSRect(x: v.minX, y: v.minY, width: w / 2 - gap, height: h)
        case .leftTwoThirds:  return NSRect(x: v.minX, y: v.minY, width: w * 2 / 3 - gap, height: h)
        case .rightTwoThirds: return NSRect(x: v.maxX - w * 2 / 3, y: v.minY, width: w * 2 / 3 - gap, height: h)
        case .leftThird:      return NSRect(x: v.minX, y: v.minY, width: w / 3 - gap, height: h)
        case .rightThird:     return NSRect(x: v.maxX - w / 3, y: v.minY, width: w / 3 - gap, height: h)
        case .rightHalf:    return NSRect(x: v.midX + gap, y: v.minY, width: w / 2 - gap, height: h)
        case .topHalf:      return NSRect(x: v.minX, y: v.midY + gap, width: w, height: h / 2 - gap)
        case .bottomHalf:   return NSRect(x: v.minX, y: v.minY, width: w, height: h / 2 - gap)
        case .topLeft:      return NSRect(x: v.minX, y: v.midY + gap, width: w / 2 - gap, height: h / 2 - gap)
        case .topRight:     return NSRect(x: v.midX + gap, y: v.midY + gap, width: w / 2 - gap, height: h / 2 - gap)
        case .bottomLeft:   return NSRect(x: v.minX, y: v.minY, width: w / 2 - gap, height: h / 2 - gap)
        case .bottomRight:  return NSRect(x: v.midX + gap, y: v.minY, width: w / 2 - gap, height: h / 2 - gap)
        case .maximize:     return v
        case .center:
            let cw = min(current.width, w * 0.8)
            let ch = min(current.height, h * 0.8)
            return NSRect(x: v.midX - cw / 2, y: v.midY - ch / 2, width: cw, height: ch)
        }
    }

    /// 给定布局与屏幕，算出目标矩形（拖拽预览与最终吸附共用同一套算法）
    static func targetRect(for layout: SnapLayout, screen: NSScreen, current: NSRect) -> NSRect {
        rect(for: layout, in: screen.visibleFrame, current: current)
    }

    /// 作用到指定窗口（拖拽吸附用：那扇窗口不是"前台窗口"）
    @discardableResult
    static func applyToWindow(_ layout: SnapLayout, window: AXUIElement) -> Bool {
        guard let current = frame(of: window) else { return false }
        let target = rect(for: layout, in: screen(for: current).visibleFrame, current: current)
        return setFrame(window, to: target)
    }

    /// 按屏幕坐标找窗口（拖拽时用来判断"拖的是不是一扇窗口"）
    static func window(at nsPoint: NSPoint) -> AXUIElement? {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(system, Float(nsPoint.x), Float(mainHeight - nsPoint.y), &element)
        guard err == .success, let element else { return nil }
        return windowOwning(element)
    }

    private static func windowOwning(_ element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &ref) == .success,
           let ref { return (ref as! AXUIElement) }

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let role = role as? String, role == (kAXWindowRole as String) { return element }

        // 向上找父级（有些 app 把窗口包在 AXGroup 里）
        var parent: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
           let parent {
            return windowOwning(parent as! AXUIElement)
        }
        return nil
    }

    // MARK: - 跨显示器移动

    /// 把当前窗口原样挪到相邻显示器（保持相对位置与尺寸，只做水平偏移后夹紧）
    @discardableResult
    static func moveToNextDisplay(step: Int) -> Bool {
        guard let window = focusedWindow(), let current = frame(of: window) else { return false }
        let screens = NSScreen.screens
        guard screens.count > 1 else {
            Log.write("snap: 只有一块屏，跨屏移动跳过")
            return false
        }
        let from = screen(for: current)
        guard let idx = screens.firstIndex(of: from) else { return false }
        var next = idx + step
        if next < 0 { next = screens.count - 1 }
        if next >= screens.count { next = 0 }
        let target = screens[next].visibleFrame

        // 保持"相对本屏的位置"，再夹进目标屏，避免窗口跑到屏幕外
        let ratioX = (current.minX - from.visibleFrame.minX) / max(1, from.visibleFrame.width)
        let ratioY = (current.minY - from.visibleFrame.minY) / max(1, from.visibleFrame.height)
        let width = min(current.width, target.width)
        let height = min(current.height, target.height)
        var x = target.minX + ratioX * target.width
        var y = target.minY + ratioY * target.height
        x = min(max(x, target.minX), target.maxX - width)
        y = min(max(y, target.minY), target.maxY - height)

        return setFrame(window, to: NSRect(x: x, y: y, width: width, height: height))
    }

    // MARK: - AX 取窗口

    private static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)
        guard err == .success, let win = value else { return nil }
        return (win as! AXUIElement)
    }

    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    static func frameForDrag(_ window: AXUIElement) -> NSRect? { frame(of: window) }

    private static func frame(of window: AXUIElement) -> NSRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        // AX(左上原点, y 向下) → NSScreen(左下原点, y 向上)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let nsY = mainHeight - point.y - size.height
        return NSRect(x: point.x, y: nsY, width: size.width, height: size.height)
    }

    private static func setFrame(_ window: AXUIElement, to rect: NSRect) -> Bool {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let axY = mainHeight - rect.origin.y - rect.height
        var point = CGPoint(x: rect.origin.x, y: axY)
        var size = CGSize(width: rect.width, height: rect.height)

        guard let posValue = AXValueCreate(.cgPoint, &point),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }

        // 先设位置再设尺寸：反过来的话，某些 app 会按旧位置重新约束尺寸，导致位置跑偏
        let e1 = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        let e2 = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        if e1 != .success || e2 != .success {
            Log.write("snap: 设置失败 pos=\(e1.rawValue) size=\(e2.rawValue)")
            return false
        }
        return true
    }

    /// 窗口落在哪块屏幕上（取交集最大的那块）
    private static func screen(for windowFrame: NSRect) -> NSScreen {
        var best = NSScreen.main ?? NSScreen.screens[0]
        var bestArea: CGFloat = -1
        for s in NSScreen.screens {
            let inter = s.frame.intersection(windowFrame)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea {
                bestArea = area
                best = s
            }
        }
        return best
    }
}
