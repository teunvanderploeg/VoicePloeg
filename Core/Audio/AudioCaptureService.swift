@preconcurrency import AVFoundation
import Foundation

enum AudioCaptureError: Error, LocalizedError {
    case engineNotReady

    var errorDescription: String? {
        switch self {
        case .engineNotReady:
            return "Audio engine is not ready"
        }
    }
}

final class AudioCaptureService: NSObject, RecordingController, @unchecked Sendable {
    private final class ConverterInputState: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var didFeed = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let lock = NSLock()
    private let maxSamples: Int

    private var converter: AVAudioConverter?
    private var converterInputSampleRate: Double = 0
    private var converterInputChannelCount: AVAudioChannelCount = 0
    private var capturedSamples: [Float] = []
    private var isRecording = false
    private var engine: AVAudioEngine?

    init(maxDurationSeconds: TimeInterval = ReleaseConfig.maxRecordingDurationSeconds) {
        maxSamples = Int(16_000 * maxDurationSeconds)
        super.init()
    }

    func start() async throws {
        guard !isRecording else { return }

        lock.withLock {
            capturedSamples.removeAll(keepingCapacity: true)
            converter = nil
            converterInputSampleRate = 0
            converterInputChannelCount = 0
        }

        try await startEngineWithRetry()
        isRecording = true
    }

    func stop() async throws -> [Float] {
        guard isRecording else { return [] }

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        engine = nil
        isRecording = false
        lock.withLock {
            converter = nil
            converterInputSampleRate = 0
            converterInputChannelCount = 0
        }

        let output = lock.withLock {
            capturedSamples
        }

        return Self.normalize(output)
    }

    private func startEngineWithRetry() async throws {
        let maxAttempts = 2
        var lastError: Error?

        for attempt in 1 ... maxAttempts {
            do {
                try startFreshEngine()
                return
            } catch {
                lastError = error
                teardownEngine()

                guard attempt < maxAttempts, isCoreAudioRouteNegotiationError(error) else {
                    throw error
                }

                // Bluetooth/HFP route switches can briefly expose unsupported formats.
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        if let lastError {
            throw lastError
        }
    }

    private func startFreshEngine() throws {
        let freshEngine = AVAudioEngine()
        let inputNode = freshEngine.inputNode

        inputNode.removeTap(onBus: 0)
        // Use hardware-native format to avoid CoreAudio tap format mismatch when input device changes.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        freshEngine.reset()
        freshEngine.prepare()
        try freshEngine.start()
        engine = freshEngine
    }

    private func teardownEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        engine = nil
    }

    private func isCoreAudioRouteNegotiationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.apple.coreaudio.avfaudio" && nsError.code == -10868
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter = activeConverter(for: buffer.format) else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let targetCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio) + 32)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            return
        }

        var error: NSError?
        let inputState = ConverterInputState(buffer: buffer)
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if inputState.didFeed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.didFeed = true
            outStatus.pointee = .haveData
            return inputState.buffer
        }

        guard error == nil else {
            return
        }

        guard status == .haveData || status == .inputRanDry || status == .endOfStream else {
            return
        }

        let frameLength = Int(convertedBuffer.frameLength)
        guard frameLength > 0, let channelData = convertedBuffer.floatChannelData?[0] else {
            return
        }

        lock.withLock {
            let remaining = maxSamples - capturedSamples.count
            guard remaining > 0 else { return }

            let copyCount = min(remaining, frameLength)
            let samples = UnsafeBufferPointer(start: channelData, count: copyCount)
            capturedSamples.append(contentsOf: samples)
        }
    }

    private func activeConverter(for inputFormat: AVAudioFormat) -> AVAudioConverter? {
        lock.withLock {
            if
                converter == nil
                || converterInputSampleRate != inputFormat.sampleRate
                || converterInputChannelCount != inputFormat.channelCount
            {
                converter = AVAudioConverter(from: inputFormat, to: targetFormat)
                converterInputSampleRate = inputFormat.sampleRate
                converterInputChannelCount = inputFormat.channelCount
            }
            return converter
        }
    }

    static func normalize(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }

        let mean = samples.reduce(0, +) / Float(samples.count)
        var centered = samples.map { $0 - mean }

        let maxAbs = centered.reduce(Float.zero) { max($0, abs($1)) }
        guard maxAbs > 0 else { return [] }
        let gain = 0.95 / maxAbs
        centered = centered.map { $0 * gain }

        // A later loud sample must not make quiet opening speech disappear.
        return centered
    }
}
