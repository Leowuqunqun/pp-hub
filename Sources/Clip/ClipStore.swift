import AppKit
import CryptoKit

/// 剪贴板历史的一条记录。
///
/// 与 11-19 删掉的那版的关键差别：**采集时保留全部表示**（RTF/HTML/PNG/多文件），
/// 粘贴时整份写回；不做"统一成纯文本"的降级。降级就是上次被否掉的原因。
struct ClipItem: Codable, Identifiable {
    var id: String              // 主载荷的 SHA256，用于去重
    var kind: String            // text / image / file
    var text: String            // 纯文本；图片存 "[图片]"；文件存第一个路径
    var createdAt: TimeInterval
    var pinned: Bool = false
    var blobPath: String?       // 富文本归档(.pb) 或 图片(.png)
    var filePaths: [String] = []// 多文件复制
    var pinyin: String = ""
    var sourceApp: String = ""
}

/// 历史库：JSON 索引 + blobs 目录（不引 SQLite —— 上限 200 条，线性扫描够快且更好排障）
final class ClipStore {
    static let shared = ClipStore()

    private(set) var items: [ClipItem] = []
    private let dir = Config.dir
    private var indexURL: URL { dir.appendingPathComponent("history.json") }
    private var blobsDir: URL { dir.appendingPathComponent("history-blobs", isDirectory: true) }

    /// 自己写回剪贴板时用：避免刚粘出去的内容又被采集一遍
    static let suppressKey = "pphub.clipSuppressCount"

    private init() {
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 读写索引

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = list
        Log.write("clipstore: 载入 \(items.count) 条历史")
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(items) else { return }
        let tmp = indexURL.appendingPathExtension("tmp")
        try? data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(indexURL, withItemAt: tmp)
    }

    // MARK: - 采集

    /// 从剪贴板抓一条。返回 nil 表示"这条不该记"（密码、临时数据、空内容）
    func capture(from pb: NSPasteboard, sourceApp: String = "") -> ClipItem? {
        let types = pb.types ?? []
        // 密码管理器与临时数据：系统里有明确标记，必须尊重
        let concealed = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                         "com.agilebits.onepassword", "com.1password.1password"]
        if types.contains(where: { concealed.contains($0.rawValue) }) { return nil }

        // 1) 文件（可多选）
        if types.contains(.fileURL),
           let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            let paths = urls.map(\.path)
            let item = ClipItem(id: Self.hash(paths.joined(separator: "|")),
                                kind: "file",
                                text: paths.first ?? "",
                                createdAt: Date().timeIntervalSince1970,
                                blobPath: nil,
                                filePaths: paths,
                                sourceApp: sourceApp)
            return insert(item)
        }

        // 2) 图片
        if let t = [NSPasteboard.PasteboardType.png, .tiff].first(where: { types.contains($0) }),
           let data = pb.data(forType: t),
           let png = Self.toPNG(data, isPNG: t == .png) {
            let h = Self.hash(String(data: png, encoding: .isoLatin1) ?? UUID().uuidString)
            let url = blobsDir.appendingPathComponent("\(h).png")
            try? png.write(to: url)
            let item = ClipItem(id: h, kind: "image", text: "[图片]",
                                createdAt: Date().timeIntervalSince1970,
                                blobPath: url.path, sourceApp: sourceApp)
            return insert(item)
        }

        // 3) 文本（带富文本表示就一起存）
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var payload: [String: Data] = [:]
            for t in [NSPasteboard.PasteboardType.rtf, .html, .string] {
                if let d = pb.data(forType: t), !d.isEmpty { payload[t.rawValue] = d }
            }
            var blob: String?
            if payload.count > 1,
               let data = try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0) {
                let h = Self.hash(String(data: data, encoding: .isoLatin1) ?? UUID().uuidString)
                let url = blobsDir.appendingPathComponent("\(h).pb")
                try? data.write(to: url)
                blob = url.path
                let item = ClipItem(id: h, kind: "text", text: s,
                                    createdAt: Date().timeIntervalSince1970,
                                    blobPath: blob,
                                    pinyin: Pinyin.initials(String(s.prefix(40))),
                                    sourceApp: sourceApp)
                return insert(item)
            }
            let item = ClipItem(id: Self.hash(s), kind: "text", text: s,
                                createdAt: Date().timeIntervalSince1970,
                                pinyin: Pinyin.initials(String(s.prefix(40))),
                                sourceApp: sourceApp)
            return insert(item)
        }

        return nil
    }

    /// 去重插入：同内容只留一条，但把它提到最前
    private func insert(_ item: ClipItem) -> ClipItem {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            var old = items.remove(at: idx)
            old.createdAt = item.createdAt
            items.insert(old, at: 0)
            save()
            return old
        }
        items.insert(item, at: 0)
        trim()
        save()
        return item
    }

    private func trim() {
        let max = max(20, Config.load().clipboardMax)
        guard items.count > max else { return }
        let dropped = items.suffix(items.count - max)
        // 被丢弃的图片/归档文件一起删，别留孤儿
        for d in dropped { removeBlob(d) }
        items = Array(items.prefix(max))
    }

    private func removeBlob(_ item: ClipItem) {
        guard item.kind != "file", let path = item.blobPath else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - 操作

    func search(_ kw: String) -> [ClipItem] {
        let k = kw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return items }
        return items.filter {
            $0.text.lowercased().contains(k) || $0.pinyin.lowercased().hasPrefix(k)
        }
    }

    func delete(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        removeBlob(items[idx])
        items.remove(at: idx)
        save()
    }

    func togglePin(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle()
        save()
    }

    func clearAll(keepPinned: Bool = true) {
        let keep = keepPinned ? items.filter(\.pinned) : []
        if !keepPinned { items.forEach(removeBlob) }
        items = keep
        save()
    }

    /// 把一条记录整份写回剪贴板（富文本/图片/多文件都按原样）
    @discardableResult
    func restore(_ item: ClipItem) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case "file":
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) as NSURL }
            guard !urls.isEmpty else { return false }
            pb.writeObjects(urls)

        case "image":
            guard let path = item.blobPath, let img = NSImage(contentsOfFile: path) else { return false }
            pb.writeObjects([img])
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                pb.setData(data, forType: .png)
            }

        default:
            if let path = item.blobPath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let payload = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Data] {
                let pbitem = NSPasteboardItem()
                for (t, d) in payload { pbitem.setData(d, forType: NSPasteboard.PasteboardType(t)) }
                pb.writeObjects([pbitem])
            } else {
                pb.setString(item.text, forType: .string)
            }
        }

        UserDefaults.standard.set(pb.changeCount, forKey: Self.suppressKey)
        return true
    }

    // MARK: - 工具

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func toPNG(_ data: Data, isPNG: Bool) -> Data? {
        if isPNG { return data }
        guard let img = NSImage(data: data),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
