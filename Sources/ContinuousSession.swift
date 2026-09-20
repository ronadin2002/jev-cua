import Foundation

/// One user-controlled mic session can contain any number of separate commands.
struct ContinuousSession {
    enum Accepted: Equatable { case queued, ignored, full, stopped }
    private(set) var enabled = false
    private(set) var commands: [String] = []
    static let capacity = 8
    mutating func start() { enabled = true }
    mutating func clearQueue() { commands.removeAll() }
    mutating func stop() { enabled = false; commands.removeAll() }
    mutating func accept(_ text: String) -> Accepted {
        guard enabled else { return .ignored }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .ignored }
        let normalized = command.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if ["stop listening", "turn off the mic", "turn off microphone", "microphone off", "mic off"].contains(normalized) {
            stop(); return .stopped
        }
        guard commands.count < Self.capacity else { return .full }
        commands.append(command)
        return .queued
    }
    mutating func acceptTyped(_ text: String) -> Accepted {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .ignored }
        guard commands.count < Self.capacity else { return .full }
        commands.append(command); return .queued
    }
    mutating func pauseListening() { enabled = false }
    mutating func next(busy: Bool, reviewing: Bool) -> String? {
        guard !busy, !reviewing, !commands.isEmpty else { return nil }
        return commands.removeFirst()
    }
}
