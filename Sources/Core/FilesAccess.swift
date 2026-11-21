import AppKit

/// 「文件与文件夹」访问权限的探测与申请。
///
/// 为什么必须管这件事：`mdfind` 只返回**本进程有权访问**的条目。
/// 没有文稿/下载/桌面的授权时，搜索会安静地少一大片结果——
/// 表现为"明明有这个文件，搜不到"，而且没有任何报错。
enum FilesAccess {
    /// 隐私保护目录：TCC 按目录授权，不是按文件
    static let watched = ["~/Documents", "~/Downloads", "~/Desktop"]

    static func probe(_ raw: String) -> Bool {
        let path = (raw as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return true }  // 不存在不算"没权限"
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    /// 返回 (目录, 可读) —— 用于菜单展示与日志
    static func status() -> [(String, Bool)] {
        watched.map { ($0, probe($0)) }
    }

    /// 挨个访问一次：第一次会弹系统授权框（或需要去系统设置里手动开）
    static func request() {
        for dir in watched {
            let path = (dir as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            _ = try? FileManager.default.contentsOfDirectory(atPath: path)
        }
        let report = status().map { "\($0.0)=\($0.1 ? "可读" : "被拒")" }.joined(separator: " ")
        Log.write("filesaccess: \(report)")
    }

    /// 一键跳到系统设置的「文件与文件夹」面板
    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders",
        ]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }
}
