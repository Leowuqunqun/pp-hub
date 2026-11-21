import AVFoundation
import Speech
import Foundation

/// 一次听写会话：SpeechAnalyzer + SpeechTranscriber，端侧流式识别（不上传）
@available(macOS 26.0, *)
final class SpeechSession {
    let analyzer: SpeechAnalyzer
    let transcriber: SpeechTranscriber
    private let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var startTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private let lock = NSLock()
    private var _committed = ""   // 已定稿的分段（可能多段）
    private var _volatile = ""    // 当前未定稿片段
    private var _finalText = ""   // 定稿后的累积文本

    var onVolatile: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    /// 每定稿一段就回调「这一段」本身（累计文本在 onFinal；会议记录按段落盘用这个）
    var onSegment: ((String) -> Void)?
    var onError: ((String) -> Void)?

    var finalText: String { lock.lock(); defer { lock.unlock() }; return _finalText }
    var liveText: String { lock.lock(); defer { lock.unlock() }; return _finalText + _volatile }

    /// 目标音频格式（模型要求）
    static func bestFormat(for localeID: String, contextual: [String]) async throws -> (AVAudioFormat, SpeechSession) {
        let transcriber = try await makeTranscriber(localeID: localeID, contextual: contextual)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "TypelessCore", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "无法取得端侧模型的音频格式"])
        }
        let session = SpeechSession(transcriber: transcriber, format: format)
        return (format, session)
    }

    /// 只取格式（启动预热用）
    static func audioFormat(for localeID: String) async throws -> AVAudioFormat {
        let transcriber = try await makeTranscriber(localeID: localeID, contextual: [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "TypelessCore", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "无法取得端侧模型的音频格式"])
        }
        return format
    }

    static func makeTranscriber(localeID: String, contextual: [String]) async throws -> SpeechTranscriber {
        let locale = Locale(identifier: localeID)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw NSError(domain: "TypelessCore", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "端侧模型不支持语言 \(localeID)"])
        }
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        return transcriber
    }

    init(transcriber: SpeechTranscriber, format: AVAudioFormat) {
        self.transcriber = transcriber
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.stream = stream
        self.continuation = continuation
        self.analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
    }

    func start() async throws {
        let t0 = Date()
        // 结果消费必须先挂上，否则首个 volatile 会丢
        let transcriber = self.transcriber
        resultTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await r in transcriber.results {
                    let text = String(r.text.characters)
                    if r.isFinal {
                        // 识别器会按停顿切段，多段必须累积而非覆盖
                        self.lock.lock()
                        let seg = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !seg.isEmpty {
                            self._committed = Self.join(self._committed, seg)
                            self._finalText = self._committed
                        }
                        self._volatile = ""
                        let cumulative = self._finalText
                        self.lock.unlock()
                        await MainActor.run { self.onFinal?(cumulative) }
                        if !seg.isEmpty { await MainActor.run { self.onSegment?(seg) } }
                    } else {
                        self.lock.lock()
                        self._volatile = text
                        let live = self._finalText + text
                        self.lock.unlock()
                        await MainActor.run { self.onVolatile?(live) }
                    }
                }
            } catch {
                Log.write("asr: 结果流错误 \(error)")
                await MainActor.run { self.onError?("\(error)") }
            }
        }
        let analyzer = self.analyzer
        startTask = Task {
            do {
                try await analyzer.start(inputSequence: self.stream)
            } catch {
                Log.write("asr: start 失败 \(error)")
                await MainActor.run { self.onError?("\(error)") }
            }
        }
        // 预热：等模型就绪，避免首个 buffer 丢失
        try await analyzer.prepareToAnalyze(in: nil)
        Log.write("asr: 会话就绪 \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000))ms")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// 结束送音并等待最终文本（超时保护）
    func finish(timeout: Double = 5.0) async -> String {
        continuation.finish()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.write("asr: finalize 失败 \(error)")
        }
        while Date() < deadline {
            lock.lock(); let t = _finalText; lock.unlock()
            if !t.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        lock.lock(); _finalText = _committed; lock.unlock()
        _ = await resultTask?.value
        startTask?.cancel()
        return finalText
    }

    /// 两段中文直接拼接，中英文之间补一个空格
    static func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        let aLast = a.last!, bFirst = b.first!
        let aCJK = aLast.unicodeScalars.first.map { (0x4E00...0x9FFF).contains(Int($0.value)) } ?? false
        let bCJK = bFirst.unicodeScalars.first.map { (0x4E00...0x9FFF).contains(Int($0.value)) } ?? false
        return aCJK || bCJK ? a + b : a + " " + b
    }

    func cancel() {
        continuation.finish()
        Task { await analyzer.cancelAndFinishNow() }
        startTask?.cancel()
        resultTask?.cancel()
    }
}
