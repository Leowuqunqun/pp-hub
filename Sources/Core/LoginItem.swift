import Foundation
import ServiceManagement

/// 开机自启
/// 首选 SMAppService（macOS 13+ 的官方 API）；它在开发期目录下可能注册失败，
/// 失败就退回 LaunchAgent —— 宁可多一条兜底，也不要"重启后功能凭空消失"。
enum LoginItem {

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled { return true }
        }
        return FileManager.default.fileExists(atPath: agentPlist.path)
    }

    @discardableResult
    static func enable() -> Bool {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                Log.write("loginitem: SMAppService 注册成功")
                return true
            } catch {
                Log.write("loginitem: SMAppService 失败 \(error.localizedDescription)，退回 LaunchAgent")
            }
        }
        return writeAgent()
    }

    @discardableResult
    static func disable() -> Bool {
        var ok = true
        if #available(macOS 13.0, *) {
            do { try SMAppService.mainApp.unregister() } catch { ok = false }
        }
        try? FileManager.default.removeItem(at: agentPlist)
        _ = runLaunchctl(["bootout", "gui/\(getuid())/com.pp.hub"])   // 兜底卸载
        return ok
    }

    // MARK: - LaunchAgent 兜底

    private static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.pp.hub.plist")
    }

    private static func writeAgent() -> Bool {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": "com.pp.hub",
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        do {
            try FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentPlist)
            _ = runLaunchctl(["bootstrap", "gui/\(getuid())", agentPlist.path])
            Log.write("loginitem: LaunchAgent 已写入 \(agentPlist.path)")
            return true
        } catch {
            Log.write("loginitem: LaunchAgent 写入失败 \(error)")
            return false
        }
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }
}
