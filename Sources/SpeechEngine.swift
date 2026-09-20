import Foundation
import Speech
import AVFoundation

// The audio tap stays open for the whole session. Recognition requests rotate
// between utterances while Jev and Mac actions run independently.
private final class SpeechBufferSink {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var pending: [AVAudioPCMBuffer] = []
    private var buffering = false
    func attach(_ next: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock(); defer { lock.unlock() }
        request = next
        for buffer in pending { next.append(buffer) }
        pending.removeAll(); buffering = false
    }
    func betweenUtterances() {
        lock.lock(); defer { lock.unlock() }
        request = nil; buffering = true
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        request = nil; buffering = false; pending.removeAll()
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if let request { request.append(buffer); return }
        // Keep preroll during finalization so a quick follow-up isn't lost.
        guard buffering, pending.count < 80,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let input = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, target) in zip(input, output) {
            if let src = source.mData, let dst = target.mData {
                memcpy(dst, src, Int(min(source.mDataByteSize, target.mDataByteSize)))
            }
        }
        pending.append(copy)
    }
}

final class SpeechEngine {
    var onTranscript: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onFinished: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let sink = SpeechBufferSink()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var utterance = UtteranceBuffer()
    private var requestStartedAt = Date()
    private var active = false
    private var ending = false
    private var submitAtEnd = false
    private var suppressed = false
    private var generation = 0
    private var sessionGeneration = 0
    private var hasTap = false
    private var hints: [String] = []
    private var replayTask: Task<Void, Never>?
    private var replaying = false
    private var consecutiveErrors = 0
    var isLocalAvailable: Bool { recognizer?.supportsOnDeviceRecognition == true }
    var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var speechGranted: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    func requestPermissions() async -> Bool {
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        return microphone && speech
    }
    func start(hints: [String]) throws {
        guard microphoneGranted && speechGranted else { throw VoiceError.message("Enable Microphone and Speech Recognition in Setup first.") }
        guard let recognizer, recognizer.isAvailable else { throw VoiceError.message("Apple speech recognition is currently unavailable.") }
        guard recognizer.supportsOnDeviceRecognition else { throw VoiceError.message("On-device English speech recognition is unavailable. Enable English dictation in System Settings → Keyboard.") }
        cancel()
        active = true; suppressed = false; consecutiveErrors = 0
        self.hints = Array((hints + ["Jev", "end command", "cancel task", "stop listening"]).prefix(100))
        let session = sessionGeneration
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { cancel(); throw VoiceError.message("No working microphone was found.") }
        beginRequest()
        node.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self, sink] buffer, _ in
            sink.append(buffer)
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for index in 0..<count { sum += samples[index] * samples[index] }
            let rms = Double(sqrt(sum / Float(count)))
            DispatchQueue.main.async {
                guard let self, self.active, !self.suppressed, session == self.sessionGeneration else { return }
                self.onLevel?(min(1, rms * 12))
                if rms > 0.012 {
                    self.utterance.voice(at: Date().timeIntervalSinceReferenceDate)
                    // The endpoint was already decided after a complete phrase;
                    // resumed audio stays buffered for the next request.
                }
            }
        }
        hasTap = true
        engine.prepare()
        do { try engine.start() } catch { cancel(); throw error }
        startTimer()
    }
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, self.active, !self.ending, !self.suppressed else { return }
            guard self.replaying || self.engine.isRunning else {
                self.cancel(); self.onError?("The audio device stopped or changed. Turn the mic on to reconnect."); return
            }
            let now = Date().timeIntervalSinceReferenceDate
            if let began = self.utterance.beganAt, now - began > 120 {
                self.utterance.reset()
                self.onError?("That request was too long. Nothing was run. Please give a shorter request.")
                self.finishRequest(submit: false)
            } else if self.utterance.shouldFinish(at: now) {
                self.finishRequest(submit: true)
            } else if Date().timeIntervalSince(self.requestStartedAt) > 25 {
                self.finishRequest(submit: false)
            }
        }
    }
    /// Feed a real recording at its original pace through the exact same
    /// recognizer, audio-level endpoint logic, request rotation and callbacks.
    /// This diagnostic mode never mixes the recording with the live microphone.
    func replay(_ url: URL, finished: @escaping () -> Void) throws {
        guard speechGranted, isLocalAvailable else { throw VoiceError.message("On-device speech recognition needs permission.") }
        cancel()
        let file = try AVAudioFile(forReading: url)
        active = true; replaying = true
        hints = ["Jev", "Notes", "Arc", "Chrome", "Photo Booth"]
        beginRequest(); startTimer()
        replayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let start = Date()
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else { throw VoiceError.message("Cannot allocate audio buffer.") }
                    try file.read(into: buffer)
                    self.sink.append(buffer)
                    if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                        var sum: Float = 0
                        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
                        let rms = Double(sqrt(sum / Float(buffer.frameLength)))
                        self.onLevel?(min(1, rms * 12))
                        if rms > 0.012 {
                            self.utterance.voice(at: Date().timeIntervalSinceReferenceDate)
                            // New audio is queued for the next utterance after an endpoint.
                        }
                    }
                    let due = Double(file.framePosition) / file.processingFormat.sampleRate
                    let delay = due - Date().timeIntervalSince(start)
                    if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                }
                try await Task.sleep(nanoseconds: 3_200_000_000)
                self.timer?.invalidate(); self.timer = nil
                self.active = false; self.replaying = false
                self.generation += 1; self.sink.clear(); self.task?.cancel(); self.task = nil
                self.onLevel?(0); finished()
            } catch is CancellationError { }
            catch { self.onError?(error.localizedDescription) }
        }
    }
    private func beginRequest() {
        guard active, !suppressed, let recognizer else { return }
        generation += 1
        onDiagnostic?("begin request \(generation)")
        let token = generation
        ending = false; submitAtEnd = false; requestStartedAt = Date()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = hints
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.active, !self.suppressed, token == self.generation else { return }
                if let result {
                    let transcription = result.bestTranscription
                    let start = transcription.segments.first?.timestamp
                    let end = transcription.segments.last.map { $0.timestamp + $0.duration }
                    self.onDiagnostic?("span \(token): \(start ?? -1)...\(end ?? -1)")
                    self.utterance.recognize(transcription.formattedString, start: start, end: end, at: Date().timeIntervalSinceReferenceDate)
                    if !self.utterance.text.isEmpty { self.consecutiveErrors = 0 }
                    self.onTranscript?(self.utterance.text)
                    if result.isFinal { self.onDiagnostic?("final \(token): \(result.bestTranscription.formattedString)"); self.completeRequest(token: token) }
                } else if let error, !self.ending {
                    let nsError = error as NSError
                    self.onDiagnostic?("error \(token): \(nsError.domain)/\(nsError.code); buffered: \(self.utterance.text)")
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        self.completeRequest(token: token); return
                    }
                    self.consecutiveErrors += 1
                    if self.consecutiveErrors >= 3 {
                        self.cancel(); self.onError?("The microphone stopped: \(error.localizedDescription)")
                    } else {
                        self.utterance.reset() // Failed fragments must never execute.
                        self.finishRequest(submit: false)
                    }
                }
            }
        }
        sink.attach(request)
    }
    private func finishRequest(submit: Bool) {
        guard active, !ending, !suppressed else { return }
        onDiagnostic?("finish request \(generation), submit=\(submit), text=\(utterance.text)")
        ending = true; submitAtEnd = submit
        sink.betweenUtterances(); request?.endAudio()
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.completeRequest(token: token) }
    }
    private func completeRequest(token: Int) {
        guard active, !suppressed, token == generation else { return }
        utterance.commitSegment()
        let submit = submitAtEnd
        let command = utterance.command
        generation += 1
        sink.betweenUtterances(); task?.cancel(); task = nil; request = nil
        if submit { utterance.reset() }
        beginRequest()
        if submit && !command.isEmpty { onDiagnostic?("submit: \(command)"); onFinished?(command) }
    }
    /// Keep the physical microphone open, but exclude our own spoken feedback.
    func suppressRecognition(_ value: Bool) {
        guard suppressed != value else { return }
        suppressed = value
        if value { onLevel?(0) }
        generation += 1; task?.cancel(); task = nil; request = nil
        sink.clear(); utterance.reset(); ending = false
        if active && !value { beginRequest() }
    }
    func cancel() {
        replayTask?.cancel(); replayTask = nil; replaying = false
        sessionGeneration += 1; generation += 1
        active = false; ending = false; suppressed = false; utterance.reset()
        timer?.invalidate(); timer = nil; sink.clear(); engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        task?.cancel(); task = nil; request = nil
        onLevel?(0)
    }
}
