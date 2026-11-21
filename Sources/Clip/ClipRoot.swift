import SwiftUI

/// 剪贴板历史面板：翻找回之前复制过的东西
struct ClipRoot: View {
    @State private var query = ""
    @State private var results: [ClipItem] = []
    @State private var selection = 0
    @FocusState private var focused: Bool
    @State private var debounce: DispatchWorkItem?

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
        .onReceive(NotificationCenter.default.publisher(for: .ppClipShown)) { _ in
            query = ""
            reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { focused = true }
        }
        .onExitCommand { NotificationCenter.default.post(name: .ppHubHide, object: nil) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索历史…（中文关键词或拼音首字母）", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($focused)
                .onChange(of: query) { _, v in schedule(v) }
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
                    if IMEState.isComposing { return .ignored }
                    paste(selection)
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
                    // ⌘1–9 快速粘贴、⌘D 删除、⌘⌥P 置顶
                    if press.modifiers == EventModifiers.command,
                       let scalar = press.key.character.unicodeScalars.first {
                        let digit = Int(scalar.value)
                        if digit >= 1, digit <= 9 {
                            paste(digit - 1)
                            return KeyPress.Result.handled
                        }
                    }
                    if press.key == KeyEquivalent("d"), press.modifiers.contains(.command) {
                        deleteSelected()
                        return KeyPress.Result.handled
                    }
                    if press.key == KeyEquivalent("p"),
                       press.modifiers.contains(.command), press.modifiers.contains(.option) {
                        pinSelected()
                        return KeyPress.Result.handled
                    }
                    return KeyPress.Result.ignored
                }
            Text("\(results.count)")
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
                    Text(query.isEmpty ? "还没有历史" : "没有匹配")
                        .font(.system(size: 13, weight: .medium))
                    Text(query.isEmpty ? "复制任何东西，它会出现在这里" : "试试中文关键词或拼音首字母")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                row(item, index: i).id(item.id)
                            }
                        }
                    }
                    .onChange(of: selection) { _, v in
                        guard v >= 0, v < results.count else { return }
                        withAnimation(.linear(duration: 0.08)) {
                            proxy.scrollTo(results[v].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: ClipItem, index: Int) -> some View {
        HStack(spacing: 10) {
            if item.kind == "image",
               let path = item.blobPath, let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: item.kind == "file" ? "doc" : "text.alignleft")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(preview(item))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.sourceApp.isEmpty {
                    Text(item.sourceApp)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange)
            }
            Text(relativeTime(item.createdAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(index == selection ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { paste(index) }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "选择")
            hint("↩", "粘贴")
            hint("⌘1–9", "快贴")
            hint("⌘D", "删除")
            hint("⌘⌥P", "置顶")
            Spacer()
            Text("历史 \(results.count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: - 行为

    private func schedule(_ v: String) {
        debounce?.cancel()
        let work = DispatchWorkItem { results = ClipStore.shared.search(v); selection = results.isEmpty ? -1 : 0 }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func reload() {
        results = ClipStore.shared.search(query)
        selection = results.isEmpty ? -1 : 0
    }

    private func move(_ d: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + d), results.count - 1)
    }

    private func paste(_ index: Int) {
        guard index >= 0, index < results.count else { return }
        let item = results[index]
        guard ClipStore.shared.restore(item) else {
            Log.write("clip: 还原失败 \(item.kind)/\(item.id.prefix(8))")
            return
        }
        NotificationCenter.default.post(name: .ppHubHide, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Self.sendCommandV() }
        Log.write("clip: 已粘贴 \(item.kind) \(index + 1)")
    }

    private func deleteSelected() {
        guard selection >= 0, selection < results.count else { return }
        ClipStore.shared.delete(id: results[selection].id)
        reload()
    }

    private func pinSelected() {
        guard selection >= 0, selection < results.count else { return }
        ClipStore.shared.togglePin(id: results[selection].id)
        reload()
    }

    private func preview(_ item: ClipItem) -> String {
        switch item.kind {
        case "image": return "[图片]"
        case "file":
            return item.filePaths.count > 1
                ? "\(item.filePaths[0]) 等 \(item.filePaths.count) 个文件"
                : item.filePaths.first ?? item.text
        default:
            return item.text.replacingOccurrences(of: "\n", with: " ⏎ ")
        }
    }

    private func relativeTime(_ ts: TimeInterval) -> String {
        let s = -Date(timeIntervalSince1970: ts).timeIntervalSinceNow
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分" }
        if s < 86400 { return "\(Int(s / 3600)) 时" }
        let f = DateFormatter(); f.dateFormat = "M/d"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let k: CGKeyCode = 9
        guard let d = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: true),
              let u = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: false) else { return }
        d.flags = .maskCommand; u.flags = .maskCommand
        d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
    }
}
