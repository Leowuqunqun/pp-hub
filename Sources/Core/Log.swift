import Foundation

/// 极简文件日志：~/Library/Application Support/pp-hub/log.txt
/// 为什么不用 NSLog：`open` 启动的 app 没有终端，os_log 又需要 predicate 才能捞；
/// 排查"权限到底授没授上"这类问题时，一个能 tail 的文件比什么都强。
enum Log {
    private static let queue = DispatchQueue(label: "com.pp.hub.log")
    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pp-hub", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("log.txt")
    }()
    /// 超过 512KB 就截断重来，避免无限增长
    private static let maxBytes = 512 * 1024

    static func write(_ message: String) {
        queue.async {
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "\(ts) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > maxBytes {
                try? "".data(using: .utf8)?.write(to: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
