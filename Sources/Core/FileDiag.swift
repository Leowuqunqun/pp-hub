import Foundation

/// 应用内文件搜索诊断：把 CLI 能看到、app 里看不到的差异摊开
enum FileDiag {
    static func run(_ kw: String) {
        let home = NSHomeDirectory()
        Log.write("diag: NSHomeDirectory=\(home)")
        Log.write("diag: HOME env=\(ProcessInfo.processInfo.environment["HOME"] ?? "未设置")")

        let docs = (home as NSString).appendingPathComponent("Documents")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: docs))?.count ?? -1
        Log.write("diag: ~/Documents 可列条目=\(entries)")

        // 原样跑一次 mdfind，把 stdout/stderr/退出码都记下来
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", home, "kMDItemFSName == \"*\(kw)*\"cd"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            Log.write("diag: mdfind 启动失败 \(error)")
            return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n")
        Log.write("diag: mdfind 退出码=\(p.terminationStatus) 输出行=\(lines.count) stderr=\(String(data: errData, encoding: .utf8)?.prefix(200) ?? "-")")
        for l in lines.prefix(5) { Log.write("diag:   \(l)") }

        // 同一个进程里直接看这些路径能不能 stat
        for l in lines.prefix(3) {
            let path = String(l)
            let exists = FileManager.default.fileExists(atPath: path)
            let readable = FileManager.default.isReadableFile(atPath: path)
            Log.write("diag:   存在=\(exists) 可读=\(readable) → \(path)")
        }
    }
}
