import AppKit

/// 壳化唤起（决策 4）：商品类应用不重造，只做"从 pp-hub 把某处交给它"。
///
/// 每加一个应用都必须先实测到**确定可行的唤起契约**，不接受"大概能用"：
/// - QSpace：`open -b <bundleID> <目录>` 实测会让它跳转到该目录；
///   AppleScript `URL of root item` 可读回当前目录（用于验证与反向取上下文）。
enum ShellApps {

    // MARK: - QSpace

    enum QSpace {
        static let bundleID = "com.jinghaoshe.qspace"
        static let name = "QSpace"

        static var isRunning: Bool {
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }

        /// 让 QSpace 打开某个目录。返回 false = 应用不存在
        @discardableResult
        static func open(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                Log.write("qspace: 路径不存在 \(path)")
                return false
            }
            // 文件就交给它所在的目录
            let target = isDir.boolValue ? path : (path as NSString).deletingLastPathComponent

            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                Log.write("qspace: 未安装")
                return false
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: target)], withApplicationAt: url,
                                    configuration: cfg) { _, err in
                if let err { Log.write("qspace: 唤起失败 \(err.localizedDescription)") }
            }
            Log.write("qspace: 打开 \(target)")
            return true
        }

        /// 读回 QSpace 当前窗口目录（需要「自动化」权限，首次会弹一次授权）
        static func currentPath() -> String? {
            let src = """
            tell application "QSpace" to get URL of root item
            """
            guard let script = NSAppleScript(source: src) else { return nil }
            var err: NSDictionary?
            let result = script.executeAndReturnError(&err)
            if let err {
                Log.write("qspace: 读取当前目录失败 \(err[NSAppleScript.errorMessage] ?? err)")
                return nil
            }
            guard var url = result.stringValue, !url.isEmpty else { return nil }
            if url.hasSuffix("/") { url.removeLast() }
            return url.removingPercentEncoding ?? url
        }
    }

    // MARK: - 常用目录

    /// 菜单里给的"一跳就到"的位置
    static var favoriteDirs: [(String, String)] {
        let home = NSHomeDirectory()
        var list: [(String, String)] = [
            ("主目录", home),
            ("下载", "\(home)/Downloads"),
            ("桌面", "\(home)/Desktop"),
            ("文稿", "\(home)/Documents"),
        ]
        // 当前工作的项目目录（存在才加，不硬编码一个可能不存在的路径）
        let pp = "\(home)/pp"
        if FileManager.default.fileExists(atPath: pp) { list.insert(("pp 容器", pp), at: 1) }
        return list.filter { FileManager.default.fileExists(atPath: $0.1) }
    }
}
