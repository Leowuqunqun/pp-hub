import AppKit

/// 输入法组词状态。
///
/// 中文输入时，回车是「确认候选词」、方向键是「选候选词」。
/// 我们的 `.onKeyPress` 一旦把这些键吃掉，用户看到的现象就是：
///   - 回车没把字放进输入框，反而打开了列表里那一项
///   - 打中文时按 ↑↓ 候选词跳不过去
/// 所以所有键处理都必须先问一句「现在在组词吗」。
enum IMEState {
    static var isComposing: Bool {
        guard let window = NSApp.keyWindow,
              let editor = window.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }
}
