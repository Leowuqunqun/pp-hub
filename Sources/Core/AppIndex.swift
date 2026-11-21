import AppKit

/// 应用索引：面板里能直接搜到并启动 App（替代 Alfred 的启动器职责）
///
/// 为什么不用 Spotlight（NSMetadataQuery）：mdfind 依赖索引状态，刚装/刚删的应用
/// 会有一段时间搜不到；直接扫目录是确定的，启动时几百毫秒完成，之后全在内存里。
///
/// 命名：macOS 的几个 API（displayName / localizedName / nameKey）**都返回带 .app 的文件名**，
/// 不会给出 Finder 里看到的中文名（实测 26.2）。所以只能靠文件名 + Bundle 里的
/// CFBundleDisplayName 做别名，中文搜索靠拼音兜。
enum AppIndex {

    struct App {
        let name: String              // 文件名去掉 .app
        let path: URL
        let aliases: [String]         // 小写别名：文件名、CFBundleDisplayName、CFBundleName
        let initials: String          // 拼音首字母
        let fullPinyin: String        // 全拼
        let hasCJK: Bool
    }

    private static var apps: [App] = []
    private static var loaded = false
    private static var iconCache: [String: NSImage] = [:]

    static func load(onDone: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let roots = [
                "/Applications",
                "/System/Applications",
                "/System/Applications/Utilities",
                "/Applications/Utilities",
                (("~/Applications" as NSString).expandingTildeInPath),
            ]
            var found: [App] = []
            var seen = Set<String>()

            for root in roots {
                guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
                for file in names where file.hasSuffix(".app") {
                    let full = (root as NSString).appendingPathComponent(file)
                    guard !seen.contains(full) else { continue }
                    seen.insert(full)

                    let url = URL(fileURLWithPath: full)
                    var base = (file as NSString).deletingPathExtension
                    var aliasSet = Set<String>()

                    if let bundle = Bundle(url: url) {
                        if let d = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !d.isEmpty {
                            aliasSet.insert(d.lowercased())
                            if base.isEmpty { base = d }
                        }
                        if let n = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !n.isEmpty {
                            aliasSet.insert(n.lowercased())
                        }
                    }
                    aliasSet.insert(base.lowercased())

                    found.append(App(
                        name: base,
                        path: url,
                        aliases: Array(aliasSet),
                        initials: Pinyin.initials(base),
                        fullPinyin: Pinyin.full(base),
                        hasCJK: base.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                    ))
                }
            }

            found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                apps = found
                loaded = true
                Log.write("appindex: 扫描到 \(found.count) 个应用")
                onDone?()
            }
        }
    }

    /// 打分：精确 > 前缀 > 拼音首字母 > 全拼前缀 > 子串（查询 ≥ 3 字才启用子串，否则噪音太大）
    static func search(_ keyword: String, limit: Int = 6) -> [App] {
        guard loaded else { return [] }
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return [] }
        let py = kw.replacingOccurrences(of: " ", with: "")

        var scored: [(App, Int)] = []
        for app in apps {
            var best = 0
            for alias in app.aliases {
                let s: Int
                if alias == kw { s = 100 }
                else if alias.hasPrefix(kw) { s = 80 }
                else if kw.count >= 3 && alias.contains(kw) { s = 30 }
                else { s = 0 }
                if s > best { best = s }
            }
            if best == 0, app.hasCJK, !py.isEmpty {
                // 拼音只对中文名生效：否则 "al" 会把 Calculator / Calendar 一并捞出来
                if app.initials.hasPrefix(py) { best = 60 }
                else if app.fullPinyin.hasPrefix(py) { best = 40 }
            }
            if best > 0 { scored.append((app, best)) }
        }
        scored.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
        }
        return scored.prefix(limit).map(\.0)
    }

    static func icon(for app: App) -> NSImage {
        if let cached = iconCache[app.path.path] { return cached }
        let img = NSWorkspace.shared.icon(forFile: app.path.path)
        iconCache[app.path.path] = img
        return img
    }
}
