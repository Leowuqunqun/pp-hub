import SwiftUI

extension Notification.Name {
    static let ppHubHide = Notification.Name("pphub.hide")
    static let ppHubShown = Notification.Name("pphub.shown")
    static let ppClipShown = Notification.Name("pphub.clipShown")
    /// 外部注入查询（pphub://search?q=…），也用于自动化验证
    static let ppHubSearch = Notification.Name("pphub.search")
}

/// 面板里的一行：应用（启动）或文件（打开）
/// 剪贴板历史已下线（2026-11-19），所以这里只剩"找东西并打开"一件事
enum PanelItem: Identifiable {
    case app(AppIndex.App)
    case file(FileSearch.Hit)

    var id: String {
        switch self {
        case .app(let a): return "app:\(a.path.path)"
        case .file(let f): return "file:\(f.path)"
        }
    }
}

/// 面板内容：搜索框 + 结果列表 + 键盘操作
struct PanelRoot: View {
    @State private var query = ""
    @State private var results: [PanelItem] = []
    @State private var selection = 0
    @State private var count = -1
    @FocusState private var focused: Bool
    @State private var debounce: DispatchWorkItem?
    @State private var fileHits: [FileSearch.Hit] = []
    /// 每次搜索递增；异步文件结果回来时若代际已变，直接丢弃
    @State private var generation = 0
    /// 按类别分组展示（应用在前、文件在后）；`results` 仍是扁平顺序，
    /// 键盘选择用扁平下标，视觉上用分组——两套视图共享同一个 selection，不会打架
    @State private var sections: [ResultSection] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
            footer
        }
        .frame(width: 640, height: 420, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .ppHubShown)) { _ in
            query = ""
            reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { focused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ppHubSearch)) { note in
            guard let q = note.userInfo?["q"] as? String else { return }
            // 只改 query，交给 onChange 触发搜索；两者都调会打两遍（并重复跑 mdfind）
            if query == q { runSearch(q) } else { query = q }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { focused = true }
        }
        .onExitCommand { NotificationCenter.default.post(name: .ppHubHide, object: nil) }
    }

    // MARK: - 区段

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索：应用、文件…（拼音首字母也行）", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($focused)
                .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
                .onKeyPress(.downArrow) {
                    if IMEState.isComposing { return .ignored }
                    move(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    if IMEState.isComposing { return .ignored }
                    move(-1)
                    return .handled
                }
                .onKeyPress(.return) {
                    // 组词中的回车属于输入法，不能拿去"打开"
                    if IMEState.isComposing { return .ignored }
                    commit(selection)
                    return .handled
                }
                .onKeyPress(phases: .down) { (press: KeyPress) -> KeyPress.Result in
                    if IMEState.isComposing { return .ignored }
                    // ⌘A 兜底：nonactivating 面板下菜单快捷键的派发路径不确定，直接调
                    if press.modifiers == .command,
                       let scalar = press.key.character.unicodeScalars.first,
                       Character(scalar) == "a",
                       let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.selectAll(nil)
                        Log.write("key: ⌘A 全选输入框（\(editor.string.count) 字）")
                        return .handled
                    }
                    // ⌘↩ = 交给 QSpace 打开（壳化唤起：不重造文件管理器）
                    if press.key == .return, press.modifiers == .command {
                        openInQSpace(selection)
                        return .handled
                    }
                    return .ignored
                }
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var content: some View {
        Group {
            if results.isEmpty {
                VStack(spacing: 8) {
                    Text(query.isEmpty ? "输入点什么" : "没有匹配")
                        .font(.system(size: 13, weight: .medium))
                    Text(query.isEmpty ? "搜应用、搜文件；拼音首字母也行（如 wx）" : "试试应用名、文件名，或拼音首字母（如 wx）")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(Array(sections.enumerated()), id: \.element.id) { si, section in
                                SwiftUI.Section {
                                    ForEach(Array(section.items.enumerated()), id: \.element.id) { i, item in
                                        rowView(item, index: baseIndex(si) + i)
                                            .id(item.id)
                                    }
                                } header: {
                                    sectionHeader(section)
                                }
                            }
                        }
                    }
                    .onChange(of: selection) { _, newValue in
                        if newValue >= 0 && newValue < results.count {
                            withAnimation(.linear(duration: 0.08)) {
                                proxy.scrollTo(results[newValue].id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 第 si 组的第一行在扁平列表里的下标（与键盘选择共用同一套换算）
    private func baseIndex(_ si: Int) -> Int {
        ResultCompose.index(in: sections, section: si, row: 0)
    }

    private func sectionHeader(_ section: ResultSection) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(section.items.count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func rowView(_ item: PanelItem, index: Int) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .app(let app):
                Image(nsImage: AppIndex.icon(for: app))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(app.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 8)

            case .file(let hit):
                Image(nsImage: fileIcon(hit))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(hit.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(shortPath(hit.path))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(index == selection ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { commit(index) }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            keyHint("↑↓", "选择")
            keyHint("↩", "打开")
            keyHint("⌘↩", "QSpace 打开")
            keyHint("按文件名搜", "也支持拼音")
            keyHint("⌘⌥P", "置顶")
            Spacer()
            Text("M2")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: - 行为

    private func scheduleSearch(_ kw: String) {
        debounce?.cancel()
        let work = DispatchWorkItem { runSearch(kw) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)   // 60ms debounce
    }

    private func runSearch(_ kw: String) {
        let trimmed = kw.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let gen = generation
        fileHits = []
        fileCache.removeAll()
        apply(trimmed, keepSelection: false)
        Log.write("panel: 搜索『\(trimmed)』→ 应用 \(count) 个，等文件…")

        guard !trimmed.isEmpty else { return }

        // 文件搜索是异步的：先出应用，文件结果到了再补进列表
        FileSearch.search(trimmed, limit: 8) { hits in
            guard gen == generation else {
                Log.write("panel: 丢弃过期文件结果（gen \(gen) ≠ \(generation)）")
                return
            }
            fileHits = hits
            apply(trimmed, keepSelection: true)
        }
    }

    /// 合成列表：应用 → 文件（分组展示，但扁平顺序保持一致）
    private func apply(_ kw: String, keepSelection: Bool) {
        // 应用排前面：输 "wx" 时你多半想开微信，而不是找同名文件
        let apps = kw.isEmpty ? [] : AppIndex.search(kw, limit: 6).map { PanelItem.app($0) }
        let files = fileHits.map { PanelItem.file($0) }
        let items = apps + files

        sections = ResultCompose.sections(apps: apps, files: files)

        let previous = selection
        results = items
        selection = items.isEmpty ? -1 : (keepSelection ? min(max(0, previous), items.count - 1) : 0)
        count = items.count
        if items.isEmpty { sections = [] }
        Log.write("panel: 结果 应用 \(apps.count) / 文件 \(files.count)（组 \(sections.map { $0.title }.joined(separator: "+"))）")
    }

    private func reload() {
        runSearch(query)
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + delta), results.count - 1)
    }

    private func commit(_ index: Int) {
        guard index >= 0, index < results.count else { return }
        switch results[index] {
        case .app(let app):
            NotificationCenter.default.post(name: .ppHubHide, object: nil)
            NSWorkspace.shared.openApplication(at: app.path, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                if let err { Log.write("panel: 启动 \(app.name) 失败 \(err.localizedDescription)") }
            }

        case .file(let hit):
            NotificationCenter.default.post(name: .ppHubHide, object: nil)
            let url = URL(fileURLWithPath: hit.path)
            if hit.isDirectory {
                NSWorkspace.shared.open(url)          // 目录交给 Finder
            } else {
                NSWorkspace.shared.open(url)          // 文件用默认应用打开
            }

        }
    }

    /// 把选中的文件/目录交给 QSpace；应用索引（App）没有"所在目录"语义，直接忽略
    private func openInQSpace(_ index: Int) {
        guard index >= 0, index < results.count else { return }
        guard case .file(let hit) = results[index] else {
            Log.write("qspace: 这条不是文件，忽略")
            return
        }
        NotificationCenter.default.post(name: .ppHubHide, object: nil)
        ShellApps.QSpace.open(hit.path)
    }

    @State private var fileCache: [String: NSImage] = [:]

    private func fileIcon(_ hit: FileSearch.Hit) -> NSImage {
        if let cached = fileCache[hit.path] { return cached }
        let img = NSWorkspace.shared.icon(forFile: hit.path)
        fileCache[hit.path] = img
        return img
    }

    /// 路径只留尾部两段，太长的整条被挤没了
    private func shortPath(_ path: String) -> String {
        let comps = path.split(separator: "/")
        if comps.count <= 2 { return path }
        return "…/" + comps.suffix(2).joined(separator: "/")
    }

}
