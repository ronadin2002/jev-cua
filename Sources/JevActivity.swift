import AppKit
import SwiftUI

struct JevCallRecord: Identifiable {
    let id = UUID()
    var number = 0
    let startedAt = Date()
    let stage: String
    let command: String
    let input: String
    let optionCount: Int
    var output: String?
    var httpStatus: Int?
    var error: String?
    var milliseconds: Double?
    var answers = ""
    var outcome: String?
    var endpoint: String? = nil
    var pending: Bool { milliseconds == nil }
    var status: String {
        if pending { return "Waiting for Jev" }
        if let httpStatus { return "HTTP \(httpStatus)" + (error == nil ? "" : " · Failed") }
        if let error {
            if error.lowercased().contains("cancel") { return "Cancelled" }
            if error.lowercased().contains("timed out") { return "Timed out" }
            return "Connection failed"
        }
        return "No HTTP response"
    }
    static func formatted(_ data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return raw }
        // Add whitespace only: preserve the provider's exact numbers, escapes and field order.
        var result = "", depth = 0, quoted = false, escaped = false
        var previous: Character?
        for character in raw {
            if quoted {
                result.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
                continue
            }
            if character.isWhitespace { continue }
            switch character {
            case "\"": quoted = true; result.append(character)
            case "{", "[":
                result.append(character); depth += 1
                result += "\n" + String(repeating: "  ", count: depth)
            case "}", "]":
                depth = max(0, depth - 1)
                while result.last?.isWhitespace == true { result.removeLast() }
                if previous != "{" && previous != "[" { result += "\n" + String(repeating: "  ", count: depth) }
                result.append(character)
            case ",": result += ",\n" + String(repeating: "  ", count: depth)
            case ":": result += ": "
            default: result.append(character)
            }
            previous = character
        }
        return result
    }
}

struct JevCallHistory {
    private(set) var calls: [JevCallRecord] = []
    private(set) var total = 0
    let capacity: Int
    init(capacity: Int = 300) { self.capacity = max(1, capacity) }
    mutating func outcome(for id: UUID?, _ text: String) {
        guard let id, let index = calls.firstIndex(where: { $0.id == id }) else { return }
        calls[index].outcome = text
    }
    mutating func receive(_ record: JevCallRecord) {
        if let index = calls.firstIndex(where: { $0.id == record.id }) {
            var updated = record; updated.number = calls[index].number
            calls[index] = updated
        } else {
            total += 1
            var numbered = record; numbered.number = total
            calls.append(numbered)
        }
        // Never drop an in-flight request, even when parallel batches finish out of order.
        while calls.count > capacity, let index = calls.firstIndex(where: { !$0.pending }) {
            calls.remove(at: index)
        }
    }
}

struct JevActivityView: View {
    @ObservedObject var model: AppModel
    @State private var selectedID: UUID?
    @State private var followLatest = true
    @State private var bodyTab = "Input"
    private var selected: JevCallRecord? {
        if followLatest { return model.jevHistory.calls.last }
        return model.jevHistory.calls.first { $0.id == selectedID } ?? model.jevHistory.calls.last
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Jev input & output", systemImage: "arrow.left.arrow.right").font(.system(size: 17, weight: .semibold))
                Spacer()
                Toggle("Follow latest", isOn: Binding(get: { followLatest }, set: { enabled in
                    if !enabled { selectedID = model.jevHistory.calls.last?.id }
                    followLatest = enabled
                })).toggleStyle(.checkbox).font(.system(size: 11))
            }
            Text("Every API call, including option batches, typing choices and completion checks. Last 300 calls from this session; API authorization headers are excluded.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if model.jevHistory.calls.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("No calls yet").font(.headline)
                        Text("Speak a command or check the connection. Its full input appears here immediately, followed by the response.")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Button("Check connection") { model.checkConnection() }
                            .disabled(!model.keyConfigured || model.busy || model.checkingConnection)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.jevHistory.calls.reversed()) { call in
                            Button {
                                selectedID = call.id; followLatest = false
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Text("#\(call.number)").font(.system(size: 11, design: .monospaced)).frame(width: 38, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(call.stage).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(call.command).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(call.status).foregroundStyle(call.error != nil ? .orange : Palette.accent)
                                        Text(call.startedAt, style: .time).foregroundStyle(Palette.muted)
                                    }.font(.system(size: 10, design: .monospaced))
                                }.padding(10).contentShape(Rectangle())
                                    .background(selected?.id == call.id ? Palette.accent.opacity(0.10) : Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).accessibilityLabel("Jev call \(call.number): \(call.stage), \(call.status)")
                        }
                    }
                }.frame(height: CGFloat(min(3, model.jevHistory.calls.count) * 54))
                if let call = selected {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Call #\(call.number) · \(call.stage)").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(call.optionCount) options" + (call.milliseconds.map { " · \(Int($0)) ms" } ?? ""))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                        }
                        Text(call.command).font(.system(size: 12)).textSelection(.enabled)
                        if !call.answers.isEmpty {
                            Text(call.answers).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.accent).textSelection(.enabled)
                        }
                        if let error = call.error {
                            Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        HStack {
                            Picker("Request or response", selection: $bodyTab) {
                                Text("Input to Jev").tag("Input")
                                Text("Output from Jev").tag("Output")
                                Text("Observed result").tag("Result")
                            }.pickerStyle(.segmented).labelsHidden()
                            Button("Copy \(bodyTab.lowercased())") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(bodyText(call), forType: .string)
                            }.font(.system(size: 11))
                        }
                        JSONBodyView(text: bodyText(call), label: bodyTab == "Input" ? "Full Jev request JSON" : bodyTab == "Output" ? "Full Jev response JSON" : "Observed action result")
                            .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 9))
                        Text("POST " + (call.endpoint ?? JevClient.endpoint.absoluteString)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                }
            }
        }
    }
    private func bodyText(_ call: JevCallRecord) -> String {
        if bodyTab == "Input" { return call.input }
        if bodyTab == "Result" { return call.outcome ?? "This call selected or checked an option. No computer action result is attached to this call." }
        return call.output ?? (call.pending ? "Waiting for Jev…" : "No response body was received.\n" + (call.error ?? ""))
    }
}

// NSTextView keeps large catalogues selectable and scrollable without building one SwiftUI view per line.
struct JSONBodyView: NSViewRepresentable {
    let text: String
    let label: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = NSColor(white: 0.88, alpha: 1)
        view.backgroundColor = NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.setAccessibilityLabel(label)
        if view.string != text {
            view.string = text
            view.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }
}
