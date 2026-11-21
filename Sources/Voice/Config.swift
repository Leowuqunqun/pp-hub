import Foundation

/// 用户配置：~/Library/Application Support/pp-hub/config.json（不存在时自动生成默认值）
struct Config: Codable {
    /// 热键："rightOption" | "fn" | "rightCommand"
    var hotkey: String = "rightCommand"
    /// 识别语言列表，第一个为主语言（macOS 26 端侧支持 30 种）
    var locales: [String] = ["zh-CN", "en-US"]
    /// 是否启用模型润色。**默认关闭**：开启后识别文本会发到你配置的接口，属于出网行为，应由用户显式选择
    var polish: Bool = false
    var polishBaseURL: String = "https://tokenhub.tencentmaas.com/v1"
    var polishModel: String = "deepseek-v4-flash-202605"
    var polishTimeout: Double = 6.0
    /// 凭据文件（按 `<KEY>` 行读取 API key，YAML 风格）
    var credentialsPath: String = "~/.dsh/.credentials.yaml"
    /// 固定替换表：识别结果落地前的硬纠正（专名/术语）
    var replacements: [String: String] = [:]
    /// 是否显示悬浮提示
    var hud: Bool = true
    /// 上屏后是否保留剪贴板（剪贴板模式下尽量还原）
    var restoreClipboard: Bool = true
    /// 剪贴板历史上限（条）；0 表示只保留置顶
    var clipboardMax: Int = 200
    /// 会议记录落盘目录
    var meetingDir: String = "~/Documents/pp-hub 会议"
    /// 会议识别会话轮换周期（秒）：长会话不换会涨内存、也会识别漂移
    var meetingRotateSec: Double = 300
    static let dir = URL(fileURLWithPath: ("~/Library/Application Support/pp-hub" as NSString).expandingTildeInPath)
    static let path = dir.appendingPathComponent("config.json")

    /// 逐字段容错解码。
    /// 合成的 Codable 要求 JSON 里**每个键都存在**，所以只要新增一个字段，
    /// 老用户的 config.json 就会整套解码失败并被打回默认值（配置静默丢失）。
    /// 这里改成 decodeIfPresent：加字段不再伤旧配置。
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        hotkey = v(.hotkey, hotkey)
        locales = v(.locales, locales)
        polish = v(.polish, polish)
        polishBaseURL = v(.polishBaseURL, polishBaseURL)
        polishModel = v(.polishModel, polishModel)
        polishTimeout = v(.polishTimeout, polishTimeout)
        credentialsPath = v(.credentialsPath, credentialsPath)
        replacements = v(.replacements, replacements)
        hud = v(.hud, hud)
        restoreClipboard = v(.restoreClipboard, restoreClipboard)
        clipboardMax = v(.clipboardMax, clipboardMax)
        meetingDir = v(.meetingDir, meetingDir)
        meetingRotateSec = v(.meetingRotateSec, meetingRotateSec)
    }

    static func load() -> Config {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: path) else {
            let cfg = Config()
            cfg.save()
            return cfg
        }
        if let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        // 解不出来就别覆盖：先留一份原文件，再写默认值
        let backup = dir.appendingPathComponent("config.json.broken-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.copyItem(at: path, to: backup)
        Log.write("config: 解析失败，原文件已备份到 \(backup.lastPathComponent)")
        let cfg = Config()
        cfg.save()
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Config.path) }
    }
}

/// 从 dsh 凭据文件里取 tokenhub key（不落盘到别处）
enum Credentials {
    static func tokenHubKey(cfg: Config) -> String? {
        let path = (cfg.credentialsPath as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("TENCENT_TOKENHUB_API_KEY:") else { continue }
            var v = line.replacingOccurrences(of: "TENCENT_TOKENHUB_API_KEY:", with: "")
                .trimmingCharacters(in: .whitespaces)
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return v.isEmpty ? nil : v
        }
        return nil
    }
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
