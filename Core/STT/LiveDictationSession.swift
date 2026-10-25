import Foundation

enum LiveDictationError: Error, LocalizedError {
    case unavailable
    case unverifiableField
    case targetChanged
    case insertionUnconfirmed

    var errorDescription: String? {
        switch self {
        case .unavailable: return UserFacingMessage.liveUnavailable
        case .unverifiableField: return UserFacingMessage.liveUnverifiableField
        case .targetChanged: return UserFacingMessage.liveTargetChanged
        case .insertionUnconfirmed: return UserFacingMessage.liveInsertionUnconfirmed
        }
    }
}

enum LiveTextFormatting {
    static func insertion(_ text: String, after prefix: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let last = prefix.last, !last.isWhitespace,
              !"([{“\"".contains(last), let first = trimmed.first,
              !".,!?;:)]}".contains(first) else { return trimmed }
        return " " + trimmed
    }
}

/// A single producer and a single consumer. The capture service's recording limit
/// bounds all queued audio to two minutes. No chunk is dropped to catch up.
@MainActor
final class LiveDictationSession {
    private let recorder: any LiveRecordingController
    private let transcriber: any SpeechTranscribing
    private let request: @Sendable ([Float]) -> TranscriptionRequest
    private let output: any LiveTextOutputSession
    private let buffer = LivePhraseBuffer()
    private let onUpdate: @MainActor (String, LiveDictationStatus) -> Void
    private let onCaptureStopped: @MainActor () -> Void
    private let onTranscriptionFailure: @MainActor () -> Void
    private var captureTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var queue: [[Float]] = []
    private var isProcessing = false
    private var isCancelled = false
    private var isFinishing = false
    private(set) var transcript = ""
    private(set) var errorMessage: String?
    private var insertionPaused = false
    private var transcriptionFailed = false

    init(
        recorder: any LiveRecordingController,
        transcriber: any SpeechTranscribing,
        output: any LiveTextOutputSession,
        request: @escaping @Sendable ([Float]) -> TranscriptionRequest,
        onUpdate: @escaping @MainActor (String, LiveDictationStatus) -> Void,
        onCaptureStopped: @escaping @MainActor () -> Void,
        onTranscriptionFailure: @escaping @MainActor () -> Void
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.output = output
        self.request = request
        self.onUpdate = onUpdate
        self.onCaptureStopped = onCaptureStopped
        self.onTranscriptionFailure = onTranscriptionFailure
    }

    func start() {
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    func poll() async {
        checkOutput()
        let samples = await recorder.drainLiveSamples()
        let phrases = await buffer.append(samples)
        enqueue(phrases)
    }

    func cancel() {
        isCancelled = true
        queue.removeAll()
        processingTask?.cancel()
        output.close()
    }

    func finish() async {
        guard !isFinishing else { return }
        isFinishing = true
        captureTask?.cancel()
        await captureTask?.value
        captureTask = nil
        do {
            _ = try await recorder.stop()
        } catch {
            errorMessage = error.localizedDescription
        }
        onCaptureStopped()
        let samples = await recorder.drainLiveSamples()
        let phrases = await buffer.append(samples)
        let tail = await buffer.finish()
        enqueue(phrases + tail)
        await processingTask?.value
        processingTask = nil
        output.close()
    }

    private func checkOutput() {
        guard !insertionPaused, !isCancelled else { return }
        do {
            try output.validate()
        } catch {
            pauseInsertion(error)
        }
    }

    private func enqueue(_ phrases: [[Float]]) {
        guard !isCancelled, !transcriptionFailed else { return }
        queue.append(contentsOf: phrases)
        publish()
        guard processingTask == nil, !queue.isEmpty else { return }
        processingTask = Task { [weak self] in
            await self?.processQueue()
        }
    }

    private func processQueue() async {
        defer {
            isProcessing = false
            processingTask = nil
            publish()
        }
        while !queue.isEmpty, !isCancelled {
            let samples = queue.removeFirst()
            isProcessing = true
            publish()
            do {
                let result = try await transcriber.transcribe(request(samples))
                guard !isCancelled, !Task.isCancelled else { return }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                transcript += LiveTextFormatting.insertion(text, after: transcript)
                publish()
                checkOutput()
                if !insertionPaused {
                    do {
                        try await output.insert(text)
                    } catch {
                        if !isCancelled { pauseInsertion(error) }
                    }
                }
            } catch {
                guard !isCancelled else { return }
                transcriptionFailed = true
                errorMessage = UserFacingMessage.liveTranscriptionFailed(error.localizedDescription)
                insertionPaused = true
                queue.removeAll()
                publish()
                onTranscriptionFailure()
                return
            }
        }
    }

    private func pauseInsertion(_ error: Error) {
        insertionPaused = true
        errorMessage = error.localizedDescription
        publish()
    }

    private func publish() {
        let status: LiveDictationStatus
        if insertionPaused {
            status = .paused(message: errorMessage ?? UserFacingMessage.liveTargetChanged)
        } else if !queue.isEmpty, isProcessing {
            status = .catchingUp
        } else if isProcessing || !queue.isEmpty {
            status = .transcribing
        } else {
            status = .listening
        }
        onUpdate(transcript, status)
    }
}
