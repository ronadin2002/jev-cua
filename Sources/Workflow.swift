import Foundation

enum VoiceControl: Equatable {
    case cancelTask, retry, status, stopListening
    static func parse(_ text: String) -> VoiceControl? {
        let command = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        switch command {
        case "cancel task", "cancel that", "cancel", "stop now", "stop": return .cancelTask
        case "try again", "retry", "retry task": return .retry
        case "status", "what are you doing", "what's happening": return .status
        case "stop listening", "turn off the mic", "turn off microphone", "microphone off", "mic off": return .stopListening
        default: return nil
        }
    }
}

struct WorkflowTrace {
    var actions: [String] = []
    var signatures: [String: Int] = [:]
    var lastFailure: String?
    var modelCalls = 0
    static let maximumActions = 48
    static let maximumCalls = 80
    mutating func record(action: String, signature: String) throws {
        actions.append(action)
        signatures[signature, default: 0] += 1
        guard actions.count <= Self.maximumActions else { throw VoiceError.message("Stopped after 48 actions. Say a smaller follow-up request to continue.") }
    }
    func repetitionCount(_ signature: String) -> Int { signatures[signature, default: 0] }
}
