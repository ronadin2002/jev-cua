import AppKit
import SwiftUI
import Darwin

/// Allows editing without activating Jev over the app being controlled.
final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    var window: NSWindow!
    var overlay: NSPanel!
    var practice: NSWindow?
    var statusItem: NSStatusItem!
    var hotkey: GlobalHotKey!
    var barHidden = false
    var pointerGeneration = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Jev Settings"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Palette.background)
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        overlay = CommandBarPanel(contentRect: NSRect(x: 0, y: 0, width: 488, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.title = "Jev command bar"
        overlay.isOpaque = false; overlay.backgroundColor = .clear; overlay.hasShadow = true
        overlay.level = .floating; overlay.hidesOnDeactivate = false
        overlay.isFloatingPanel = true; overlay.becomesKeyOnlyIfNeeded = true
        overlay.isMovableByWindowBackground = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.tabbingMode = .disallowed
        overlay.contentView = NSHostingView(rootView: CommandBarView(model: model,
            openSettings: { [weak self] in self?.showSettings() },
            releaseKeyboard: { [weak self] in self?.releaseBarKeyboard() }))
        model.showOverlay = { [weak self] in self?.presentOverlay() }
        model.hideOverlay = {} // Pausing the microphone keeps the command bar available.
        model.beforeRequest = { [weak self] in self?.releaseBarKeyboard() }
        model.controller.onPrepareInput = { [weak self] in self?.releaseBarKeyboard() }
        model.controller.onPointerInput = { [weak self] active in
            guard let self else { return }
            self.pointerGeneration += 1
            let generation = self.pointerGeneration
            if active { self.overlay.ignoresMouseEvents = true }
            else {
                // Keep synthetic pointer events from hitting the floating bar.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self, generation == self.pointerGeneration else { return }
                    self.overlay.ignoresMouseEvents = false
                }
            }
        }
        model.showMain = { [weak self] in self?.showSettings() }
        model.showCommandBar = { [weak self] in self?.showCommandCenter() }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in guard self?.barHidden == false else { return }; self?.presentOverlay() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard self?.barHidden == false else { return }; self?.presentOverlay() }
        }
        model.openPractice = { [weak self] in self?.showPractice() }
        model.focusPractice = { [weak self] in self?.practice?.makeKeyAndOrderFront(nil) }
        hotkey = GlobalHotKey()
        hotkey.onPress = { [weak self] in self?.model.toggleListening() }
        model.hotkeyWorking = hotkey.registered
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Jev Voice")
        let menu = NSMenu()
        for (title, selector, key) in [("Show command bar", #selector(showCommandCenter), ""), ("Settings & diagnostics…", #selector(showSettings), ""), ("Toggle microphone  ⌥ Space", #selector(listen), ""), ("Hide command bar", #selector(hideCommandBar), ""), ("Quit Jev Voice", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
        let mainMenu = NSMenu()
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Jev Voice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        let editItem = NSMenuItem(); editItem.submenu = edit; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        if model.keyConfigured && model.microphoneGranted && model.speechGranted && model.accessibilityGranted {
            if !CommandLine.arguments.contains("--diagnostics") { model.toggleListening() }
        } else { model.showSetup = true; showWindow() }
        if CommandLine.arguments.contains("--diagnostics") { model.showSetup = true; showWindow() }
        presentOverlay()
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.statusItem.button?.image = NSImage(systemSymbolName: self.model.busy ? "waveform.circle.fill" : self.model.micEnabled ? "mic.fill" : "mic.slash", accessibilityDescription: "Jev Voice: " + self.model.phase)
                self.statusItem.button?.toolTip = "Jev Voice · " + self.model.phase + " · " + self.model.detail
            }
        }
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showCommandCenter() {
        window.orderOut(nil)
        barHidden = false; presentOverlay()
    }
    @objc func hideCommandBar() { barHidden = true; overlay.orderOut(nil) }
    func releaseBarKeyboard() {
        guard overlay.isKeyWindow else { return }
        overlay.endEditing(for: nil); overlay.makeFirstResponder(nil); overlay.resignKey()
        if !model.practiceActive, let target = model.lastExternalApp, !target.isTerminated {
            NSApp.yieldActivation(to: target)
            target.activate(options: [.activateAllWindows])
        }
    }
    @objc func showSettings() { model.showSetup = true; showWindow() }
    @objc func listen() { model.toggleListening() }
    @objc func quit() { model.cancel(); NSApp.terminate(nil) }
    @objc func showPractice() {
        if practice == nil {
            let view = PracticeView(model: model)
            practice = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 535, height: 465), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            practice?.title = "Jev Voice · Practice"
            practice?.contentView = NSHostingView(rootView: view)
            practice?.isReleasedWhenClosed = false; practice?.delegate = self; practice?.center()
        }
        model.practiceActive = true; model.currentApp = "Practice window"
        practice?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) == practice { model.practiceActive = false }
    }
    func presentOverlay() {
        guard !barHidden, let overlay else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen, !overlay.isVisible || !screen.visibleFrame.contains(CGPoint(x: overlay.frame.midX, y: overlay.frame.midY)) {
            overlay.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - overlay.frame.width / 2,
                y: screen.visibleFrame.maxY - overlay.frame.height - 12))
        }
        overlay.orderFrontRegardless()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showCommandCenter(); return false }
}

@main struct JevVoiceApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--store-key") {
            guard let pointer = getpass("OpenRouter or TypeSafe API key (hidden): ") else { exit(1) }
            do { try KeyStore.save(String(cString: pointer)); memset(pointer, 0, strlen(pointer)); print("Key saved in macOS Keychain."); exit(0) }
            catch { print(error.localizedDescription); exit(1) }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--speech-file-test"), CommandLine.arguments.count > flag + 1 {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    let transcript = try await SpeechFixtureTest().transcribe(URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                    var buffer = UtteranceBuffer(); buffer.update(transcript, at: 0)
                    let steps = [buffer.command]
                    let passed = CommandLine.arguments.contains("--transcribe-only") || ["chrome", "youtube", "search", "piano", "first video"].allSatisfy { transcript.lowercased().contains($0) } && buffer.explicitEnd && steps.count == 1
                    let report: [String: Any] = ["transcript": transcript, "command": buffer.command, "passed": passed, "on_device": true, "explicit_endpoint": buffer.explicitEnd, "steps": steps]
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    if let reportFlag = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > reportFlag + 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[reportFlag + 1])) }
                    print(String(data: data, encoding: .utf8)!)
                    exit(passed ? 0 : 1)
                } catch {
                    if let reportFlag = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > reportFlag + 1,
                       let data = try? JSONSerialization.data(withJSONObject: ["passed": false, "error": error.localizedDescription]) {
                        try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[reportFlag + 1]))
                    }
                    print("FAIL: \(error.localizedDescription)"); exit(1)
                }
            }
            NSApplication.shared.run(); return
        }
        if CommandLine.arguments.contains("--self-test") { SelfTests.run(); exit(0) }
        if CommandLine.arguments.contains("--activity-test") {
            Task { await ActivityTests.run(); exit(0) }
            RunLoop.main.add(Timer(timeInterval: 60, repeats: true) { _ in }, forMode: .default); CFRunLoopRun(); return
        }
        if CommandLine.arguments.contains("--account-status") {
            Task { @MainActor in
                do {
                    guard let key = KeyStore.read() else { throw VoiceError.message("This app could not read its saved Keychain key.") }
                    let status = try await JevClient().accountStatus(key: key)
                    let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
                    print(String(data: data, encoding: .utf8)!); exit(0)
                } catch { print(error.localizedDescription); exit(1) }
            }
            RunLoop.main.add(Timer(timeInterval: 60, repeats: true) { _ in }, forMode: .default); CFRunLoopRun(); return
        }
        if CommandLine.arguments.contains("--router-test") {
            Task { await SelfTests.router(); exit(0) }
            RunLoop.main.add(Timer(timeInterval: 60, repeats: true) { _ in }, forMode: .default); CFRunLoopRun()
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
