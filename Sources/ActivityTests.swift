import Foundation

// Local HTTP fixtures exercise the real JevClient lifecycle without paid calls or computer actions.
final class ActivityFixtureProtocol: URLProtocol {
    static var scenario = "success"
    static var attempts = 0
    static var routingCriteria: [String: String] = [:]
    static var routingChoice = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.attempts += 1
        if Self.scenario == "timeout" || Self.scenario == "cancelled" {
            client?.urlProtocol(self, didFailWithError: URLError(Self.scenario == "timeout" ? .timedOut : .cancelled)); return
        }
        let status = Self.scenario == "credits" ? 402 : Self.scenario == "recover" && Self.attempts == 1 ? 503 : 200
        let body: String
        switch Self.scenario {
        case "routing":
            let probabilities = Self.routingCriteria.mapValues { _ in 0.0 }.merging([Self.routingChoice: 1.0]) { _, new in new }
            let object: [String: Any] = ["model": "typesafe/jev-test", "answers": ["next_action": ["type": "choice", "choice": Self.routingChoice, "confidence": 1.0, "probabilities": probabilities]]]
            body = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        case "credits": body = #"{"error":{"message":"Insufficient credits","metadata":{"limit_source":"openrouter_credits"}}}"#
        case "malformed": body = "not a JSON response"
        case "invalid_choice": body = #"{"model":"typesafe/jev-test","answers":{"next_action":{"type":"choice","choice":"absent","confidence":1,"probabilities":{"absent":1}}}}"#
        default: body = #"{"model":"typesafe/jev-test","answers":{"next_action":{"type":"choice","choice":"yes","confidence":0.9,"probabilities":{"yes":0.9,"no":0.1}}}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum ActivityTests {
    @MainActor static func run() async {
        let raw = #"{"confidence":0.74,"cost":1.5246e-05,"literal":"A {bracket}, a \"quote\" and \\ slash","empty":{},"items":[1,2]}"#
        let displayed = JevCallRecord.formatted(Data(raw.utf8))
        precondition(displayed.contains("0.74") && displayed.contains("1.5246e-05"))
        let original = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! NSDictionary
        let formatted = try! JSONSerialization.jsonObject(with: Data(displayed.utf8)) as! NSDictionary
        precondition(original == formatted)
        print("PASS: readable JSON preserves literal values, numeric spelling and escaped text.")
        for scenario in ["success", "credits", "malformed", "invalid_choice", "timeout", "cancelled"] {
            ActivityFixtureProtocol.scenario = scenario
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ActivityFixtureProtocol.self]
            let client = JevClient(configuration: config, maxRetries: 0)
            var events: [JevCallRecord] = []
            var exchanges: [[String: Any]] = []
            client.onActivity = { events.append($0) }
            client.onExchange = { exchanges.append($0) }
            do {
                let answer = try await client.choose(transcript: "Fixture command with café 👋", context: "Fixture screen",
                    criteria: ["yes": "Yes", "no": "No"], key: "fixture-authorization-secret")
                precondition(scenario == "success" && answer.actionID == "yes")
                precondition(answer.requestID == events.first?.id)
            } catch { precondition(scenario != "success") }
            precondition(events.count == 2 && events[0].pending && !events[1].pending)
            precondition(events[0].id == events[1].id && events[0].input == events[1].input)
            precondition(events[1].input.contains("café 👋") && !events[1].input.contains("fixture-authorization-secret"))
            precondition(exchanges.count == 1 && exchanges[0]["input"] != nil)
            precondition((events[1].error == nil) == (scenario == "success"))
            if scenario == "credits" { precondition(events[1].httpStatus == 402 && events[1].output!.contains("Insufficient credits")) }
            if scenario == "malformed" { precondition(events[1].output == "not a JSON response") }
            if scenario == "timeout" || scenario == "cancelled" { precondition(events[1].output == nil && events[1].status == (scenario == "timeout" ? "Timed out" : "Cancelled")) }
            print("PASS: activity records input, pending state and final output/error for \(scenario).")
        }
        ActivityFixtureProtocol.scenario = "recover"; ActivityFixtureProtocol.attempts = 0
        let recoveryConfig = URLSessionConfiguration.ephemeral
        recoveryConfig.protocolClasses = [ActivityFixtureProtocol.self]
        let recovery = JevClient(configuration: recoveryConfig)
        var retries: [JevCallRecord] = []
        recovery.onActivity = { if !$0.pending { retries.append($0) } }
        do {
            let answer = try await recovery.choose(transcript: "recover", context: "fixture", criteria: ["yes": "Yes", "no": "No"], key: "fixture")
            precondition(answer.actionID == "yes" && retries.count == 2 && retries[0].httpStatus == 503 && retries[1].httpStatus == 200)
        } catch { preconditionFailure("Transient recovery failed: \(error)") }
        ActivityFixtureProtocol.scenario = "credits"; ActivityFixtureProtocol.attempts = 0
        do { _ = try await recovery.choose(transcript: "credits", context: "fixture", criteria: ["yes": "Yes", "no": "No"], key: "fixture"); preconditionFailure() } catch {}
        precondition(ActivityFixtureProtocol.attempts == 1)
        print("PASS: transient failures recover automatically; billing failures never retry; each attempt is traced.")
        ActivityFixtureProtocol.scenario = "routing"; ActivityFixtureProtocol.attempts = 0
        let routing = JevClient(configuration: recoveryConfig)
        var leaves = (0..<3990).map { ChoiceOption(id: "button_\($0)", description: "Click button \($0)", summary: "Button \($0)", category: "Buttons") }
        leaves += (0..<10).map { ChoiceOption(id: "app_\($0)", description: "Open application \($0)", category: "Apps") }
        var route = ["category_0", "app_9"]
        routing.onActivity = { call in
            guard call.pending else { return }
            let payload = try! JSONSerialization.jsonObject(with: Data(call.input.utf8)) as! [String: Any]
            let questions = payload["questions"] as! [String: [String: Any]]
            ActivityFixtureProtocol.routingCriteria = questions["next_action"]!["criteria"] as! [String: String]
            precondition(!route.isEmpty)
            ActivityFixtureProtocol.routingChoice = route.removeFirst()
        }
        do {
            let answer = try await routing.select(options: leaves, request: "Open application 9", screen: "Desktop", history: "No actions", key: "fixture")
            precondition(answer.actionID == "app_9" && ActivityFixtureProtocol.attempts == 2 && route.isEmpty)
        } catch { preconditionFailure("Bounded routing failed: \(error)") }
        print("PASS: 4,000 discovered options route to a concrete action in two calls, with no batch fanout.")
        var history = JevCallHistory(capacity: 2)
        var first = JevCallRecord(stage: "First", command: "one", input: "{}", optionCount: 2)
        var second = JevCallRecord(stage: "Second", command: "two", input: "{}", optionCount: 2)
        history.receive(first); history.receive(second)
        second.milliseconds = 10; second.output = "second response"
        history.receive(second)
        first.milliseconds = 20; first.output = "first response"
        history.receive(first)
        precondition(history.calls.map(\.number) == [1, 2])
        precondition(history.calls.map(\.output) == ["first response", "second response"])
        history.outcome(for: first.id, "Observed result")
        precondition(history.calls[0].outcome == "Observed result")
        let third = JevCallRecord(stage: "Third", command: "three", input: "{}", optionCount: 2)
        history.receive(third)
        precondition(history.calls.map(\.number) == [2, 3] && history.calls.last!.pending)
        print("PASS: overlapping requests preserve their own input/output, stable order, retention and observed results.")
    }
}
