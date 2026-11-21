import Foundation

/// 文件搜索：走 Spotlight（mdfind）
///
/// 为什么不自建索引：全盘扫描做不到"输一个字就有结果"，而 mdfind 是系统已经在维护的索引，
/// 复用它比自己建库快且全。代价是"索引状态不可控"——刚下载还没被索引的文件搜不到，
/// 所以每条结果只是**候选**，不是真相。
///
/// 三条纪律：
///  1. 绝不阻塞主线程：全部在 utility 队列，UI 先显示应用与剪贴板，文件结果后到
///  2. 迟到结果必须作废：每轮搜索带 generation，旧代结果回来直接丢弃
///  3. 结果要收敛：超量就截断并 kill 进程，不让 mdfind 跑完全盘
enum FileSearch {

    struct Hit {
        let path: String
        let name: String
        let isDirectory: Bool
    }

    private static let queue = DispatchQueue(label: "com.pp.hub.filesearch", qos: .utility)
    /// 缓存必须带时间：文件夹/文件会被改名、移动，缓存太久会给出已失效的路径
    private static var cache: [String: (hits: [Hit], at: Date)] = [:]
    private static let cacheTTL: TimeInterval = 120
    private static var running: Process?

    /// 不该出现在启动器里的路径：系统区、隐藏目录、依赖目录
    private static let banned = [
        "/System/", "/private/", "/Library/", "/usr/", "/bin/", "/sbin/", "/dev/",
        "/.Spotlight-V100/", "/node_modules/", "/.git/", "/.Trash/", "/dev/null",
    ]

    private static var home: String { ("~" as NSString).expandingTildeInPath }

    static func search(_ keyword: String, limit: Int = 8, completion: @escaping ([Hit]) -> Void) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kw.count >= 1 else { completion([]); return }

        if let entry = cache[kw], Date().timeIntervalSince(entry.at) < cacheTTL {
            completion(Array(entry.hits.prefix(limit)))
            return
        }

        queue.async {
            var result = runAll(kw, limit: limit, budget: 1.5)
            // 只有"超时且一条都没有"才值得重试；已经拿到结果的超时不算失败
            if result.timedOut && result.hits.isEmpty {
                // 首次搜索常赶上 mdfind 冷启动：1500ms 不够，放宽再来一次。
                // 绝不能把这次的空结果当结论 —— 那会让"搜不到"永久化。
                Log.write("filesearch: 『\(kw)』1.5s 内没拿到任何结果，放宽到 3.5s 重试")
                result = runAll(kw, limit: limit, budget: 3.5)
            }
            let hits = result.hits
            DispatchQueue.main.async {
                // 只缓存有结果的查询：空结果可能是超时/索引未建，不是事实
                if !hits.isEmpty {
                    cache[kw] = (hits, Date())
                    if cache.count > 60 { cache.removeAll() }
                }
                Log.write("filesearch: 『\(kw)』命中 \(hits.count)")
                completion(Array(hits.prefix(limit)))
            }
        }
    }

    // MARK: - 执行

    /// 先搜家目录，不够再全盘兜底。
    /// 为什么分两步：mdfind 按索引顺序吐结果，全盘查询前面几十条几乎都是
    /// /System/Library 里的文件；把它们过滤掉之后就没剩几条了。
    /// 家目录优先既快又准，兜底那步才是"实在没有"时的广撒网。
    private static func runAll(_ kw: String, limit: Int, budget: TimeInterval) -> (hits: [Hit], timedOut: Bool) {
        let first = runProcess(kw, onlyIn: home, acceptedLimit: limit, budget: budget)
        var homeResults = first.paths
        if homeResults.count >= limit { return (finish(homeResults), first.timedOut) }

        let broad = runProcess(kw, onlyIn: nil, acceptedLimit: limit, budget: budget)
        var seen = Set(homeResults)
        for p in broad.paths where !seen.contains(p) {
            seen.insert(p)
            homeResults.append(p)
            if homeResults.count >= limit { break }
        }
        return (finish(homeResults), first.timedOut || broad.timedOut)
    }

    /// 返回 (路径, 是否超时)。超时这条信息必须往上带：
    /// 超时和"真没有"在调用方看来一样空，但处理方式相反
    private static func runProcess(_ kw: String, onlyIn: String?, acceptedLimit: Int,
                                   budget: TimeInterval) -> (paths: [String], timedOut: Bool) {
        let safe = kw.replacingOccurrences(of: "\"", with: "")
        guard !safe.isEmpty else { return ([], false) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        var args: [String] = []
        if let onlyIn { args += ["-onlyin", onlyIn] }
        args.append("kMDItemFSName == \"*\(safe)*\"cd")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        do { try p.run() } catch {
            Log.write("filesearch: mdfind 启动失败 \(error.localizedDescription)")
            return ([], false)
        }

        let handle = pipe.fileHandleForReading
        var buffer = Data()
        var accepted: [String] = []
        var rawLines = 0
        let deadline = Date().addingTimeInterval(budget)   // 超过就收摊，别让一次搜索拖住后续输入

        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                rawLines += 1
                guard let path = String(data: lineData, encoding: .utf8), !path.isEmpty else { continue }
                if isUsable(path) {
                    accepted.append(path)
                    if accepted.count >= acceptedLimit { break }
                }
                if rawLines > 4000 { break }      // 硬上限，防病态查询
            }
            if accepted.count >= acceptedLimit || rawLines > 4000 { break }
        }
        if p.isRunning {
            p.terminate()
            return (accepted, true)          // 还没跑完 → 这是"没搜完"，不是"没有"
        }
        return (accepted, false)
    }

    private static func isUsable(_ path: String) -> Bool {
        if banned.contains(where: { path.contains($0) }) { return false }
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") { return false }
        return true
    }

    private static func finish(_ paths: [String]) -> [Hit] {
        paths.map { path in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return Hit(path: path,
                       name: (path as NSString).lastPathComponent,
                       isDirectory: isDir.boolValue)
        }
        .sorted { a, b in
            let aHome = a.path.hasPrefix(home), bHome = b.path.hasPrefix(home)
            if aHome != bHome { return aHome }
            if a.isDirectory != b.isDirectory { return !a.isDirectory }
            return a.path.count < b.path.count
        }
    }
}
