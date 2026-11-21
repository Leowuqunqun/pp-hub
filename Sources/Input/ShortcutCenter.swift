import Cocoa
import ApplicationServices

/// 全局快捷键中心：一个 CGEventTap 管所有组合键
/// 为什么合成一个 tap：每个 tap 都要一份辅助功能授权与一份运行循环源，
/// 分开注册既费资源，也更容易在某个 App 面前被系统吞掉。
final class ShortcutCenter {

    struct Binding {
        let keyCode: Int64
        let flags: CGEventFlags          // 必须精确匹配的修饰键集合
        let label: String
        let action: () -> Void
    }

    /// 只关心这四个修饰键，其余（如 maskNonCoalesced）忽略
    private static let relevantFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    private var bindings: [Binding] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastFire: CFTimeInterval = 0

    /// 纯修饰键单击（如轻点右 Command）—— 语音听写的触发手势
    var onModifierTap: (() -> Void)?
    private static let modifierKeyCode: Int64 = 54      // 右 Command
    private var modifierDownAt: CFTimeInterval?
    private var modifierCancelled = false

    var isRunning: Bool { tap != nil }

    func add(_ binding: Binding) { bindings.append(binding) }

    @discardableResult
    func start() -> Bool {
        stop()
        guard AXIsProcessTrusted() else {
            Log.write("shortcut: 缺少辅助功能权限")
            return false
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let center = Unmanaged<ShortcutCenter>.fromOpaque(info).takeUnretainedValue()
                if type == .keyDown {
                    center.handle(event)
                } else if type == .flagsChanged {
                    center.handleFlags(event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: opaque
        ) else {
            Log.write("shortcut: tapCreate 失败（授权后需重启 App）")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        source = src
        Log.write("shortcut: 已监听 \(bindings.count) 个组合键")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// 右 Command 单点：按下记时，抬起时若没被别的按键打断、且够快，就算一次轻点。
    /// 必须先取消掉 ⌘C / ⌘V 这类组合——否则每次复制都会顺带触发听写。
    private func handleFlags(_ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == Self.modifierKeyCode else { return }
        let down = event.flags.contains(.maskCommand)
        if down {
            modifierDownAt = CACurrentMediaTime()
            modifierCancelled = false
        } else if let t0 = modifierDownAt {
            modifierDownAt = nil
            let held = CACurrentMediaTime() - t0
            if !modifierCancelled && held < 0.45 {
                onModifierTap?()
            }
        }
    }

    private func handle(_ event: CGEvent) {
        modifierCancelled = true          // 任何普通按键都把"轻点修饰键"作废
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let pressed = event.flags.intersection(Self.relevantFlags)

        for b in bindings where b.keyCode == code && b.flags == pressed {
            let now = CACurrentMediaTime()
            guard now - lastFire > 0.08 else { return }   // 连发去抖
            lastFire = now
            b.action()
            return
        }
    }
}

/// 键码常量（用名字比裸数字稳）
enum KeyCode {
    static let space: Int64 = 49
    static let leftArrow: Int64 = 123
    static let rightArrow: Int64 = 124
    static let downArrow: Int64 = 125
    static let upArrow: Int64 = 126
    static let returnKey: Int64 = 36
    static let u: Int64 = 32
    static let i: Int64 = 34
    static let j: Int64 = 38
    static let k: Int64 = 40
    static let m: Int64 = 46
    static let v: Int64 = 9
    static let bracketLeft: Int64 = 33
    static let bracketRight: Int64 = 30
}
