import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var shortcuts: ShortcutCenter!
    private var dragSnap: DragSnapController!
    private var voice: VoiceController!
    private var meeting: MeetingRecorder?
    private var clipWatcher: ClipWatcher?

    /// 循环吸附的记忆：(方向, 第几个, 时间)。1.5 秒内连按同一方向才继续循环
    private var lastCycle: (dir: String, index: Int, time: TimeInterval)?

    /// 窗口吸附修饰键：⌃⌥（三键好按；Rectangle 未运行，键位不冲突）
    private static let snapFlags: CGEventFlags = [.maskControl, .maskAlternate]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动分隔标记：smoke.sh 靠它切出"本次启动"的日志，
        // 否则历史记录会被误当成当前状态
        Log.write("===== 启动 =====")
        // 剪贴板历史能力已移除（2026-11-19 owner 决定）：
        // 原生 ⌘C/⌘V 保留的表示比任何中间层都全，中间层只能做它的降级仿制品。
        panel = PanelController()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        Log.write("statusItem 创建：item=\(statusItem != nil) button=\(statusItem.button != nil)")
        // 记住菜单位置，避免每次启动都漂到别处
        statusItem.autosaveName = "com.pp.hub.status"

        if let button = statusItem.button {
            // 用文字而不是图标：18pt 的图形在密集的菜单栏里认不出来，
            // 而 "pp" 两个字一眼就能定位
            button.title = "pp"
            button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            button.toolTip = "pp-hub（左键唤出面板，右键菜单）"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let b = self.statusItem.button
            Log.write("statusItem 延时检查：isVisible=\(self.statusItem.isVisible) " +
                      "buttonFrame=\(b?.frame.debugDescription ?? "nil") " +
                      "window=\(b?.window?.frame.debugDescription ?? "nil") " +
                      "onScreen=\(b?.window?.isVisible ?? false)")
        }

        AppIndex.load()

        setUpVoice()
        setUpShortcuts()
        installEditMenu()
        startClipboardWatcher()

        if !LoginItem.isEnabled {
            _ = LoginItem.enable()
        }
        Log.write("登录项 = \(LoginItem.isEnabled ? "已开启" : "未开启")")
        let access = FilesAccess.status().map { "\($0.0)=\($0.1 ? "可读" : "被拒")" }.joined(separator: " ")
        Log.write("文件访问：\(access)")

        Log.write("辅助功能权限 = \(Permissions.hasAccessibility ? "已授权" : "未授权")")
        Log.write("启动完成（不含剪贴板历史）：应用索引 + 窗口吸附 + 语音听写")
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts?.stop()
        dragSnap?.stop()
    }

    // MARK: - 快捷键

    // MARK: - 语音听写

    private func setUpVoice() {
        voice = VoiceController()
        voice.onStateChange = { [weak self] state in
            guard let self, let button = self.statusItem?.button else { return }
            switch state {
            case .recording: button.title = "pp ●"
            case .preparing: button.title = "pp …"
            case .finishing: button.title = "pp …"
            case .idle: button.title = "pp"
            }
            // 会议在记时，标题以会议为准
            if self.meeting?.isRunning == true { button.title = "pp ⏺" }
        }
        voice.onFinalText = { text in
            // 听写结果直接上屏，不再入历史库（历史库已随剪贴板能力下线）
            Log.write("voice: 上屏 \(text.count) 字")
        }
        voice.start()   // 预热：把识别会话先建好，第一次听写不用等模型初始化
    }

    private func setUpShortcuts() {
        shortcuts = ShortcutCenter()

        // 唤出面板：⌥Space（Alfred 已卸载，接管它的默认键位）
        // 会议记录：⌃⌥M 开始/结束（长时录音，不上屏、不润色）
        // 剪贴板历史：⌃⌥V（不抢占 ⌘V —— 那个是系统的，改掉会让人抓狂）
        shortcuts.add(.init(keyCode: KeyCode.v,
                            flags: [.maskControl, .maskAlternate],
                            label: "剪贴板历史 ⌃⌥V") { [weak self] in
            self?.panel.toggle(.clipboard)
        })

        shortcuts.add(.init(keyCode: KeyCode.m,
                            flags: [.maskControl, .maskAlternate],
                            label: "会议记录 ⌃⌥M") { [weak self] in
            self?.toggleMeeting()
        })

        shortcuts.add(.init(keyCode: KeyCode.space,
                            flags: [.maskAlternate],
                            label: "唤出面板 ⌥Space") { [weak self] in
            self?.panel.toggle()
        })

        // 旧键位保留：并行期养成的肌肉记忆，改起来要一个月，不如两个都留着
        shortcuts.add(.init(keyCode: KeyCode.space,
                            flags: [.maskAlternate, .maskCommand],
                            label: "唤出面板 ⌥⌘Space") { [weak self] in
            self?.panel.toggle()
        })

        // 左/右：连按在 ½ → ⅔ → ⅓ 之间循环（Rectangle 的手感）
        shortcuts.add(.init(keyCode: KeyCode.leftArrow, flags: Self.snapFlags, label: "左循环") { [weak self] in
            self?.cycleSnap("left")
        })
        shortcuts.add(.init(keyCode: KeyCode.rightArrow, flags: Self.snapFlags, label: "右循环") { [weak self] in
            self?.cycleSnap("right")
        })

        // 其余布局：一键直达
        let snaps: [(Int64, SnapLayout)] = [
            (KeyCode.upArrow, .topHalf),
            (KeyCode.downArrow, .bottomHalf),
            (KeyCode.u, .topLeft),
            (KeyCode.i, .topRight),
            (KeyCode.j, .bottomLeft),
            (KeyCode.k, .bottomRight),
            (KeyCode.returnKey, .maximize),
        ]
        for (code, layout) in snaps {
            shortcuts.add(.init(keyCode: code, flags: Self.snapFlags, label: layout.title) {
                Log.write("snap: 触发 \(layout.title)")
                SnapManager.apply(layout)
            })
        }

        // 跨显示器：⌃⌥[ / ⌃⌥]（三键，比四键好按）
        shortcuts.add(.init(keyCode: KeyCode.bracketLeft, flags: Self.snapFlags, label: "上一个显示器") {
            Log.write("snap: 移到上一个显示器")
            SnapManager.moveToNextDisplay(step: -1)
        })
        shortcuts.add(.init(keyCode: KeyCode.bracketRight, flags: Self.snapFlags, label: "下一个显示器") {
            Log.write("snap: 移到下一个显示器")
            SnapManager.moveToNextDisplay(step: 1)
        })

        shortcuts.onModifierTap = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // 麦克风只有一只：会议在记时不开听写
                if self.meeting?.isRunning == true {
                    Log.write("voice: 会议记录中，听写不可用")
                    return
                }
                self.voice.toggle()
            }
        }

        dragSnap = DragSnapController()
        dragSnap.start()

        if !shortcuts.start() {
            Permissions.promptAccessibility()
            Log.write("快捷键未启动，已请求辅助功能授权；授权后从菜单重启")
        }
    }

    /// ½ → ⅔ → ⅓ 循环
    private func cycleSnap(_ dir: String) {
        let seq: [SnapLayout] = dir == "left"
            ? [.leftHalf, .leftTwoThirds, .leftThird]
            : [.rightHalf, .rightTwoThirds, .rightThird]
        let now = CACurrentMediaTime()
        var index = 0
        if let last = lastCycle, last.dir == dir, now - last.time < 1.5 {
            index = (last.index + 1) % seq.count
        }
        lastCycle = (dir, index, now)
        let layout = seq[index]
        Log.write("snap: \(layout.title)（循环 \(index + 1)/3）")
        SnapManager.apply(layout)
    }

    private func restartShortcuts() {
        shortcuts.onModifierTap = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // 麦克风只有一只：会议在记时不开听写
                if self.meeting?.isRunning == true {
                    Log.write("voice: 会议记录中，听写不可用")
                    return
                }
                self.voice.toggle()
            }
        }

        dragSnap = DragSnapController()
        dragSnap.start()

        if !shortcuts.start() {
            Permissions.promptAccessibility()
        }
    }

    // MARK: - 菜单栏交互

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            panel.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(
            title: Permissions.hasAccessibility ? "辅助功能：已授权" : "辅助功能：未授权（点此去设置）",
            action: Permissions.hasAccessibility ? nil : #selector(openA11y),
            keyEquivalent: "")
        status.target = self
        menu.addItem(status)

        let shortcutState = NSMenuItem(
            title: shortcuts?.isRunning == true ? "快捷键：运行中" : "快捷键：未启动",
            action: nil,
            keyEquivalent: "")
        menu.addItem(shortcutState)

        menu.addItem(.separator())

        let clipItem = NSMenuItem(title: "剪贴板历史  ⌃⌥V", action: #selector(openClipboardAction), keyEquivalent: "")
        clipItem.target = self
        menu.addItem(clipItem)

        let clipClear = NSMenuItem(title: "清空历史（保留置顶）", action: #selector(clearClipboardAction), keyEquivalent: "")
        clipClear.target = self
        menu.addItem(clipClear)

        if ShellApps.QSpace.isRunning || NSWorkspace.shared.urlForApplication(withBundleIdentifier: ShellApps.QSpace.bundleID) != nil {
            let qsMenu = NSMenu()
            for (title, path) in ShellApps.favoriteDirs {
                let mi = NSMenuItem(title: title, action: #selector(openInQSpaceAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = path
                qsMenu.addItem(mi)
            }
            qsMenu.addItem(.separator())
            let cur = NSMenuItem(title: "从 QSpace 当前目录起跳", action: #selector(qspaceCurrentAction), keyEquivalent: "")
            cur.target = self
            qsMenu.addItem(cur)

            let qsRoot = NSMenuItem(title: "在 QSpace 打开", action: nil, keyEquivalent: "")
            qsRoot.submenu = qsMenu
            menu.addItem(qsRoot)
        }

        let meetingTitle: String
        if let m = meeting, m.isRunning {
            let mins = Int(m.elapsed) / 60
            let secs = Int(m.elapsed) % 60
            meetingTitle = "结束会议记录（\(mins) 分 \(secs) 秒 / \(m.segmentCount) 段）  ⌃⌥M"
        } else {
            meetingTitle = "开始会议记录  ⌃⌥M"
        }
        let meetingItem = NSMenuItem(title: meetingTitle, action: #selector(toggleMeetingAction), keyEquivalent: "")
        meetingItem.target = self
        menu.addItem(meetingItem)

        let denied = FilesAccess.status().filter { !$0.1 }.count
        let accessItem = NSMenuItem(
            title: denied > 0 ? "文件搜索权限：\(denied) 个目录未授权（点此处理）" : "文件搜索权限：已完整",
            action: denied > 0 ? #selector(requestFilesAccessAction) : nil,
            keyEquivalent: "")
        accessItem.target = self
        menu.addItem(accessItem)

        let openMeetingDir = NSMenuItem(title: "打开会议目录", action: #selector(openMeetingDirAction), keyEquivalent: "")
        openMeetingDir.target = self
        menu.addItem(openMeetingDir)

        menu.addItem(.separator())

        let snapMenu = NSMenu()
        for (title, key) in SnapLayout.menuItems {
            let item = NSMenuItem(title: title, action: #selector(applySnap(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            snapMenu.addItem(item)
        }
        let movePrev = NSMenuItem(title: "移到上一个显示器  ⌃⌥[", action: #selector(prevDisplay), keyEquivalent: "")
        movePrev.target = self
        menu.addItem(movePrev)
        let moveNext = NSMenuItem(title: "移到下一个显示器  ⌃⌥]", action: #selector(nextDisplay), keyEquivalent: "")
        moveNext.target = self
        menu.addItem(moveNext)

        let snapRoot = NSMenuItem(title: "窗口布局", action: nil, keyEquivalent: "")
        snapRoot.submenu = snapMenu
        menu.addItem(snapRoot)

        let restart = NSMenuItem(title: "重启快捷键", action: #selector(restartHotkey), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        let openDB = NSMenuItem(title: "打开数据目录", action: #selector(openDataDir), keyEquivalent: "")
        openDB.target = self
        menu.addItem(openDB)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 pp-hub", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // 用完即摘，避免左键也被菜单接管
    }

    // MARK: - URL scheme（pphub://launcher / pphub://clipboard）

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "pphub" else { continue }
            switch url.host {
            case "clipboard": panel.show(.clipboard)
            case "launcher": panel.show(.launcher)
            case "diag-files":
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let kw = comps?.queryItems?.first(where: { $0.name == "kw" })?.value ?? "网易"
                Log.write("url: 文件诊断 kw=\(kw)")
                DispatchQueue.global().async { FileDiag.run(kw) }

            case "grant-files":
                FilesAccess.request()
                Log.write("url: 申请文件访问权限")

            case "search":
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let q = comps?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
                panel.show(.launcher)
                NotificationCenter.default.post(name: .ppHubSearch, object: nil, userInfo: ["q": q])
                Log.write("url: 搜索『\(q)』")

            case "qspace":
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let path = comps?.queryItems?.first(where: { $0.name == "path" })?.value
                ShellApps.QSpace.open(path ?? NSHomeDirectory())
            default: Log.write("url: 未知入口 \(url.absoluteString)")
            }
            Log.write("url: 打开 \(url.host ?? "-")")
        }
    }

    // MARK: - 会议记录

    /// 与听写互斥：两者都要独占麦克风，同时开只会互相抢设备
    private func toggleMeeting() {
        if let m = meeting, m.isRunning {
            Task { @MainActor in
                let summary = await m.stop()
                meeting = nil
                refreshStatusTitle()
                if let s = summary {
                    Log.write("meeting: 完成 \(s.segments) 段 / \(Int(s.seconds)) 秒 → \(s.path)")
                }
            }
            return
        }

        guard voice.state == .idle else {
            Log.write("meeting: 听写进行中，先结束听写再开会")
            return
        }

        let rec = MeetingRecorder(cfg: Config.load())
        meeting = rec
        rec.onSegment = { text in
            Log.write("meeting: 段落 \(text.count) 字")
        }
        Task { @MainActor in
            do {
                let path = try await rec.start()
                Log.write("meeting: 开始 → \(path)")
                refreshStatusTitle()
            } catch {
                Log.write("meeting: 启动失败 \(error)")
                meeting = nil
                refreshStatusTitle()
            }
        }
    }

    /// 状态栏文字是三方状态（听写 / 会议 / 空闲）的合成结果
    private func refreshStatusTitle() {
        guard let button = statusItem?.button else { return }
        if meeting?.isRunning == true {
            button.title = "pp ⏺"
        } else {
            button.title = "pp"
        }
    }

    /// 安装一个"看不见但生效"的编辑菜单。
    /// 菜单栏不显示（LSUIElement 应用没有菜单栏），但 ⌘A/⌘C/⌘V/⌘Z 这些
    /// 标准编辑操作**必须**靠主菜单的快捷键才能派发到输入框——没有它，
    /// 用户会以为"搜索框不支持全选"。
    private func installEditMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 pp-hub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = main
        Log.write("menu: 编辑菜单已安装（⌘A 全选 / ⌘C ⌘V / ⌘Z 撤销）")
    }

    private func startClipboardWatcher() {
        let w = ClipWatcher()
        w.onCapture = { item in
            Log.write("clip: 采集 \(item.kind) \(item.text.prefix(20).replacingOccurrences(of: "\n", with: " "))")
        }
        w.start()
        clipWatcher = w
    }

    @objc private func openInQSpaceAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        ShellApps.QSpace.open(path)
    }

    /// 反向：把 QSpace 正在看的位置读回来，证明这条链路是两个方向都通的
    @objc private func qspaceCurrentAction() {
        guard let path = ShellApps.QSpace.currentPath() else {
            Log.write("qspace: 读不到当前目录（可能没授予自动化权限）")
            return
        }
        Log.write("qspace: 当前目录 = \(path)")
        let alert = NSAlert()
        alert.messageText = "QSpace 当前目录"
        alert.informativeText = path
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func requestFilesAccessAction() {
        FilesAccess.request()
        let report = FilesAccess.status().map { "\($0.0)  \($0.1 ? "✅ 可读" : "❌ 被拒")" }.joined(separator: "\n")
        Log.write("filesaccess: 申请后 \(report.replacingOccurrences(of: "\n", with: " "))")

        let alert = NSAlert()
        alert.messageText = "文件搜索需要「文稿 / 下载 / 桌面」访问权限"
        alert.informativeText = report + "\n\n没有授权时，Spotlight 搜索会安静地少掉一大片结果（不报错，只是搜不到）。\n若刚点过没有弹框，去系统设置 → 隐私与安全性 → 文件与文件夹 里勾选 pp-hub。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { FilesAccess.openSettings() }
    }

    @objc private func openClipboardAction() {
        panel.toggle(.clipboard)
    }

    @objc private func clearClipboardAction() {
        ClipStore.shared.clearAll(keepPinned: true)
        Log.write("clip: 历史已清空（保留置顶）")
    }

    @objc private func toggleMeetingAction() {
        toggleMeeting()
    }

    @objc private func openMeetingDirAction() {
        let dir = (Config.load().meetingDir as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    @objc private func togglePolishAction() {
        voice.togglePolish()
    }

    @objc private func toggleLoginItem() {
        if LoginItem.isEnabled {
            _ = LoginItem.disable()
            Log.write("loginitem: 已关闭开机自启")
        } else {
            _ = LoginItem.enable()
            Log.write("loginitem: 已开启开机自启")
        }
    }

    @objc private func prevDisplay() { SnapManager.moveToNextDisplay(step: -1) }
    @objc private func nextDisplay() { SnapManager.moveToNextDisplay(step: 1) }

    @objc private func applySnap(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        if let layout = SnapLayout.all.first(where: { $0.key == raw }) {
            SnapManager.apply(layout)
        }
    }

    @objc private func openA11y() { Permissions.openAccessibilitySettings() }
    @objc private func restartHotkey() { restartShortcuts() }

    @objc private func openDataDir() {
        NSWorkspace.shared.open(URL(fileURLWithPath: (("~/Library/Application Support/pp-hub" as NSString).expandingTildeInPath)))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
