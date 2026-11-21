import Foundation

/// 文本后处理：规则清洗（必做，零延迟） + 模型润色（可选，失败即降级）
enum Polisher {

    // MARK: - 规则清洗

    /// 修掉 ASR 的机械毛病：中文标点前的空格、中日韩字之间的空格、行首口头语、缺句末标点
    static func quickClean(_ input: String, replacements: [String: String] = [:], keepEndPeriod: Bool = false) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }

        for (from, to) in replacements where !from.isEmpty {
            s = s.replacingOccurrences(of: from, with: to)
        }

        // 中文标点前后的多余空格：，" 。" 之类
        let cjkPunct = "，。、；：？！“”‘’（）《》【】…—～"
        for p in cjkPunct {
            s = s.replacingOccurrences(of: " \(p)", with: String(p))
            s = s.replacingOccurrences(of: "\(p) ", with: String(p))
        }

        // 中日韩字符之间被插入的空格
        let cjkRange = "\u{4E00}-\u{9FFF}\u{3400}-\u{4DBF}\u{3000}-\u{303F}\u{FF00}-\u{FFEF}"
        if let re = try? NSRegularExpression(pattern: "([\(cjkRange)])\\s+([\(cjkRange)])") {
            var prev = ""
            var guardCount = 0
            while prev != s && guardCount < 8 {
                prev = s
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1$2")
                guardCount += 1
            }
        }

        // 只有口语填充词时才删（避免误伤「那个文件」这类真实语义）
        for filler in ["嗯，", "嗯。", "呃，", "呃。", "啊，", "唔，"] {
            if s.hasPrefix(filler) { s.removeFirst(filler.count) }
        }

        // 识别器会给纯数字/英文也补中文句号（"123。"），去掉它——那不是句子
        let hasCJKNow = containsHan(s)
        if !hasCJKNow {
            while let last = s.last, "。，、；：".contains(last) { s.removeLast() }
        }

        if !keepEndPeriod { s = stripTrailingPeriod(s) }

        // 不再自己补句末标点：端侧识别器对短句不补、长句才补，我们补就是越权（实测：
        // "把这个发给他" → 无句号；"…再考虑一下性能问题" → 自带句号）
        return s
    }

    /// 去掉结尾的中文句号（owner 口径：听写结果不要句号；问号/感叹号有语义，保留）
    static func stripTrailingPeriod(_ input: String) -> String {
        var s = input
        while let last = s.last, last == "。" { s.removeLast() }
        return s
    }

    /// 是否含汉字。不能用 `\p{Han}`：ICU 的 Han 含 Script_Extensions，
    /// 会把「。」「、」这类中文标点也算成汉字（实测 "123。" → true，导致去标点失效）
    static func containsHan(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)      // CJK 统一表意文字
            || (0x3400...0x4DBF).contains(scalar.value)   // 扩展 A
            || (0xF900...0xFAFF).contains(scalar.value)   // 兼容表意文字
        }
    }

    /// 静音/纯标点时视为「没听到有效内容」
    static func isEffectivelyEmpty(_ s: String) -> Bool {
        let junk = CharacterSet(charactersIn: "，。、；：？！“”‘’（）《》【】…—～.,;:?!\"'()[]\n\t ").union(.whitespacesAndNewlines)
        return s.trimmingCharacters(in: junk).isEmpty
    }

    // MARK: - 模型润色

    private static let systemPrompt = """
    你是语音听写的润色器。用户输入是语音识别的原始文本，可能含口误、重复、同音错字、缺标点或错标点。
    规则：
    1. 只输出润色后的最终文本本身。不要解释、不要引号、不要 markdown、不要前缀。
    2. 严格保留原意与信息量，不增删事实，不做扩写或总结。
    3. 去掉口头语（嗯、呃、那个、就是说）与无意义重复。
    4. 修正标点与断句；保持原语言（中文 / 英文 / 中英混说时各自保持）。
    5. 数字、专有名词、代码与技术术语优先保留原样。
    6. 若原文已经通顺，原样返回。
    7. 原文结尾没有标点时不要自行补句号；只有原文是完整的长句子才允许保留句号。
    """

    /// 模型对短句擅自补句号时，把句号去回去（原文本来没有）
    private static func stripUnwantedPeriod(original: String, polished: String) -> String {
        let endPunct: Set<Character> = ["。", "，", "、", "；", "：", "！", "？"]
        guard let lastOriginal = original.last, !endPunct.contains(lastOriginal),
              let lastPolished = polished.last, lastPolished == "。" ,
              original.count <= 15 else { return polished }
        var t = polished
        while t.last == "。" { t.removeLast() }
        return t
    }

    /// 返回：润色结果；失败或超时则返回规则清洗后的原文
    static func polish(_ raw: String, cfg: Config, key: String?) async -> (text: String, polished: Bool) {
        let cleaned = quickClean(raw, replacements: cfg.replacements)
        guard cfg.polish, cleaned.count > 1, let key, !key.isEmpty else { return (cleaned, false) }

        let urlStr = cfg.polishBaseURL.hasSuffix("/") ? "\(cfg.polishBaseURL)chat/completions" : "\(cfg.polishBaseURL)/chat/completions"
        guard let url = URL(string: urlStr) else { return (cleaned, false) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = cfg.polishTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": cfg.polishModel,
            "temperature": 0.1,
            "max_tokens": 1200,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": cleaned]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return (cleaned, false) }
        req.httpBody = data

        let t0 = Date()
        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                Log.write("polish: HTTP \(code)，降级为规则清洗")
                return (cleaned, false)
            }
            guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                Log.write("polish: 响应结构异常，降级")
                return (cleaned, false)
            }
            var out = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // 兜底：模型偶尔自带引号/前缀
            if out.hasPrefix("\"") && out.hasSuffix("\"") && out.count > 2 {
                out = String(out.dropFirst().dropLast())
            }
            if out.isEmpty { return (cleaned, false) }
            out = stripUnwantedPeriod(original: cleaned, polished: out)
            out = stripTrailingPeriod(out)   // 模型补的句号同样去掉
            Log.write("polish: 完成 \(ms)ms \(cleaned.count)→\(out.count) 字")
            return (out, true)
        } catch {
            Log.write("polish: 请求失败 \(error.localizedDescription)，降级为规则清洗")
            return (cleaned, false)
        }
    }
}
