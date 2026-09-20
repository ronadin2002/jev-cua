import AVFoundation

@MainActor final class SpokenFeedback: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var onSpeakingChanged: ((Bool) -> Void)?
    private var generation = 0
    override init() { super.init(); synthesizer.delegate = self }
    func say(_ text: String) {
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        onSpeakingChanged?(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.53
        synthesizer.speak(utterance)
    }
    func stop() {
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        onSpeakingChanged?(false)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { Task { @MainActor [weak self] in self?.resumeAfterTail() } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { Task { @MainActor [weak self] in self?.resumeAfterTail() } }
    private func resumeAfterTail() {
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, token == self.generation, !self.synthesizer.isSpeaking else { return }
            self.onSpeakingChanged?(false)
        }
    }
}
