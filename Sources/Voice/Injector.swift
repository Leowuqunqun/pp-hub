import Cocoa
import ApplicationServices

/// 文本上屏：AX 直插优先，失败退到「剪贴板 + Cmd+V」。
/// 关键设计：**先上屏（原始文本）再精修**——润色是后台任务，用户几乎不用等模型。
enum Injector {

    enum Method: String { case paste, failed }

    /// 一次插入的句柄，用于后续把原文替换成润色稿
    struct Insertion {
        let element: AXUIElement
        let expectedCaret: Int    // 插入后光标应在的位置（AX 的 UTF-16 偏移）
        let len: Int              // 插入的字符数（退格用）
        let text: String
    }

    // MARK: - 焦点与判定

    static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    static func canSetSelectedText(_ el: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    static func isSecureField(_ el: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        if let role = role as? String, role == "AXSecureTextField" { return true }
        return false
    }

    private static func caret(_ el: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        if range.length != 0 { return NSRange(location: range.location, length: range.length) }
        return NSRange(location: range.location, length: 0)
    }

    private static func setCaret(_ el: AXUIElement, _ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }

    private static func value(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    // MARK: - 插入（照 Typeless 的做法：剪贴板 + Cmd+V，不用 AX 写）

    /// AX 只用来**读**光标位置，用于插入后定位和精修前校验；从不写 AX 属性。
    static func insert(_ text: String, restoreClipboard: Bool) -> (Method, Insertion?) {
        guard !text.isEmpty else { return (.failed, nil) }
        let el = focusedElement()
        if let el, isSecureField(el) {
            Log.write("inject: 目标是安全输入框，拒绝写入")
            return (.failed, nil)
        }
        let before = el.flatMap { caret($0) }

        guard pasteboardPaste(text, restore: restoreClipboard) else { return (.failed, nil) }
        usleep(140_000)

        // 读回光标：既用于确认插入是否真的发生，也给精修留下锚点
        var handle: Insertion?
        if let el, let after = caret(el) {
            let delta = after.location - (before?.location ?? after.location)
            let expected = (text as NSString).length
            if delta == expected || before == nil {
                handle = Insertion(element: el, expectedCaret: after.location, len: text.count, text: text)
                Log.write("inject: 光标推进 \(delta) 字（期望 \(expected)），插入已确认")
            } else {
                Log.write("inject: 光标推进 \(delta) 字，与期望 \(expected) 不符（插入可能被拒），不提供精修锚点")
            }
        } else {
            Log.write("inject: 读不到光标位置，插入照常返回，但无法原地精修")
        }
        return (.paste, handle)
    }

    /// 精修：校验光标没动 → 退格删掉原文 → 粘贴润色稿（= Typeless 的 deleteBackward + insertText）
    static func refine(_ ins: Insertion, to newText: String) -> Bool {
        guard newText != ins.text, !newText.isEmpty else { return false }
        guard let current = caret(ins.element) else {
            Log.write("refine: 读不到光标，跳过精修")
            return false
        }
        guard current.location == ins.expectedCaret else {
            Log.write("refine: 光标已移动（现在 \(current.location)，期望 \(ins.expectedCaret)），放弃精修以免覆盖用户输入")
            return false
        }
        backspaces(ins.len)
        usleep(90_000)
        if let mid = caret(ins.element) {
            Log.write("refine: 退格 \(ins.len) 次后光标=\(mid.location)（期望 \(ins.expectedCaret - ins.len)）")
        }
        guard pasteboardPaste(newText, restore: false) else {
            Log.write("refine: 粘贴润色稿失败")
            return false
        }
        usleep(140_000)
        if let after = caret(ins.element) {
            let expected = ins.expectedCaret - ins.len + newText.count
            Log.write("refine: 精修完成 \(ins.text.count)→\(newText.count) 字，光标 \(after.location)（期望 \(expected)）")
            return abs(after.location - expected) <= 1
        }
        return true
    }

    private static func backspaces(_ count: Int) {
        guard count > 0, let src = CGEventSource(stateID: .hidSystemState) else { return }
        let keyCode: CGKeyCode = 51   // Delete/Backspace，与 Typeless 的 deleteBackward 一致
        for _ in 0..<count {
            CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
            usleep(4_000)
        }
    }

    // MARK: - 剪贴板粘贴（Typeless 的做法：TransientType 标记 + Cmd+V + 事后还原）

    private static func pasteboardPaste(_ text: String, restore: Bool) -> Bool {
        let pb = NSPasteboard.general
        let saved = restore ? snapshot(pb) : nil

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Typeless 同款：打上 transient 标记，剪贴板管理器不会把它当历史留存
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        usleep(40_000)
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else {
            Log.write("inject: 无法创建 Cmd+V 事件")
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(12_000)
        up.post(tap: .cghidEventTap)
        usleep(160_000)

        if let saved { restoreSnapshot(saved, to: pb) }
        Log.write("inject: Cmd+V 已发出（还原剪贴板=\(restore)）")
        return true
    }

    private struct Snapshot { let items: [[NSPasteboard.PasteboardType: Data]] }

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot? {
        guard let list = pb.pasteboardItems else { return nil }
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in list {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            items.append(entry)
        }
        return Snapshot(items: items)
    }

    private static func restoreSnapshot(_ snap: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        let objs: [NSPasteboardItem] = snap.items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(objs)
    }
}
