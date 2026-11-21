import AVFoundation
import CoreAudio

/// 麦克风采集：AVAudioEngine 输入 → 转成 16kHz 单声道 Float32 → 交给识别器
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private(set) var targetFormat: AVAudioFormat

    /// 每个 buffer 回调（已转换为 targetFormat）
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// 音量（0...1），供 HUD 画电平
    var onLevel: ((Float) -> Void)?
    /// 采集时长（秒）
    private(set) var recordedSeconds: Double = 0

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        recordedSeconds = 0
        let input = engine.inputNode
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0 else {
            throw NSError(domain: "TypelessCore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "麦克风不可用（采样率 0，检查系统输入设备）"])
        }
        guard let conv = AVAudioConverter(from: natural, to: targetFormat) else {
            throw NSError(domain: "TypelessCore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "音频格式转换器创建失败"])
        }
        converter = conv

        let ratio = targetFormat.sampleRate / natural.sampleRate
        let tapBuffer: AVAudioFrameCount = 2048

        input.installTap(onBus: 0, bufferSize: tapBuffer, format: natural) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else { return }
            var err: NSError?
            var supplied = false
            let status = converter.convert(to: out, error: &err) { _, outStatus in
                if supplied { outStatus.pointee = .noDataNow; return nil }
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            if let err { Log.write("audio: 转换失败 \(err.localizedDescription)"); return }
            guard status != .error, out.frameLength > 0 else { return }

            self.recordedSeconds += Double(out.frameLength) / self.targetFormat.sampleRate
            self.onLevel?(Self.rms(out))
            self.onBuffer?(out)
        }

        engine.prepare()
        try engine.start()
        Log.write("audio: 开始采集（自然格式 \(natural.sampleRate)Hz \(natural.channelCount)ch → \(targetFormat.sampleRate)Hz 单声道）")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Log.write("audio: 停止采集，录制 \(String(format: "%.2f", recordedSeconds))s")
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = (sum / Float(n)).squareRoot()
        // 映射到 0...1（-50dB 起点，近似人耳感知）
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 50) / 50))
    }
}
