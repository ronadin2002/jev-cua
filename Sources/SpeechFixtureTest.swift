import Foundation
import Speech
import AVFoundation

@MainActor final class SpeechFixtureTest {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var lastPartial = ""
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    func transcribe(_ url: URL) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer, recognizer.supportsOnDeviceRecognition else { throw VoiceError.message("Local speech unavailable: authorization=\(SFSpeechRecognizer.authorizationStatus().rawValue), onDevice=\(recognizer?.supportsOnDeviceRecognition == true).") }
        let file = try AVAudioFile(forReading: url)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = ["Jev", "YouTube", "end command", "confirm action", "cancel task", "stop listening"]
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.lastPartial = result.bestTranscription.formattedString }
                    if let result, result.isFinal { self.finish(.success(result.bestTranscription.formattedString)) }
                    else if let error { self.finish(.failure(error)) }
                }
            }
            do {
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw VoiceError.message("Could not allocate speech test audio.") }
                    try file.read(into: buffer)
                    request.append(buffer)
                }
                request.endAudio()
            } catch { finish(.failure(error)) }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.finish(.failure(VoiceError.message("Speech fixture timed out. Last partial: \(self?.lastPartial ?? "none")")))
            }
        }
    }
    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
        task?.cancel(); task = nil
    }
}
