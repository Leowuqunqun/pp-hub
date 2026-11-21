import Foundation

/// 一组同类结果
struct ResultSection: Identifiable {
    let id: String
    let title: String
    let items: [PanelItem]
}

/// 结果分组：视觉上分类，键盘上仍是一条扁平序列。
///
/// 抽成纯函数是有原因的——分组最常见的 bug 是**下标错位**：
/// 视觉上第 2 组第 1 行，扁平下标该是第几？算错就会"选中的是文件、打开的是应用"。
/// 把它做成纯函数后可以自检（`--selftest panel`），不靠肉眼。
enum ResultCompose {

    /// 应用在前、文件在后；空组不出现
    static func sections(apps: [PanelItem], files: [PanelItem]) -> [ResultSection] {
        var out: [ResultSection] = []
        if !apps.isEmpty { out.append(ResultSection(id: "apps", title: "应用", items: apps)) }
        if !files.isEmpty { out.append(ResultSection(id: "files", title: "文件", items: files)) }
        return out
    }

    static func flat(sections: [ResultSection]) -> [PanelItem] {
        sections.flatMap(\.items)
    }

    /// 第 section 组第 row 行的扁平下标
    static func index(in sections: [ResultSection], section: Int, row: Int) -> Int {
        guard section >= 0, section < sections.count,
              row >= 0, row < sections[section].items.count else { return -1 }
        return sections.prefix(section).reduce(0) { $0 + $1.items.count } + row
    }
}
