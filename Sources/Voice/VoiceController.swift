import AppKit
import AVFoundation

/// 语音听写 —— 从 typeless-core 的 AppDelegate 听写流程原样复刻：
/// 预热池（省去模型初始化）+ 实时浮窗（HUD）+ 规则清洗 + 先上屏后润色 + 原地精修。
///
/// 与原版的差异只有三处，都是"接入本容器"必需的：
///   1. 触发手势由 ShortcutCenter 提供（原版自带 HotkeyMonitor，pp-hub 已有键盘中枢）
///   2. 最终文本同时写入 pp-hub 的剪贴板/事件库（source=voice），供面板检索
///   3. 配置落在 pp-hub 数据目录，日志走本站 Log
@MainActor
final class VoiceController {

    enum State: String { case idle, preparing, recording, finishing }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?
    /// 最终文本（润色后，即真正上屏的那份）
    var onFinalText: ((String) -> Void)?

    private var cfg = Config.load()
    private let hud = HUD()

    private var session: SpeechSession?
    private var capture: AudioCapture?
    private var sharedFormat: AVAudioFormat?
    private var readySession: SpeechSession?
    private var readyAt: Date?
    private var partial = ""
    private var lastToggleAt = Date.distantPast
    private var pendingStop = false

    // MARK: - 生命周期

    /// 启动时预热：加载识别格式并建一个"已 start、待喂音"的会话
    func start() {
        Task { @MainActor in
            do {
                let locale = cfg.locales.first ?? "zh-CN"
                sharedFormat = try await SpeechSession.audioFormat(for: locale)
                if let f = sharedFormat { Log.write("voice: 预热格式 \(f.sampleRate)Hz 就绪") }
                await prepareSession(locale: locale)
            } catch {
                Log.write("voice: 预热失败 \(error)")
            }
        }
    }

    private func prepareSession(locale: String) async {
        do {
            let transcriber = try await SpeechSession.makeTranscriber(localeID: locale, contextual: [])
            guard let format = sharedFormat else { return }
            let s = SpeechSession(transcriber: transcriber, format: format)
            try await s.start()
            readySession = s
            readyAt = Date()
            Log.write("voice: 预热池就绪")
        } catch {
            Log.write("voice: 预热池建立失败 \(error)")
        }
    }

    private func takeReadySession(locale: String, format: AVAudioFormat) async throws -> SpeechSession {
        if let s = readySession, let at = readyAt, Date().timeIntervalSince(at) < 120 {
            readySession = nil; readyAt = nil
            Log.write("voice: 预热池命中")
            return s
        }
        readySession?.cancel(); readySession = nil
        let transcriber = try await SpeechSession.makeTranscriber(localeID: locale, contextual: [])
        let s = SpeechSession(transcriber: transcriber, format: format)
        try await s.start()
        return s
    }

    // MARK: - 开关

    var polishEnabled: Bool { cfg.polish }
    func togglePolish() {
        cfg.polish.toggle()
        cfg.save()
        Log.write("voice: 润色 \(cfg.polish ? "开" : "关")")
    }

    nonisolated static var micStatusText: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "已授权"
        case .notDetermined: return "未请求，首次听写时询问"
        case .denied: return "被拒，需去系统设置打开"
        default: return "受限"
        }
    }

    // MARK: - 切换式交互

    func toggle() {
        let now = Date()
        if now.timeIntervalSince(lastToggleAt) < 0.25 { return }   // 连按去抖
        lastToggleAt = now

        switch state {
        case .idle:
            begin()
        case .recording:
            end()
        case .preparing:
            pendingStop = true
            hud.set(state: "结束中…")
        case .finishing:
            Log.write("voice: 收尾中，忽略本次触发")
        }
    }

    private func begin() {
        guard state == .idle else { return }
        state = .preparing
        partial = ""
        let pressStart = Date()
        hud.set(state: "准备中…")
        hud.set(text: "")
        hud.set(level: 0)
        if cfg.hud { hud.show() }

        Task { @MainActor in
            guard await AudioCapture.requestMicrophonePermission() else {
                Log.write("voice: 缺少麦克风权限")
                self.state = .idle
                self.hud.hide()
                return
            }

            do {
                let locale = self.cfg.locales.first ?? "zh-CN"
                let format: AVAudioFormat
                if let shared = self.sharedFormat {
                    format = shared
                } else {
                    format = try await SpeechSession.audioFormat(for: locale)
                    self.sharedFormat = format
                }

                let speech = try await self.takeReadySession(locale: locale, format: format)
                speech.onVolatile = { [weak self] text in
                    guard let self else { return }
                    self.partial = text
                    self.hud.set(text: text)
                }
                speech.onError = { err in Log.write("voice: asr 错误 \(err)") }
                // 注意：takeReadySession 返回的会话已经 start 过，这里不能再 start

                let cap = AudioCapture(targetFormat: format)
                cap.onBuffer = { buffer in speech.feed(buffer) }
                cap.onLevel = { level in self.hud.set(level: level) }
                try cap.start()

                self.session = speech
                self.capture = cap
                self.state = .recording
                self.hud.set(state: "聆听中…（再按一下结束）")
                self.hud.set(text: "")
                Log.write("voice: 开始录音，准备耗时 \(Int(Date().timeIntervalSince(pressStart) * 1000))ms")

                if self.pendingStop {
                    self.pendingStop = false
                    Log.write("voice: 准备阶段又按了一次，立即收尾")
                    self.end()
                }
            } catch {
                Log.write("voice: 启动录音失败 \(error)")
                self.cleanup()
                self.state = .idle
                self.hud.hide()
            }
        }
    }

    private func end() {
        guard state == .recording, let speech = session, let cap = capture else { return }
        state = .finishing
        let stopAt = Date()

        let recordedSecs = cap.recordedSeconds
        cap.stop()
        cap.onBuffer = nil
        cap.onLevel = nil
        capture = nil

        if recordedSecs < 0.30 {
            Log.write("voice: 录音仅 \(String(format: "%.2f", recordedSecs))s，太短，不送识别")
            hud.set(state: "太短了，请再说一遍")
            session = nil
            state = .idle
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); self.hud.hide() }
            return
        }

        hud.set(state: "识别中…")
        hud.set(level: 0)

        Task { @MainActor in
            let raw = await speech.finish()
            let asrMs = Int(Date().timeIntervalSince(stopAt) * 1000)
            self.session = nil
            Task { await self.prepareSession(locale: self.cfg.locales.first ?? "zh-CN") }

            guard !Polisher.isEffectivelyEmpty(raw) else {
                Log.write("voice: 识别为空，耗时 \(asrMs)ms，不上屏")
                self.hud.set(state: "没听清")
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.hud.hide()
                self.state = .idle
                return
            }

            // ① 先上屏原始文本：感知延迟 = ASR 延迟
            let cleaned = Polisher.quickClean(raw, replacements: self.cfg.replacements)
            let (method, handle) = Injector.insert(cleaned, restoreClipboard: self.cfg.restoreClipboard)
            let insertMs = Int(Date().timeIntervalSince(stopAt) * 1000)
            let preview = cleaned.count > 40 ? String(cleaned.prefix(40)) + "…" : cleaned
            Log.write("voice: 上屏完成 ASR \(asrMs)ms / 首屏 \(insertMs)ms / 方式=\(method.rawValue) / \(cleaned.count) 字 / 内容=\(preview)")

            self.hud.set(state: method == .failed ? "上屏失败（检查辅助功能权限）" : "已上屏")
            self.hud.set(text: cleaned)
            self.onFinalText?(cleaned)

            if method == .failed {
                self.hud.hide()
                self.state = .idle
                return
            }

            // ② 后台润色：回来后原地替换刚插入的文本
            if self.cfg.polish, let handle, let key = Credentials.tokenHubKey(cfg: self.cfg) {
                self.hud.set(state: "润色中…")
                let (polished, ok) = await Polisher.polish(raw, cfg: self.cfg, key: key)
                if !ok {
                    self.hud.set(state: "润色超时/失败，保留原文")
                } else if polished == cleaned {
                    self.hud.set(state: "已是通顺文本，无需润色")
                } else {
                    let refined = Injector.refine(handle, to: polished)
                    self.hud.set(state: refined ? "已润色" : "润色稿未替换（光标已移动）")
                    if refined {
                        self.hud.set(text: polished)
                        self.onFinalText?(polished)   // 落库也用润色后的版本
                    }
                    Log.write("voice: 精修 \(refined ? "生效" : "跳过") 总耗时 \(Int(Date().timeIntervalSince(stopAt) * 1000))ms")
                }
            } else if self.cfg.polish {
                Log.write("voice: 未找到 tokenhub 凭据，只做规则清洗")
            }

            if self.cfg.hud {
                try? await Task.sleep(nanoseconds: 600_000_000)
                self.hud.hide()
            }
            self.state = .idle
        }
    }

    private func cleanup() {
        capture?.stop()
        capture = nil
        capture?.onBuffer = nil
        capture?.onLevel = nil
        session?.cancel()
        session = nil
    }
}
