import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 远程操作入口：通过 `pphub://ctl/...` 让外部程序（脚本、自动化 agent）驱动这台机器。
///
/// 为什么要做进 pp-hub 而不是单独一个命令行工具：
/// macOS 的「辅助功能」授权按**进程身份**发放。命令行工具没有 app 身份，
/// 它发起的按键注入的"责任进程"是调用它的那个程序（比如某个 node 进程），
/// 而那个进程在设置里没有条目，于是永远被拒。
/// pp-hub 本身是应用、已经有授权，把能力放在这里，一次授权就够，也不用维护第二个签名。
///
/// 安全边界：这是"能替你敲键盘"的入口，默认**关闭**。
/// 打开需要同时满足两个条件，缺一不可：
///   1. config.json 里 `ctlEnabled = true`
///   2. URL 带上正确的一次性令牌（config.json 的 `ctlToken`，32 位随机串）
/// 否则任何网页都能用一条 pphub:// 链接在你电脑上打字。这是硬要求，不是可选项。
enum CtlEngine {

    // MARK: - 入口

    static func handle(_ url: URL) {
        let cfg = Config.load()
        guard cfg.ctlEnabled else {
            Log.write("ctl: 已拒绝（功能未启用）")
            return
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let token = comps?.queryItems?.first(where: { $0.name == "token" })?.value ?? ""
        guard !cfg.ctlToken.isEmpty, token == cfg.ctlToken else {
            Log.write("ctl: 已拒绝（令牌不匹配）")
            return
        }
        func arg(_ name: String) -> String? {
            comps?.queryItems?.first(where: { $0.name == name })?.value
        }

        // url.host 是 ctl，动作在 path 里：pphub://ctl/key?...
        let action = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var out = ""
        switch action {
        case "key":
            guard let combo = arg("combo") else { out = "缺 combo"; break }
            out = sendCombo(combo) ? "已发送 \(combo)" : "未知组合键 \(combo)"

        case "type":
            guard let text = arg("text") else { out = "缺 text"; break }
            if arg("slow") == "1" {
                for ch in text {
                    _ = sendText(String(ch))
                    usleep(90_000)
                }
                out = "已慢速输入 \(text.count) 字"
            } else {
                out = sendText(text) ? "已输入 \(text.count) 字" : "输入失败"
            }

        case "click":
            guard let xs = arg("x"), let ys = arg("y"), let x = Double(xs), let y = Double(ys) else {
                out = "缺 x/y"; break
            }
            click(CGPoint(x: x, y: y), right: arg("right") == "1")
            out = "已点击 (\(x),\(y))"

        case "focus":
            guard let name = arg("app") else { out = "缺 app"; break }
            out = focus(name)

        case "ax":
            guard let name = arg("app") else { out = "缺 app"; break }
            let depth = Int(arg("depth") ?? "6") ?? 6
            out = axDump(name, depth: depth)

        case "ax-click":
            guard let name = arg("app"), let label = arg("label") else { out = "缺 app/label"; break }
            out = axClick(name, label: label)

        case "status":
            out = "辅助功能：\(AXIsProcessTrusted() ? "已授权" : "未授权")"

        default:
            out = "未知动作：\(action)"
        }

        // URL 调用没有回传通道，结果落到固定文件 + 日志，调用方读文件拿结果
        let outURL = Config.dir.appendingPathComponent("ctl-last.txt")
        try? out.write(to: outURL, atomically: true, encoding: .utf8)
        Log.write("ctl: \(action) → \(out.prefix(120))")
    }

    // MARK: - 按键

    private static let keyCodes: [String: CGKeyCode] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,
        "r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"equal":24,"9":25,"7":26,
        "minus":27,"8":28,"0":29,"rightbracket":30,"o":31,"u":32,"leftbracket":33,"i":34,"p":35,
        "return":36,"l":37,"j":38,"quote":39,"k":40,"semicolon":41,"backslash":42,"comma":43,
        "slash":44,"n":45,"m":46,"period":47,"tab":48,"space":49,"grave":50,"delete":51,"escape":53,
        "left":123,"right":124,"down":125,"up":126,"home":115,"end":119,"pageup":116,"pagedown":121,
        "forwarddelete":117,"f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,
        "f9":101,"f10":109,"f11":103,"f12":111
    ]

    private static func modifierCode(_ part: String) -> CGKeyCode? {
        switch part {
        case "cmd", "command": return 55
        case "ctrl", "control": return 59
        case "alt", "option": return 58
        case "shift": return 56
        default: return nil
        }
    }

    private static func flag(_ part: String) -> CGEventFlags? {
        switch part {
        case "cmd", "command": return .maskCommand
        case "ctrl", "control": return .maskControl
        case "alt", "option": return .maskAlternate
        case "shift": return .maskShift
        default: return nil
        }
    }

    static func sendCombo(_ spec: String) -> Bool {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last, let code = keyCodes[keyName] else { return false }
        let mods = parts.dropLast()
        var flags: CGEventFlags = []
        for m in mods { if let f = flag(m) { flags.insert(f) } }
        let src = CGEventSource(stateID: .hidSystemState)

        // 显式按下/抬起修饰键：只设 flags 而不发修饰键事件，很多应用（包括自带输入法）不认
        for m in mods {
            if let mc = modifierCode(m), let e = CGEvent(keyboardEventSource: src, virtualKey: mc, keyDown: true) {
                e.flags = flags; e.post(tap: .cghidEventTap); usleep(12_000)
            }
        }
        if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
            down.flags = flags; down.post(tap: .cghidEventTap); usleep(12_000)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
            up.flags = flags; up.post(tap: .cghidEventTap); usleep(12_000)
        }
        for m in mods.reversed() {
            if let mc = modifierCode(m), let e = CGEvent(keyboardEventSource: src, virtualKey: mc, keyDown: false) {
                e.flags = flags; e.post(tap: .cghidEventTap); usleep(12_000)
            }
        }
        return true
    }

    /// 直接注入 Unicode：不受键盘布局影响，中文也能打
    static func sendText(_ text: String) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        guard !units.isEmpty, let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) else { return false }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
        return true
    }

    static func click(_ p: CGPoint, right: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        let button: CGMouseButton = right ? .right : .left
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button)?
            .post(tap: .cghidEventTap)
        usleep(30_000)
        CGEvent(mouseEventSource: src, mouseType: right ? .rightMouseDown : .leftMouseDown,
                mouseCursorPosition: p, mouseButton: button)?.post(tap: .cghidEventTap)
        usleep(20_000)
        CGEvent(mouseEventSource: src, mouseType: right ? .rightMouseUp : .leftMouseUp,
                mouseCursorPosition: p, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    // MARK: - 应用与界面

    private static func runningApp(_ name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            ($0.bundleIdentifier ?? "").lowercased() == name.lowercased()
                || ($0.localizedName ?? "").lowercased() == name.lowercased()
                || ($0.executableURL?.lastPathComponent ?? "").lowercased() == name.lowercased()
        }
    }

    static func focus(_ name: String) -> String {
        guard let app = runningApp(name) else { return "没在运行的：\(name)" }
        app.activate(options: [.activateAllWindows])
        return "已切到 \(app.localizedName ?? name)"
    }

    private static func attr(_ el: AXUIElement, _ key: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success ? v : nil
    }

    private static func label(_ el: AXUIElement) -> String {
        let t = attr(el, kAXTitleAttribute as String) as? String ?? ""
        let d = attr(el, kAXDescriptionAttribute as String) as? String ?? ""
        let v = attr(el, kAXValueAttribute as String) as? String ?? ""
        return [t, d, v].joined(separator: " ")
    }

    static func axDump(_ appName: String, depth: Int) -> String {
        guard AXIsProcessTrusted() else { return "辅助功能未授权" }
        guard let app = runningApp(appName) else { return "没在运行的：\(appName)" }
        var lines: [String] = []
        func walk(_ el: AXUIElement, _ d: Int) {
            let role = attr(el, kAXRoleAttribute as String) as? String ?? "?"
            let name = [attr(el, kAXTitleAttribute as String) as? String ?? "",
                        attr(el, kAXDescriptionAttribute as String) as? String ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " / ")
            var extra = ""
            if let v = attr(el, kAXValueAttribute as String) as? String, !v.isEmpty {
                extra += " value=\"\(v.prefix(40))\""
            }
            if let p = attr(el, kAXPositionAttribute as String) {
                var point = CGPoint.zero
                AXValueGetValue(p as! AXValue, .cgPoint, &point)
                if let s = attr(el, kAXSizeAttribute as String) {
                    var size = CGSize.zero
                    AXValueGetValue(s as! AXValue, .cgSize, &size)
                    extra += " @(\(Int(point.x)),\(Int(point.y))) \(Int(size.width))x\(Int(size.height))"
                }
            }
            lines.append(String(repeating: "  ", count: d) + "\(role)\(name.isEmpty ? "" : " [\(name)]")\(extra)")
            guard d < depth else { return }
            if let kids = attr(el, kAXChildrenAttribute as String) as? [AXUIElement] {
                for k in kids.prefix(60) { walk(k, d + 1) }
            }
        }
        walk(AXUIElementCreateApplication(app.processIdentifier), 0)
        return lines.joined(separator: "\n")
    }

    /// 按文字找元素并按下。
    /// 直接用"包含匹配"会命中噪声——比如找「删除」会先撞上工具栏的「删除线」。
    /// 所以打分排序：标题全等 > 前缀 > 后缀 > 仅包含，且在弹窗(sheet)内的加分。
    static func axClick(_ appName: String, label needle: String) -> String {
        guard AXIsProcessTrusted() else { return "辅助功能未授权" }
        guard let app = runningApp(appName) else { return "没在运行的：\(appName)" }
        let root = AXUIElementCreateApplication(app.processIdentifier)

        var hits: [AXUIElement] = []
        func collect(_ el: AXUIElement, _ d: Int) {
            if hits.count >= 40 { return }
            if label(el).localizedCaseInsensitiveContains(needle) { hits.append(el) }
            guard d < 12, let kids = attr(el, kAXChildrenAttribute as String) as? [AXUIElement] else { return }
            for k in kids {
                collect(k, d + 1)
                if hits.count >= 40 { return }
            }
        }
        collect(root, 0)
        guard !hits.isEmpty else { return "没找到标签含「\(needle)」的元素" }

        func score(_ el: AXUIElement) -> Int {
            let title = attr(el, kAXTitleAttribute as String) as? String ?? ""
            var s = 0
            if title == needle { s += 100 }
            else if title.hasPrefix(needle) { s += 40 }
            else if title.hasSuffix(needle) { s += 60 }
            else { s += 10 }
            if (attr(el, kAXRoleAttribute as String) as? String) == "AXButton" { s += 20 }
            if insideSheet(el) { s += 50 }
            return s
        }
        let best = hits.max { score($0) < score($1) }!

        if AXUIElementPerformAction(best, kAXPressAction as CFString) == .success {
            return "已按下「\(label(best).trimmingCharacters(in: .whitespaces))」"
        }
        if let p = attr(best, kAXPositionAttribute as String), let s = attr(best, kAXSizeAttribute as String) {
            var point = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &point)
            AXValueGetValue(s as! AXValue, .cgSize, &size)
            let center = CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
            click(center, right: false)
            return "已点击「\(label(best).trimmingCharacters(in: .whitespaces))」"
        }
        return "元素不可按下"
    }

    /// 判断元素是否落在 sheet/对话框里：AX 树没有反向指针，用屏幕坐标包含关系推断
    private static func insideSheet(_ el: AXUIElement) -> Bool {
        guard let p = attr(el, kAXPositionAttribute as String), let s = attr(el, kAXSizeAttribute as String) else { return false }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        let center = CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)

        var sheets: [AXUIElement] = []
        let sys = AXUIElementCreateSystemWide()
        func collectSheets(_ el: AXUIElement, _ d: Int) {
            if sheets.count >= 20 { return }
            if (attr(el, kAXRoleAttribute as String) as? String) == "AXSheet" { sheets.append(el) }
            guard d < 10, let kids = attr(el, kAXChildrenAttribute as String) as? [AXUIElement] else { return }
            for k in kids { collectSheets(k, d + 1) }
        }
        collectSheets(sys, 0)
        for sheet in sheets {
            guard let sp = attr(sheet, kAXPositionAttribute as String),
                  let ss = attr(sheet, kAXSizeAttribute as String) else { continue }
            var spos = CGPoint.zero, ssize = CGSize.zero
            AXValueGetValue(sp as! AXValue, .cgPoint, &spos)
            AXValueGetValue(ss as! AXValue, .cgSize, &ssize)
            if CGRect(x: spos.x, y: spos.y, width: ssize.width, height: ssize.height).contains(center) {
                return true
            }
        }
        return false
    }
}
