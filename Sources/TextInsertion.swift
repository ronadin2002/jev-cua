import AppKit
import ApplicationServices

extension MacController {
    @MainActor func insertLiteral(_ text: String, snapshot: MacSnapshot, replaceAll: Bool = false) async throws -> String {
        guard !text.isEmpty, text.count <= 4000 else { throw VoiceError.message("Selected text is empty or too long.") }
        let app = try await prepare(snapshot)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let expected = snapshot.focusedField, let focused = AX.element(root, kAXFocusedUIElementAttribute),
              CFEqual(expected, focused), AX.isEditable(focused) else { throw VoiceError.message("The focused field changed while choosing text. Nothing was typed.") }
        let before = AX.string(focused, kAXValueAttribute)
        if replaceAll && !before.isEmpty {
            try sendKey(0, flags: .maskCommand)
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let stillFocused = AX.element(root, kAXFocusedUIElementAttribute), CFEqual(focused, stillFocused),
                  let raw = AX.value(focused, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
                throw VoiceError.message("Could not verify full-field selection. Nothing was typed.")
            }
            var selected = CFRange()
            guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &selected), selected.location == 0,
                  selected.length == (before as NSString).length else { throw VoiceError.message("The whole field was not selected. Nothing was typed.") }
        }
        let selectedText = AX.string(focused, kAXSelectedTextAttribute)
        var expectedValue: String? = nil
        if let rawRange = AX.value(focused, kAXSelectedTextRangeAttribute), CFGetTypeID(rawRange) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(unsafeBitCast(rawRange, to: AXValue.self), .cfRange, &range), range.location >= 0, range.length >= 0,
               range.location + range.length <= (before as NSString).length {
                expectedValue = (before as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
            }
        }
        if replaceAll { expectedValue = text }
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        board.clearContents()
        guard board.setString(text, forType: .string) else { throw VoiceError.message("Could not prepare literal text.") }
        let count = board.changeCount
        defer {
            if board.changeCount == count {
                board.clearContents()
                let items = saved.map { representations in let item = NSPasteboardItem(); for (type, data) in representations { item.setData(data, forType: type) }; return item }
                if !items.isEmpty { board.writeObjects(items) }
            }
        }
        try sendKey(9, flags: .maskCommand)
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 75_000_000)
            let after = AX.string(focused, kAXValueAttribute)
            let verified = expectedValue.map { after == $0 } ?? (after.contains(text) && (after != before || selectedText == text))
            if verified { return "Inserted exact text: \(text). Field value verified. Return was NOT pressed." }
        }
        throw VoiceError.verification("Text was sent, but the field value could not be verified. Stopped to avoid duplicate typing.")
    }
    @MainActor func drag(_ source: MacAction, to destination: MacAction, snapshot: MacSnapshot) async throws -> String {
        let app = try await prepare(snapshot)
        onPointerInput?(true)
        defer { onPointerInput?(false) }
        func element(_ action: MacAction) -> AXUIElement? { switch action.kind { case .click(let e, _), .focus(let e): return e; default: return nil } }
        guard let a = element(source), let b = element(destination) else { throw VoiceError.message("Invalid drag targets.") }
        try validate(a, action: source); try validate(b, action: destination)
        guard let first = AX.frame(a), let last = AX.frame(b) else { throw VoiceError.message("Drag target positions are unavailable.") }
        let start = CGPoint(x: first.midX, y: first.midY); let end = CGPoint(x: last.midX, y: last.midY)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else { throw VoiceError.message("Cannot create drag events.") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw VoiceError.message("The active app changed.") }
        down.post(tap: .cghidEventTap)
        defer { up.post(tap: .cghidEventTap) }
        for step in 1...12 {
            try Task.checkCancellation()
            let t = CGFloat(step) / 12
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: start.x + (end.x-start.x)*t, y: start.y + (end.y-start.y)*t), mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return "Drag delivered from \(source.title) to \(destination.title); inspect its result next."
    }
}
