import Foundation

/// 汉字 → 拼音首字母（用系统 CFStringTransform，零依赖）
enum Pinyin {

    /// "旺德快跑" → "wdkp"
    static func initials(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let latin = (mutable as String).lowercased()

        var out = ""
        var buf = ""
        func flush() {
            if let f = buf.first { out.append(f) }
            buf = ""
        }
        for ch in latin {
            if ch.isLetter && ch.isASCII {
                buf.append(ch)
            } else if ch == "'" {
                continue          // 分隔符（西安 xian 之类），不打断音节
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// 全拼（"旺德快跑" → "wangdekuai pao" 去空格 → "wangdekuai pao"），用于更宽松的匹配
    static func full(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return (mutable as String)
            .lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
