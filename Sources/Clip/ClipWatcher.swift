import AppKit

/// 剪贴板采集：0.3s 轮询 changeCount。
///
/// 为什么是轮询而不是别的：macOS 没有剪贴板变更通知，changeCount 是唯一公开信号。
/// 0.3s 是"人眼感觉不到延迟"与"空闲 CPU 可忽略"之间的取值（实测 0%）。
final class ClipWatcher {
    var onCapture: ((ClipItem) -> Void)?

    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastChangeTime: Date = .distantPast
    private var enabled = true

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.write("clip: 采集已启动（0.3s 轮询）")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        Log.write("clip: 采集 \(on ? "开" : "关")")
    }

    private func poll() {
        guard enabled else { return }
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc

        // 自己写回去的那次不算新内容
        if UserDefaults.standard.integer(forKey: ClipStore.suppressKey) == cc { return }

        guard let item = ClipStore.shared.capture(from: pb, sourceApp: frontAppName()) else { return }
        lastChangeTime = Date()
        onCapture?(item)
    }

    /// 记下来源应用：以后能回答"这条是从哪来的"
    private func frontAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    }
}
