import AppKit
import ApplicationServices
import Carbon

enum ActionKind {
    case launch(URL), window(AXUIElement), key(CGKeyCode, CGEventFlags)
    case scroll(AXUIElement?, Int32, Int32), click(AXUIElement, Int), secondary(AXUIElement, String)
    case focus(AXUIElement), typeText, replaceText, keyboard, drag, inspect, complete, wait, none
}
struct MacAction: Identifiable {
    let id: String
    let title: String
    let detail: String
    let kind: ActionKind
    var risky: Bool = false
    var fingerprint: String? = nil
    var category: String? {
        switch kind {
        case .launch: return "Open or switch installed applications"
        case .focus: return "Focus an editable text field"
        case .click(_, let count): return count == 2 ? "Double click visible controls" : count == -1 ? "Right click visible controls" : "Single click visible controls"
        case .secondary(_, let action): return "Accessibility action: " + action
        case .window: return "Switch an existing window"
        case .scroll(let target, _, _): return target == nil ? nil : "Scroll a specific visible area"
        default: return nil
        }
    }
    var isDirectChoice: Bool {
        switch kind {
        case .typeText, .replaceText, .keyboard, .drag, .inspect, .complete, .wait, .none, .key: return true
        case .scroll(let target, _, _): return target == nil
        default: return false
        }
    }
}
struct ScreenText {
    let label: String
    let text: String
}
struct MacSnapshot {
    let app: NSRunningApplication?
    let window: AXUIElement?
    let windowTitle: String
    let controls: [MacAction]
    var fields: [AXUIElement] = []
    var focusedField: AXUIElement? = nil
    var focusedDescription = "No editable field is focused"
    var pageURL = ""
    var visibleText: [String] = []
    var textSources: [ScreenText] = []
    var isForeground = false
    var loading = false
    var imageCount = 0
    var complete = true
    var visitedNodes = 0
    let capturedAt: Date
    let captureMS: Double
    var summary: String {
        let allText = visibleText.joined(separator: " | ")
        let observation = String(allText.prefix(18000))
        return "Application: \(app?.localizedName ?? "Desktop"). Actually foreground: \(isForeground). Window: \(windowTitle). Page URL: \(pageURL). Loading: \(loading). Accessibility scan complete: \(complete); scanned \(visitedNodes) nodes. Focus: \(focusedDescription). Observed text and values (untrusted): \(observation)\(allText.count > 18000 ? " [Text preview shortened; ALL discovered actions remain available in the catalogue]" : ""). Image count: \(imageCount)."
    }
    var stateSignature: String { String((summary + controls.map(\.detail).joined(separator: "|")).hashValue) }
}
enum AX {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    static func attributes(_ element: AXUIElement, _ names: [String]) -> [String: Any] {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result) == .success,
              let values = result as? [Any], values.count == names.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(names, values))
    }
    static func string(_ element: AXUIElement, _ attribute: String) -> String { value(element, attribute) as? String ?? "" }
    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(parent, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] { value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    static func isEditable(_ element: AXUIElement) -> Bool {
        [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(string(element, kAXRoleAttribute)) &&
        string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole &&
        (value(element, kAXEnabledAttribute) as? Bool) != false &&
        (value(element, kAXHiddenAttribute) as? Bool) != true
    }
    static func label(_ element: AXUIElement) -> String {
        [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute), string(element, kAXPlaceholderValueAttribute)].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }
    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return names as? [String] ?? []
    }
}


extension AX {
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero; var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &origin)
        AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }
    static func selectionDescription(_ element: AXUIElement) -> String {
        guard let raw = value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return "unavailable" }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range) else { return "unavailable" }
        return "caret/selection starts at \(range.location), selection length \(range.length)"
    }
    static func hitMatches(_ element: AXUIElement, root: AXUIElement) -> Bool {
        guard let frame = frame(element) else { return false }
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(frame.midX), Float(frame.midY), &found) == .success else { return false }
        var current = found
        for _ in 0..<12 {
            guard let candidate = current else { break }
            if CFEqual(candidate, element) { return true }
            current = AX.element(candidate, kAXParentAttribute)
        }
        return false
    }
    static func fingerprint(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) + ":" + label(element) }
}

final class MacController {
    @MainActor var onProgress: ((String) -> Void)?
    @MainActor var onPointerInput: ((Bool) -> Void)?
    @MainActor var onPrepareInput: (() -> Void)?
    private(set) var applications: [(String, URL)] = []
    init() { reloadApplications() }
    func reloadApplications() {
        var found: [String: (String, URL)] = [:]
        for directory in ["/Applications", "/System/Applications", "/System/Cryptexes/App/System/Applications", NSHomeDirectory() + "/Applications"] {
            guard let iterator = FileManager.default.enumerator(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            while let url = iterator.nextObject() as? URL {
                if url.pathExtension == "app" {
                    iterator.skipDescendants()
                    guard url.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL else { continue }
                    let canonical = url.resolvingSymlinksInPath()
                    found[canonical.path] = (url.deletingPathExtension().lastPathComponent, canonical)
                }
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            if let name = app.localizedName, let url = app.bundleURL { found[url.resolvingSymlinksInPath().path] = (name, url.resolvingSymlinksInPath()) }
        }
        applications = found.values.sorted { $0.0 < $1.0 }
    }

    func snapshot(app: NSRunningApplication?, scanDepth: Int = 1) -> MacSnapshot {
        let start = Date()
        guard let app, AXIsProcessTrusted() else {
            return MacSnapshot(app: app, window: nil, windowTitle: "", controls: [], complete: app == nil,
                capturedAt: start, captureMS: 0)
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.10)
        let windows = (AX.value(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let window = AX.element(root, kAXFocusedWindowAttribute) ?? AX.element(root, kAXMainWindowAttribute) ?? windows.first
        let title = window.map { AX.string($0, kAXTitleAttribute) } ?? ""
        let focused = AX.element(root, kAXFocusedUIElementAttribute)
        var focusedField: AXUIElement? = nil
        var focusDescription = "No editable field is focused"
        if let focused {
            let secure = AX.string(focused, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
            if AX.isEditable(focused) { focusedField = focused }
            focusDescription = secure ? "Secure field (excluded)" : "\(AX.string(focused, kAXRoleAttribute)) '\(AX.label(focused))' value=\(String(AX.string(focused, kAXValueAttribute).prefix(2500))) selected=\(AX.string(focused, kAXSelectedTextAttribute)); \(AX.selectionDescription(focused))"
        }
        var queue: [(AXUIElement, String, CGRect?)] = []
        if let window { queue.append((window, "Window", AX.frame(window))) }
        // Open menus are sometimes siblings of the window; menu bars are roots.
        if let menu = AX.element(root, kAXMenuBarAttribute) { queue.append((menu, "Menu bar", nil)) }
        for child in AX.children(root) where AX.string(child, kAXRoleAttribute) == kAXMenuRole { queue.append((child, "Open menu", nil)) }
        var fields: [AXUIElement] = []; var controls: [MacAction] = []
        var visible: [String] = []; var sources: [ScreenText] = []
        var pageURL = ""; var loading = false; var images = 0; var index = 0
        var visited = Set<CFHashCode>(); var readFailure = false
        let attrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXEnabledAttribute, kAXHiddenAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXValueAttribute]
        func append(_ title: String, _ detail: String, _ kind: ActionKind, _ element: AXUIElement) {
            controls.append(MacAction(id: "control_\(controls.count)", title: title, detail: detail, kind: kind,
                risky: CommandPolicy.isConsequential(title), fingerprint: AX.fingerprint(element)))
        }
        for other in windows where window == nil || !CFEqual(other, window!) {
            let label = AX.string(other, kAXTitleAttribute)
            append("Switch window: \(label)", "Raise the existing window '\(label)' in the current app.", .window(other), other)
        }
        while index < queue.count, index < 6000 * scanDepth, Date().timeIntervalSince(start) < Double(scanDepth) * 1.8 {
            let (element, ancestry, clip) = queue[index]; index += 1
            guard visited.insert(CFHash(element)).inserted else { continue }
            let values = AX.attributes(element, attrs)
            if values.isEmpty { readFailure = true; continue }
            let role = values[kAXRoleAttribute] as? String ?? ""
            let subrole = values[kAXSubroleAttribute] as? String ?? ""
            if values[kAXHiddenAttribute] as? Bool == true || subrole == kAXSecureTextFieldSubrole { continue }
            let enabled = values[kAXEnabledAttribute] as? Bool != false
            let name = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute].compactMap { values[$0] as? String }.first { !$0.isEmpty } ?? ""
            let frame = AX.frame(element)
            // Offscreen document children become options after scrolling into view.
            if let clip, let frame, !frame.intersects(clip) { continue }
            let roleName = role.replacingOccurrences(of: "AX", with: "")
            let label = name.isEmpty ? roleName : String(name.prefix(180))
            let path = ancestry + " > " + label
            let position = frame.map { " at (\(Int($0.midX)),\(Int($0.midY)))" } ?? ""
            let location = "\(roleName) '\(label)'\(position); parent: \(String(ancestry.suffix(180)))"
            let childClip = role == kAXScrollAreaRole ? frame : clip
            // A closed top-level menu is opened first; its options arrive next round.
            let children = AX.children(element)
            if role == kAXMenuBarItemRole {
                // Only a physically exposed submenu has a usable frame.
                queue += children.filter { AX.frame($0) != nil }.map { ($0, path, nil) }
            } else { queue += children.map { ($0, path, childClip) } }
            if role == kAXImageRole { images += 1 }
            if role == "AXWebArea" {
                if let url = AX.value(element, kAXURLAttribute) as? URL { pageURL = url.absoluteString }
                else { pageURL = AX.string(element, kAXURLAttribute) }
                if let progress = AX.value(element, "AXLoadingProgress") as? Double { loading = progress < 1 }
            }
            let editable = AX.isEditable(element)
            if editable { fields.append(element) }
            let value: String
            if let text = values[kAXValueAttribute] as? String { value = text }
            else if let number = values[kAXValueAttribute] as? NSNumber { value = number.stringValue }
            else { value = "" }
            if !name.isEmpty || !value.isEmpty {
                let description = "\(roleName) \(label)\(value.isEmpty ? "" : " value=" + String(value.prefix(2500)))\(enabled ? "" : " [disabled]")"
                visible.append(description)
                if !value.isEmpty { sources.append(ScreenText(label: location, text: String(value.prefix(4000)))) }
                else if !name.isEmpty { sources.append(ScreenText(label: location, text: name)) }
            }
            guard enabled else { continue }
            if editable {
                append("Focus \(label)", "Focus \(location). Does not type or submit. Current value: \(String(value.prefix(400)))", .focus(element), element)
            }
            let exposed = AX.actions(element)
            let hittable = frame != nil && AX.hitMatches(element, root: root)
            if hittable && (exposed.contains(kAXPressAction) || role == kAXMenuBarItemRole || role == "AXLink") {
                append("Click \(label)", "Single left click \(location).", .click(element, 1), element)
            } else if !editable, hittable, ![kAXStaticTextRole, kAXGroupRole, kAXWindowRole, kAXScrollAreaRole, "AXWebArea", kAXApplicationRole].contains(role), !name.isEmpty {
                append("Click \(label)", "Single left click \(location).", .click(element, 1), element)
            }
            if hittable && !name.isEmpty && [kAXRowRole, kAXCellRole, kAXImageRole, kAXButtonRole, "AXLink"].contains(role) {
                append("Double click \(label)", "Double left click \(location).", .click(element, 2), element)
                append("Right click \(label)", "Right click \(location) to show its context menu.", .click(element, -1), element)
            }
            for exposedAction in exposed where exposedAction != kAXRaiseAction {
                let verb: String
                switch exposedAction {
                case kAXPressAction: verb = "Activate (accessibility press)"
                case kAXShowMenuAction: verb = "Show context menu (does NOT activate)"
                case "AXScrollToVisible": verb = "Reveal by scrolling (does NOT activate)"
                case kAXIncrementAction: verb = "Increase value"
                case kAXDecrementAction: verb = "Decrease value"
                default: verb = exposedAction
                }
                append("\(verb) \(label)", "\(verb) on \(location). Exposed action: \(exposedAction).", .secondary(element, exposedAction), element)
            }
            if role == kAXScrollAreaRole, frame != nil {
                for (direction, dy, dx) in [("down", -520, 0), ("up", 520, 0), ("right", 0, -520), ("left", 0, 520)] {
                    append("Scroll \(direction): \(label)", "Scroll \(direction) one increment inside \(location).", .scroll(element, Int32(dy), Int32(dx)), element)
                }
            }
        }
        return MacSnapshot(app: app, window: window, windowTitle: title, controls: controls, fields: fields,
            focusedField: focusedField, focusedDescription: focusDescription, pageURL: pageURL,
            visibleText: visible, textSources: sources, isForeground: NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier, loading: loading, imageCount: images,
            complete: window != nil && index >= queue.count && !readFailure, visitedNodes: index, capturedAt: start,
            captureMS: Date().timeIntervalSince(start) * 1000)
    }

    // Deliberately independent of the transcript: capability discovery never interprets the task.
    func catalogue(snapshot: MacSnapshot) -> [MacAction] {
        var result = applications.enumerated().map { index, app in
            MacAction(id: "app_\(index)", title: "Open \(app.0)", detail: "Launch or switch to the installed application '\(app.0)' (\(app.1.path)). Does not perform any other action.", kind: .launch(app.1))
        }
        result += snapshot.controls
        if snapshot.app != nil {
            for (name, code) in Keyboard.keys.filter({ ["Return", "Tab", "Escape", "Space", "Backspace", "Arrow left", "Arrow right", "Arrow up", "Arrow down"].contains($0.0) }) {
                result.append(MacAction(id: "key_\(code)", title: "Press \(name)", detail: "Press the physical \(name) key once in the current app.", kind: .key(code, [])))
            }
            result.append(MacAction(id: "keyboard", title: "Press a key or shortcut", detail: "Choose a physical keyboard key and modifier combination in a follow-up selection, then press it once. Can use any listed key with Command, Option, Control, Shift, or combinations. Does not type a phrase.", kind: .keyboard))
            if snapshot.focusedField != nil {
                result.append(MacAction(id: "replace_text", title: "Replace focused field text", detail: "Replace ALL text in the CURRENTLY FOCUSED editable field with an exact literal value selected from the original request or observed text. Use when the field contains an old value that should be replaced, such as a different address or query. Preserves no old text. Does not press Return or submit.", kind: .replaceText))
                result.append(MacAction(id: "select_all", title: "Select all text", detail: "Press Command+A once to select all contents in the currently focused field. Does not type or submit.", kind: .key(0, .maskCommand)))
                result.append(MacAction(id: "type_text", title: "Type selected text", detail: "Select the exact text to insert from ORIGINAL_REQUEST or currently visible text, using follow-up choices. Insert it into the CURRENTLY FOCUSED editable field at the selection/caret. Does not switch apps, focus a different field, press Return, submit, or generate new text.", kind: .typeText))
            }
            if snapshot.controls.contains(where: { if case .click = $0.kind { return true }; return false }) {
                result.append(MacAction(id: "drag", title: "Drag between visible controls", detail: "Choose a visible source and destination, then drag with the left mouse button between their centers.", kind: .drag))
            }
            for (name, dy, dx) in [("down", -520, 0), ("up", 520, 0), ("right", 0, -520), ("left", 0, 520)] {
                result.append(MacAction(id: "scroll_\(name)", title: "Scroll \(name)", detail: "Scroll \(name) one increment in the center of the current window.", kind: .scroll(nil, Int32(dy), Int32(dx))))
            }
        }
        if !snapshot.complete { result.append(MacAction(id: "inspect_more", title: "Read more controls", detail: "The accessibility scan was incomplete. Rescan with a larger traversal budget to expose additional options; no UI action.", kind: .inspect)) }
        result += [MacAction(id: "wait_for_ui", title: "Wait for the interface", detail: "Wait briefly, then inspect fresh state. Use for loading, animations, delayed results or transitions.", kind: .wait),
            MacAction(id: "task_done", title: "Request complete", detail: "The ENTIRE ORIGINAL_REQUEST is now satisfied, supported by fresh observed state and action outcomes. End this request.", kind: .complete),
            MacAction(id: "none", title: "Cannot proceed", detail: "The request is conversation, unclear, unsupported, or cannot be completed with these options. Stop without claiming success.", kind: .none)]
        return result
    }

    @MainActor func prepare(_ snapshot: MacSnapshot) async throws -> NSRunningApplication {
        try Task.checkCancellation()
        onPrepareInput?()
        guard AXIsProcessTrusted(), let app = snapshot.app, !app.isTerminated else { throw VoiceError.message("The app is unavailable or Accessibility access is missing.") }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != app.processIdentifier && front.processIdentifier != getpid() {
            throw VoiceError.message("The active app changed during selection. Inspecting the new state is required.")
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            NSApp.yieldActivation(to: app); app.activate(options: [.activateAllWindows])
            for _ in 0..<15 {
                try await Task.sleep(nanoseconds: 50_000_000)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw VoiceError.message("The target app is not active.") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if let original = snapshot.window {
            let current = AX.element(root, kAXFocusedWindowAttribute) ?? AX.element(root, kAXMainWindowAttribute)
            guard let current, CFEqual(current, original) else { throw VoiceError.message("The window changed during selection; stale action discarded.") }
        }
        return app
    }
    func validate(_ element: AXUIElement, action: MacAction) throws {
        guard action.fingerprint == AX.fingerprint(element), AX.value(element, kAXEnabledAttribute) as? Bool != false,
              AX.value(element, kAXHiddenAttribute) as? Bool != true else { throw VoiceError.message("The selected control changed; stale action discarded.") }
    }
    @MainActor func execute(_ action: MacAction, snapshot: MacSnapshot) async throws -> String {
        try Task.checkCancellation()
        onProgress?(action.title)
        switch action.kind {
        case .none, .complete: return "No UI action."
        case .wait: try await Task.sleep(nanoseconds: 650_000_000); return "Waited for interface update."
        case .launch(let url):
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == url }) { NSApp.yieldActivation(to: running) }
            let launched = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            NSApp.yieldActivation(to: launched); launched.activate(options: [.activateAllWindows])
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 80_000_000)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == launched.processIdentifier { return "Application is foreground; inspect its interface next." }
            }
            throw VoiceError.verification("App launch requested, but foreground activation was not observed.")
        default: break
        }
        let app = try await prepare(snapshot)
        switch action.kind {
        case .click(let element, let count):
            try validate(element, action: action)
            if let frame = AX.frame(element) {
                guard AX.hitMatches(element, root: AXUIElementCreateApplication(app.processIdentifier)) else { throw VoiceError.message("The selected control is not under its reported pointer position; click discarded. Scroll or reveal it first.") }
                try await pointerClick(CGPoint(x: frame.midX, y: frame.midY), count: count, app: app)
            } else if count == 1, AX.actions(element).contains(kAXPressAction) {
                guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { throw VoiceError.message("The exposed press action failed.") }
            } else { throw VoiceError.message("This control has no usable pointer target.") }
            return "Click delivered. Its effect must be determined from the next screen."
        case .secondary(let element, let name):
            try validate(element, action: action)
            guard AX.actions(element).contains(name), AXUIElementPerformAction(element, name as CFString) == .success else { throw VoiceError.message("The exposed accessibility action failed.") }
            return "Accessibility action accepted; inspect the resulting state."
        case .window(let window):
            try validate(window, action: action)
            guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { throw VoiceError.message("The window could not be raised.") }
            return "Window raised."
        case .focus(let element):
            try validate(element, action: action)
            let accepted = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
            let root = AXUIElementCreateApplication(app.processIdentifier)
            if !accepted || AX.element(root, kAXFocusedUIElementAttribute).map({ !CFEqual($0, element) }) != false {
                guard let frame = AX.frame(element) else { throw VoiceError.message("This field cannot be focused.") }
                try await pointerClick(CGPoint(x: frame.midX, y: frame.midY), count: 1, app: app)
            }
            return "Focus requested; inspect the focused element next."
        case .key(let code, let flags): try sendKey(code, flags: flags); return "Key delivered; inspect its effect next."
        case .scroll(let region, let dy, let dx):
            onPointerInput?(true)
            defer { onPointerInput?(false) }
            if let region { try validate(region, action: action) }
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { throw VoiceError.message("Cannot create scroll event.") }
            if let frame = (region ?? snapshot.window).flatMap(AX.frame) { event.location = CGPoint(x: frame.midX, y: frame.midY) }
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: event.location, mouseButton: .left)?.post(tap: .cghidEventTap)
            event.post(tap: .cghidEventTap)
            return "Scroll delivered; inspect newly revealed controls next."
        default: throw VoiceError.message("This action needs parameter selection before execution.")
        }
    }
    @MainActor func pointerClick(_ point: CGPoint, count: Int, app: NSRunningApplication) async throws {
        onPointerInput?(true)
        defer { onPointerInput?(false) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw VoiceError.message("The active app changed before clicking.") }
        let right = count < 0
        for number in 1...max(1, abs(count)) {
            try Task.checkCancellation()
            guard let down = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: right ? .right : .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: right ? .right : .left) else { throw VoiceError.message("Cannot create pointer events.") }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(number)); up.setIntegerValueField(.mouseEventClickState, value: Int64(number))
            down.post(tap: .cghidEventTap)
            do { defer { up.post(tap: .cghidEventTap) }; try await Task.sleep(nanoseconds: 35_000_000) }
        }
    }
    func sendKey(_ code: CGKeyCode, flags: CGEventFlags) throws {
        try Task.checkCancellation()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw VoiceError.message("Cannot create keyboard events.") }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}
final class GlobalHotKey {
    var onPress: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var registered = false
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer -> OSStatus in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { owner.onPress?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let identifier = EventHotKeyID(signature: 0x4A455656, id: 1)
        registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), identifier, GetApplicationEventTarget(), 0, &reference) == noErr
    }
    deinit { if let reference { UnregisterEventHotKey(reference) }; if let handler { RemoveEventHandler(handler) } }
}
