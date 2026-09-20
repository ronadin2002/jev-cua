import Foundation

/// Recognition requests may finalize mid-sentence. Only this buffer decides when
/// the complete spoken request is ready; request rotation never submits a task.
struct UtteranceBuffer {
    private(set) var segments: [String] = []
    private(set) var partial = ""
    private(set) var lastTextAt: TimeInterval = 0
    private(set) var lastVoiceAt: TimeInterval = 0
    private(set) var beganAt: TimeInterval?
    private var audioStart: TimeInterval?
    private var audioEnd: TimeInterval?
    private var timedAt: TimeInterval = 0
    var text: String { (segments + [partial]).filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var endMarker: String? {
        let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        for marker in ["end of command", "end command", "and command"] {
            guard normalized == marker || normalized.hasSuffix(" " + marker),
                  let range = text.range(of: marker, options: [.caseInsensitive, .backwards]) else { continue }
            let prefix = text[..<range.lowerBound]
            guard prefix.filter({ $0 == "\"" }).count % 2 == 0,
                  prefix.filter({ $0 == "“" }).count == prefix.filter({ $0 == "”" }).count else { continue }
            return marker
        }
        return nil
    }
    var explicitEnd: Bool { endMarker != nil }
    var command: String {
        var value = text
        if let marker = endMarker, let range = value.range(of: marker, options: [.caseInsensitive, .backwards]) { value = String(value[..<range.lowerBound]) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    mutating func update(_ value: String, at now: TimeInterval) {
        if value != partial { lastTextAt = now }
        partial = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if beganAt == nil && !partial.isEmpty { beganAt = now }
    }
    mutating func recognize(_ value: String, start: TimeInterval?, end: TimeInterval?, at now: TimeInterval) {
        // macOS can roll its partial transcript forward WITHOUT isFinal. A
        // non-overlapping audio span is a new segment, not a correction that
        // should erase the preceding request. Empty finals retain the last text.
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let newWords = value.lowercased().split { !$0.isLetter && !$0.isNumber }
        let oldWords = partial.lowercased().split { !$0.isLetter && !$0.isNumber }
        let timedRollover = (audioEnd ?? 0) > 0 && (end ?? 0) == 0 &&
            !newWords.starts(with: oldWords) && now - timedAt > 0.2
        // Streaming results on macOS 26 report zero timings until a segment
        // stabilizes, then reset both timings and text for the next sentence.
        let disjointSpan = (audioEnd ?? 0) > 0 && (start ?? 0) > (audioStart ?? 0) + 0.35 &&
            (start ?? 0) >= (audioEnd ?? 0) - 0.15
        if !partial.isEmpty && (timedRollover || disjointSpan) { commitSegment() }
        update(value, at: now)
        if (end ?? 0) > 0 { timedAt = now }
        if (end ?? 0) > 0 || newWords != oldWords { audioStart = start; audioEnd = end }
    }
    mutating func voice(at now: TimeInterval) { lastVoiceAt = now }
    mutating func commitSegment() {
        if !partial.isEmpty { segments.append(partial) }
        partial = ""; audioStart = nil; audioEnd = nil
    }
    var silenceRequired: TimeInterval {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let incomplete = [" and", " and then", " then", " to", " for", " in", " into", " on", " the", " a", " open", " type", " write", " search for", " click", " press", " select", " can you", " could you", " let's", " make", " set", " say", " called", " named", " inside", " once you're there", " and um"]
        return incomplete.contains(where: normalized.hasSuffix) || ["open", "type", "write", "search", "click", "press"].contains(normalized) ? 2.6 : 0.8
    }
    func shouldFinish(at now: TimeInterval) -> Bool {
        guard !text.isEmpty else { return false }
        return now - (explicitEnd ? lastTextAt : max(lastTextAt, lastVoiceAt)) >= (explicitEnd ? 0.18 : silenceRequired)
    }
    mutating func reset() { self = UtteranceBuffer() }
}
