import AppKit

// 入口必须在 main.swift（顶层代码），而 AppDelegate 已被收敛到主线程隔离，
// 所以这里用 assumeIsolated 声明"我确实在主线程上"——启动阶段不存在并发。
// 自检模式：不起菜单栏，只跑逻辑
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--selftest" {
    exit(SelfTest.run(CommandLine.arguments))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // 只在菜单栏，不占 Dock
    app.run()
}
