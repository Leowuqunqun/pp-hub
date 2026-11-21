import AVFoundation
import Foundation

/// 会议记录：长时间采集 + 按段落盘。
///
/// 与听写的区别：
/// - 不上屏（不碰光标、不碰剪贴板）
/// - 不逐句润色（会议动辄几百句，逐句调模型既慢又贵）
/// - 按「定稿段」逐行追加到文件，边录边写，崩溃不丢已录内容
/// - 每 `meetingRotateSec` 秒轮换一次识别会话，避免长会话内存与精度漂移
@available(macOS 26.0, *)
final class MeetingRecorder {
    struct Summary {
        let path: String
        let seconds: Double
        let segments: Int
        let chars: Int
    }

    private let cfg: Config
    private let locale: String

    private var capture: AudioCapture?
    private var session: SpeechSession?
    private var rotateTimer: Timer?
    private var handle: FileHandle?
    private var fileURL: URL?

    private var startedAt = Date()
    private var segments = 0
    private var chars = 0
    private(set) var isRunning = false

    /// HUD 用的实时信息
    var onLevel: ((Float) -> Void)?
    var onText: ((String) -> Void)?
    var onSegment: ((String) -> Void)?

    init(cfg: Config) {
        self.cfg = cfg
        self.locale = cfg.locales.first ?? "zh-CN"
    }

    var elapsed: TimeInterval { isRunning ? Date().timeIntervalSince(startedAt) : 0 }
    var filePath: String { fileURL?.path ?? "" }
    var segmentCount: Int { segments }

    // MARK: - 开始

    func start() async throws -> String {
        guard !isRunning else { return filePath }

        let dir = URL(fileURLWithPath: cfg.meetingDir.expandingTilde, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = Self.fileStamp(Date())
        let url = dir.appendingPathComponent("\(stamp)--会议.md")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(domain: "TypelessCore", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建会议记录文件 \(url.path)"])
        }
        fileURL = url
        handle = try FileHandle(forWritingTo: url)
        startedAt = Date()
        segments = 0
        chars = 0

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let body = """
        # 会议记录 \(fmt.string(from: startedAt))

        - 语言：\(locale)
        - 设备：\(Self.inputDeviceName())
        - 识别：端侧 SpeechAnalyzer（音频不出本机）

        ---

        """
        write(body)

        let format = try await SpeechSession.audioFormat(for: locale)
        let s = try await makeStartedSession()
        session = s

        let cap = AudioCapture(targetFormat: format)
        cap.onBuffer = { [weak self] buffer in self?.session?.feed(buffer) }
        cap.onLevel = { [weak self] level in self?.onLevel?(level) }
        try cap.start()
        capture = cap
        isRunning = true

        // 会话轮换：长会话不换会一直涨内存，也更容易识别漂移
        let interval = max(60, cfg.meetingRotateSec)
        rotateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.rotate() }
        }

        Log.write("meeting: 开始记录 → \(url.path)（轮换 \(interval)s）")
        return url.path
    }

    // MARK: - 结束

    func stop() async -> Summary? {
        guard isRunning else { return nil }
        isRunning = false
        rotateTimer?.invalidate(); rotateTimer = nil

        let seconds = Date().timeIntervalSince(startedAt)
        capture?.stop()
        capture?.onBuffer = nil
        capture?.onLevel = nil
        capture = nil

        if let s = session {
            let tail = await s.finish(timeout: 4)
            if !tail.isEmpty {
                // finish 只返回累计文本，尾段已经通过 onSegment 追加过，这里只在为空时兜底
                _ = tail
            }
        }
        session = nil

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let mins = Int(seconds) / 60
        write("\n---\n\n结束 \(fmt.string(from: Date()))，时长 \(mins) 分 \(Int(seconds) % 60) 秒，\(segments) 段，\(chars) 字\n")
        handle?.synchronizeFile()
        try? handle?.close()
        handle = nil

        let summary = Summary(path: fileURL?.path ?? "", seconds: seconds, segments: segments, chars: chars)
        Log.write("meeting: 结束，时长 \(mins)m\(Int(seconds) % 60)s / \(segments) 段 / \(chars) 字 → \(summary.path)")
        return summary
    }

    // MARK: - 内部

    private func makeStartedSession() async throws -> SpeechSession {
        let s = try await SpeechSession.bestFormat(for: locale, contextual: []).1
        s.onSegment = { [weak self] seg in self?.appendSegment(seg) }
        s.onVolatile = { [weak self] live in self?.onText?(live) }
        s.onError = { err in Log.write("meeting: asr 错误 \(err)") }
        try await s.start()
        return s
    }

    /// 先建好新会话再接流，避免轮换期间丢音频
    private func rotate() async {
        guard isRunning, let old = session else { return }
        do {
            let fresh = try await makeStartedSession()
            session = fresh                      // 之后的音频进新会话
            let tail = await old.finish(timeout: 3)
            Log.write("meeting: 会话已轮换（旧会话尾长 \(tail.count) 字）")
        } catch {
            Log.write("meeting: 轮换失败 \(error)，继续用旧会话")
        }
    }

    private func appendSegment(_ raw: String) {
        // 会议转写保留句末标点：整段读起来才不费劲
        let text = Polisher.quickClean(raw, replacements: cfg.replacements, keepEndPeriod: true)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        segments += 1
        chars += text.count
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        write("- **[\(fmt.string(from: Date()))]** \(text)\n")
        onSegment?(text)
    }

    private func write(_ s: String) {
        guard let handle, let data = s.data(using: .utf8) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()   // 边录边落盘：进程崩了也只是丢当前这一句
        } catch {
            Log.write("meeting: 写文件失败 \(error)")
        }
    }

    private static func fileStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd--HHmm"
        return f.string(from: d)
    }

    private static func inputDeviceName() -> String {
        guard let device = AVCaptureDevice.default(for: .audio) else { return "未知" }
        return device.localizedName
    }
}
