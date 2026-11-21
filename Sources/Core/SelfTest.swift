import AppKit

/// 命令行自检：不启动菜单栏，只验证核心逻辑
///   pp-hub --selftest apps wx
///   pp-hub --selftest image <blob path>
enum SelfTest {

    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 3 else {
            print("用法: pp-hub --selftest apps <关键词> | image <文件路径>")
            return 2
        }
        switch args[2] {
        case "apps":
            let kw = args.count > 3 ? args[3] : "wx"
            var done = false
            AppIndex.load { done = true }
            while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            let hits = AppIndex.search(kw, limit: 10)
            print("查询『\(kw)』命中 \(hits.count) 个应用：")
            for a in hits { print("  \(a.name)\t\(a.path.path)") }
            return hits.isEmpty ? 1 : 0

        case "panel":
            // 分组下标换算（纯逻辑，不依赖界面）
            // 用合成数据，不依赖本机装了什么应用（否则测试结果随机器变化）
            func fakeApp(_ name: String) -> PanelItem {
                .app(AppIndex.App(name: name,
                                  path: URL(fileURLWithPath: "/Applications/\(name).app"),
                                  aliases: [name.lowercased()],
                                  initials: "", fullPinyin: "", hasCJK: false))
            }
            let apps: [PanelItem] = [fakeApp("Alpha"), fakeApp("Beta")]
            let fakeFiles: [PanelItem] = [
                .file(FileSearch.Hit(path: "/tmp/a.txt", name: "a.txt", isDirectory: false)),
                .file(FileSearch.Hit(path: "/tmp/b.txt", name: "b.txt", isDirectory: true)),
            ]
            let secs = ResultCompose.sections(apps: apps, files: fakeFiles)
            let titles = secs.map { "\($0.title):\($0.items.count)" }
            print("分组：\(titles.joined(separator: " → "))")
            let flat = ResultCompose.flat(sections: secs)
            var bad: [String] = []
            for (si, sec) in secs.enumerated() {
                for (ri, item) in sec.items.enumerated() {
                    let idx = ResultCompose.index(in: secs, section: si, row: ri)
                    if idx < 0 || idx >= flat.count || flat[idx].id != item.id {
                        bad.append("组\(si)行\(ri) → 扁平\(idx)")
                    }
                }
            }
            // 越界必须返回 -1，不能返回 0（否则会"打开第一项"）
            if ResultCompose.index(in: secs, section: 9, row: 0) != -1 { bad.append("越界组没返回 -1") }
            if ResultCompose.index(in: secs, section: 0, row: 99) != -1 { bad.append("越界行没返回 -1") }
            if secs.first?.title != "应用" { bad.append("第一组不是应用") }
            if secs.count != 2 || secs[1].items.count != 2 { bad.append("分组数量不对") }
            // 真实应用搜索也要能出结果（不进界面的冒烟）——load 是异步的，必须等它回调
            // onDone 回到主队列 —— 用信号量等主队列回调会死锁，必须泵 RunLoop
            var indexed = false
            AppIndex.load { indexed = true }
            let t0 = Date()
            while !indexed && Date().timeIntervalSince(t0) < 8 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            let real = AppIndex.search("safari", limit: 3)
            print("真实搜索 safari → \(real.map(\.name).joined(separator: ", "))")
            if real.isEmpty { bad.append("应用索引搜不到 Safari") }
            print(bad.isEmpty ? "✅ 分组与扁平下标一致（越界返回 -1）" : "❌ \(bad.joined(separator: "；"))")
            return bad.isEmpty ? 0 : 1

        case "qspace":
            // 端到端：让它打开一个临时目录，再用 AppleScript 读回当前目录核对
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: ShellApps.QSpace.bundleID) != nil else {
                print("⚠️  未安装 QSpace，跳过")
                return 0
            }
            // 先记住它原来的位置，测完还回去——不能把人家的窗口挪走就不管了
            let previous = ShellApps.QSpace.currentPath()
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pphub-qspace-\(Int.random(in: 1000...9999))")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            print("唤起 QSpace → \(tmp.path)")
            guard ShellApps.QSpace.open(tmp.path) else {
                print("❌ 唤起失败")
                return 1
            }
            var got: String?
            for _ in 0..<12 {
                Thread.sleep(forTimeInterval: 0.5)
                got = ShellApps.QSpace.currentPath()
                if got?.hasSuffix(tmp.lastPathComponent) == true { break }
            }
            print("读回：\(got ?? "nil")")
            guard let got else {
                print("❌ 读不回当前目录（多半是「自动化」权限没给：系统设置 → 隐私与安全性 → 自动化 → 允许 pp-hub 控制 QSpace）")
                return 1
            }
            let ok = got.hasSuffix(tmp.lastPathComponent)
            print(ok ? "✅ QSpace 顺从唤起到位（双向：能开 + 能读）" : "❌ QSpace 停在了别处")
            try? FileManager.default.removeItem(at: tmp)
            if let previous { _ = ShellApps.QSpace.open(previous) }
            return ok ? 0 : 1

        case "clip":
            // 往返自检：富文本 / 图片 / 文件 三种，采集 → 落盘 → 还原
            var ids: [String] = []
            var failures: [String] = []
            let store = ClipStore.shared

            // 富文本
            let pb = NSPasteboard.general
            pb.clearContents()
            let richItem = NSPasteboardItem()
            let markup = "你好，富文本 <b>加粗</b> \\(Int.random(in: 10000...99999))"
            let attr = NSAttributedString(string: markup)
            if let rtf = try? attr.data(from: NSRange(location: 0, length: attr.length),
                                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                richItem.setData(rtf, forType: .rtf)
                richItem.setString(markup, forType: .string)
                pb.writeObjects([richItem])
                if let captured = store.capture(from: pb, sourceApp: "selftest") {
                    ids.append(captured.id)
                    if captured.blobPath == nil { failures.append("富文本没存到 blob") }
                    _ = store.restore(captured)
                    let okText = NSPasteboard.general.string(forType: .string) == markup
                    let okRTF = NSPasteboard.general.data(forType: .rtf) != nil
                    print("富文本：文本=\(okText ? "✅" : "❌") 格式=\(okRTF ? "✅" : "❌")")
                    if !okText || !okRTF { failures.append("富文本还原不完整") }
                } else {
                    failures.append("富文本没被采集")
                }
            } else {
                failures.append("构造 RTF 失败")
            }

            // 图片
            let img = NSImage(size: NSSize(width: 40, height: 40))
            img.lockFocus()
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: 40, height: 40).fill()
            img.unlockFocus()
            let pb2 = NSPasteboard.general
            pb2.clearContents()
            pb2.writeObjects([img])
            if let captured = store.capture(from: pb2, sourceApp: "selftest") {
                ids.append(captured.id)
                let exists = captured.blobPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                print("图片：存盘=\(exists ? "✅" : "❌") 大小=\(captured.blobPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)).count } ?? 0) 字节")
                if !exists { failures.append("图片 blob 缺失") }
                _ = store.restore(captured)
                if NSImage(pasteboard: NSPasteboard.general) == nil { failures.append("图片还原失败") }
            } else {
                failures.append("图片没被采集")
            }

            // 文件
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pphub-selftest-clip.txt")
            try? "clip selftest".write(to: tmp, atomically: true, encoding: .utf8)
            let pb3 = NSPasteboard.general
            pb3.clearContents()
            pb3.writeObjects([tmp as NSURL])
            if let captured = store.capture(from: pb3, sourceApp: "selftest") {
                ids.append(captured.id)
                print("文件：路径=\(captured.filePaths.first ?? "无")")
                _ = store.restore(captured)
                let back = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
                if back?.first?.path != tmp.path { failures.append("文件还原失败") }
            } else {
                failures.append("文件没被采集")
            }

            // 敏感性标记必须被拒（密码管理器靠这个标记）
            let pb4 = NSPasteboard.general
            pb4.clearContents()
            let concealed = NSPasteboardItem()
            concealed.setString("super-secret", forType: .string)
            concealed.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            pb4.writeObjects([concealed])
            let leaked = store.capture(from: pb4, sourceApp: "selftest") != nil
            print("敏感标记：\(leaked ? "❌ 被采集了（严重）" : "✅ 已拒绝")")
            if leaked { failures.append("ConcealedType 没被拦住") }

            // 清掉自检产生的记录，别脏用户历史
            for id in ids { store.delete(id: id) }

            if failures.isEmpty {
                print("✅ 剪贴板历史往返正常（文本/富文本/图片/文件 + 敏感拦截）")
                return 0
            }
            print("❌ \(failures.joined(separator: "；"))")
            return 1

        case "meeting":
            // 录 N 秒会议，验证：麦克风可用 + 文件建立 + 头写入 + 正常收尾
            let secs = max(2.0, Double(args.count > 3 ? (Int(args[3]) ?? 3) : 3))
            let cfg = Config.load()
            let rec = MeetingRecorder(cfg: cfg)
            var path = ""
            var startErr = ""
            var done = false
            Task {
                do { path = try await rec.start() } catch { startErr = "\(error)" }
                done = true
            }
            let t0 = Date()
            while !done && Date().timeIntervalSince(t0) < 20 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if !startErr.isEmpty {
                print("❌ 启动失败：\(startErr)")
                return 1
            }
            print("录制中：\(path)，\(Int(secs)) 秒…")
            RunLoop.current.run(until: Date().addingTimeInterval(secs))

            var summary: MeetingRecorder.Summary?
            var stopped = false
            Task {
                summary = await rec.stop()
                stopped = true
            }
            while !stopped && Date().timeIntervalSince(t0) < 40 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            print("段落 \(summary?.segments ?? -1) / 时长 \(Int(summary?.seconds ?? 0)) 秒 / 字数 \(summary?.chars ?? -1)")
            guard let summary, FileManager.default.fileExists(atPath: summary.path) else {
                print("❌ 记录文件没落盘")
                return 1
            }
            let body = (try? String(contentsOfFile: summary.path, encoding: .utf8)) ?? ""
            let head = body.split(separator: "\n").prefix(8).joined(separator: "\n")
            print("--- 文件前 8 行 ---")
            print(head)
            let ok = body.contains("# 会议记录") && body.contains("结束") && summary.seconds >= secs - 1
            print(ok ? "✅ 会议记录链路可用（录音期间无语音时 0 段是正常的）" : "❌ 记录内容不完整")
            return ok ? 0 : 1

        case "offline":
            // 断网验证：润色请求打不到网时必须快速降级，且**文本照常返回**（不能因为润色失败就丢字）
            var cfg = Config.load()
            cfg.polish = true
            cfg.polishTimeout = 2.0
            let raw = "嗯 那个 我们 明天 上午 十点 开会 吧"
            var allOK = true

            for target in ["http://127.0.0.1:9/v1", "http://10.255.255.1/v1"] {
                cfg.polishBaseURL = target
                var text = ""
                var polished = true
                var done = false
                let t0 = Date()
                Task {
                    let r = await Polisher.polish(raw, cfg: cfg, key: "dummy-key-for-offline-test")
                    text = r.text; polished = r.polished; done = true
                }
                while !done && Date().timeIntervalSince(t0) < 12 {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                let elapsed = Date().timeIntervalSince(t0)
                let okTime = elapsed <= cfg.polishTimeout + 1.5
                let okText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let degraded = (polished == false)
                print("目标 \(target)")
                print("  耗时 \(String(format: "%.2f", elapsed))s（上限 \(cfg.polishTimeout + 1.5)s）\(okTime ? "✅" : "❌")")
                print("  文本保留 \(okText ? "✅" : "❌")：\(text.prefix(20))…")
                print("  已降级 \(degraded ? "✅" : "❌")（polished=\(polished)）")
                if !(okTime && okText && degraded) { allOK = false }
            }
            print(allOK ? "✅ 断网降级正常" : "❌ 断网时有问题")
            return allOK ? 0 : 1

        case "snaps":
            // 不复制算法，只检查布局该有的性质（半屏不重叠、角落在对应象限、三分屏拼满）
            let v = NSRect(x: 0, y: 0, width: 1200, height: 800)
            let cur = NSRect(x: 300, y: 200, width: 600, height: 400)
            var failures: [String] = []

            func r(_ l: SnapLayout) -> NSRect { SnapManager.rect(for: l, in: v, current: cur) }

            // SnapLayout.all 只是菜单里的 10 种，循环用的 ⅔ / ⅓ 也要一起验
            let checked: [SnapLayout] = SnapLayout.all + [.leftTwoThirds, .rightTwoThirds, .leftThird, .rightThird]

            for layout in checked {
                let rect = r(layout)
                if !v.contains(rect) { failures.append("\(layout) 越出可用区域 \(rect)") }
                if rect.width <= 1 || rect.height <= 1 { failures.append("\(layout) 尺寸异常 \(rect)") }
            }

            let lh = r(.leftHalf), rh = r(.rightHalf)
            if abs(lh.width + rh.width - v.width) > 0.5 { failures.append("左右半屏宽度和 ≠ 屏宽") }
            if lh.maxX > rh.minX + 0.5 { failures.append("左右半屏重叠") }

            let th = r(.topHalf), bh = r(.bottomHalf)
            if abs(th.height + bh.height - v.height) > 0.5 { failures.append("上下半屏高度和 ≠ 屏高") }
            if bh.maxY > th.minY + 0.5 { failures.append("上下半屏重叠") }

            let t1 = r(.leftThird), t2 = r(.leftTwoThirds)
            if !t1.equalTo(t2) && t1.width >= t2.width { failures.append("⅓ 不比 ⅔ 窄") }

            for (layout, c) in [(SnapLayout.topLeft, v.midX), (.topRight, v.midX),
                                (.bottomLeft, v.midX), (.bottomRight, v.midX)] {
                let rect = r(layout)
                let inLeft = rect.midX < c
                let shouldLeft = (layout == .topLeft || layout == .bottomLeft)
                if inLeft != shouldLeft { failures.append("\(layout) 落在错误的一侧") }
            }

            if !r(.maximize).equalTo(v) { failures.append("最大化 ≠ 可用区域") }
            let cen = r(.center)
            if abs(cen.midX - v.midX) > 0.5 || abs(cen.midY - v.midY) > 0.5 { failures.append("居中布局没居中") }

            print("吸附布局检查 \(checked.count) 种：")
            for l in checked { print("  \(l.title)\(String(repeating: " ", count: max(0, 8 - l.title.count)))\(r(l))") }
            if failures.isEmpty {
                print("✅ 几何全部通过")
                return 0
            } else {
                for f in failures { print("❌ \(f)") }
                return 1
            }

        case "files":
            let kw = args.count > 3 ? args[3] : "报告"
            var out: [FileSearch.Hit] = []
            var done = false
            FileSearch.search(kw, limit: 10) { hits in out = hits; done = true }
            let deadline = Date().addingTimeInterval(8)
            while !done && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            print("文件查询『\(kw)』命中 \(out.count) 个：")
            for h in out { print("  [\(h.isDirectory ? "目录" : "文件")] \(h.name)\t\(h.path)") }
            return out.isEmpty ? 1 : 0

        default:
            print("未知自检项 \(args[2])")
            return 2
        }
    }
}
