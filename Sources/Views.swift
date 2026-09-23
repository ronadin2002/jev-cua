import SwiftUI

enum Palette {
    static let background = Color(red: 0.055, green: 0.066, blue: 0.085)
    static let panel = Color(red: 0.087, green: 0.103, blue: 0.128)
    static let line = Color.white.opacity(0.085)
    static let accent = Color(red: 0.59, green: 0.94, blue: 0.80)
    static let muted = Color(red: 0.57, green: 0.63, blue: 0.68)
}
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line)) }
}
struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "waveform").foregroundStyle(Palette.accent)
                    Text("Settings").font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Button("Back to bar") { model.showCommandBar?() }
                }
                Picker("Settings section", selection: $model.settingsTab) {
                    Text("General").tag("General")
                    Text("Jev activity").tag("Jev activity")
                }.pickerStyle(.segmented).labelsHidden()
                if model.settingsTab == "Jev activity" { JevActivityView(model: model) }
                else {
                    if let issue = model.billingIssue { Text(issue).foregroundStyle(.orange).font(.system(size: 12)) }
                    setup
                }
            }.padding(24)
        }
        .frame(minWidth: 620, minHeight: 530)
        .background(Palette.background).foregroundStyle(.white).preferredColorScheme(.dark)
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisclosureGroup("Voice diagnostics") { Button("Replay audio command…") { model.chooseAudioReplay() }.disabled(model.busy) }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Jev connection", systemImage: "key.fill").font(.system(size: 15, weight: .medium))
                    Text(model.keyConfigured ? "Your API key is stored in macOS Keychain." : "Add your API key. It is stored only in macOS Keychain.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    if model.keyConfigured {
                        DisclosureGroup("Change API key") { keyEntry.padding(.top, 8) }.font(.system(size: 12))
                    } else { keyEntry }
                    Text("Model: \(model.provider.model) via \(model.provider.name)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.accent)
                    connectionActions
                    if !model.connectionDetail.isEmpty { Text(model.connectionDetail).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
                    if !model.keyExpiry.isEmpty { Text(model.keyExpiry).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 13) {
                    Label("Voice & Mac control", systemImage: "hand.raised.fill").font(.system(size: 15, weight: .medium))
                    permissionRow("Microphone + Speech Recognition", description: "Transcribes English speech on this Mac.", enabled: model.microphoneGranted && model.speechGranted) { model.requestAudio() }
                    Divider()
                    permissionRow("Accessibility", description: "Reads control labels and performs your chosen action.", enabled: model.accessibilityGranted) { model.requestAccessibility() }
                    Text(model.localSpeechAvailable ? "On-device speech is available." : "If local speech is unavailable, enable English dictation in System Settings → Keyboard.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Toggle("Speak task results (off keeps listening uninterrupted)", isOn: $model.voiceFeedback).toggleStyle(.checkbox).font(.system(size: 11))
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 9) {
                    Text("What leaves your Mac").font(.system(size: 14, weight: .medium))
                    Text("OpenRouter and TypeSafe receive your transcript, app/window title, page URL, visible UI text and field values, and action labels. Audio stays on this Mac. Password fields are excluded. Jev activity shows the actual request and response bodies; authorization headers are excluded.").font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    Text("Commands execute immediately. A request can run many actions. Say “cancel task” to stop the current request, or “stop listening” to turn off the microphone.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
        }
    }
    private var keyEntry: some View {
        HStack {
            SecureField("OpenRouter or TypeSafe API key", text: $model.keyInput).textFieldStyle(.roundedBorder)
            Button("Save key") { model.saveKey() }.disabled(model.keyInput.isEmpty)
        }
    }
    private var connectionActions: some View {
        HStack {
            if model.provider == .openRouter {
                Link("OpenRouter credits", destination: OpenRouterBilling.creditsURL)
                Link("Key limits", destination: OpenRouterBilling.keysURL)
            }
            Spacer()
            Button(model.checkingConnection ? "Checking…" : "Check connection") { model.checkConnection() }
                .disabled(!model.keyConfigured || model.busy || model.checkingConnection)
        }.font(.system(size: 11))
    }
    private func permissionRow(_ title: String, description: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack { VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12, weight: .medium)); Text(description).font(.system(size: 10)).foregroundStyle(Palette.muted) }; Spacer(); Button(enabled ? "Enabled" : "Enable", action: action).disabled(enabled) }
    }
}

/// The everyday interface. Detailed activity stays in the menu-bar settings window.
struct CommandBarView: View {
    @ObservedObject var model: AppModel
    @FocusState private var editing: Bool
    let openSettings: () -> Void
    let releaseKeyboard: () -> Void

    private var command: String {
        if !model.liveTranscript.isEmpty { return model.liveTranscript }
        if !model.transcript.isEmpty { return model.transcript }
        return model.micEnabled ? "Say or type a command…" : "Type a command, or turn the mic on…"
    }
    private var status: String {
        if model.requestingAudio { return "Allow microphone access" }
        if !model.keyConfigured || !model.accessibilityGranted { return "Finish setup in Settings" }
        if model.billingIssue != nil { return "Connection needs attention · Settings" }
        if model.busy { return model.phase == "Acting" ? model.detail : "Working…" }
        if model.phase == "Reconnecting microphone" { return "Reconnecting microphone…" }
        if model.phase == "Needs attention" || model.phase == "Connection needs attention" { return model.detail }
        if model.detail.hasPrefix("Finished") { return model.micEnabled ? "Done · Listening" : "Done · Mic off" }
        return model.micEnabled ? "Listening" : "Mic off"
    }
    private func submit() {
        editing = false
        releaseKeyboard()
        model.runTyped()
    }
    var body: some View {
        HStack(spacing: 11) {
            Button {
                editing = false
                releaseKeyboard()
                model.toggleListening()
            } label: {
                Image(systemName: model.micEnabled ? "waveform" : "mic.slash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(model.micEnabled ? Palette.accent : Palette.muted)
                    .frame(width: 34, height: 36)
                    .background(model.micEnabled ? Palette.accent.opacity(0.10) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain)
                .accessibilityLabel(model.micEnabled ? "Turn mic off" : "Turn mic on")
                .help("Toggle listening · Option–Space")
            VStack(alignment: .leading, spacing: 3) {
                TextField("", text: $model.typedCommand,
                    prompt: Text(command).foregroundColor(model.transcript.isEmpty && model.liveTranscript.isEmpty ? Palette.muted : .white))
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                    .focused($editing).onSubmit { submit() }
                    .accessibilityLabel("Command transcript")
                HStack(spacing: 5) {
                    Circle().fill(model.busy ? Color.orange : model.micEnabled ? Palette.accent : Palette.muted).frame(width: 4, height: 4)
                    Text(status).lineLimit(1).truncationMode(.tail)
                    if model.queuedCount > 0 { Text("· \(model.queuedCount) queued") }
                }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !model.typedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { submit() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.background).frame(width: 27, height: 27)
                        .background(Palette.accent, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Run command").help("Run command · Return")
            }
            if model.busy {
                Button { model.cancelCurrentTask() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 10)).frame(width: 26, height: 28)
                }.buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("Stop task")
            } else if !model.keyConfigured || !model.accessibilityGranted || model.billingIssue != nil {
                Button(action: openSettings) { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    .buttonStyle(.plain).accessibilityLabel("Open Settings")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 488, height: 60)
        .background(Palette.background.opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .onChange(of: model.busy) { _, busy in if busy { editing = false } }
        .onExitCommand { editing = false; releaseKeyboard() }
    }
}

struct PracticeView: View {
    @ObservedObject var model: AppModel
    @State private var color = Palette.accent
    @State private var result = "Pick a color with your voice."
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("A place to try things.").font(.system(size: 26, weight: .medium, design: .rounded))
            Text("Turn the mic on once and say “click Blue”.\nPause, then say “type hello world”.").font(.system(size: 13)).foregroundStyle(Palette.muted)
            RoundedRectangle(cornerRadius: 20).fill(color).frame(height: 100).overlay(Text(result).font(.system(size: 18, weight: .medium)).foregroundStyle(.black)).accessibilityLabel(result)
            HStack(spacing: 12) {
                Button("Blue") { color = .cyan; result = "Blue selected" }.accessibilityLabel("Blue")
                Button("Coral") { color = .orange; result = "Coral selected" }.accessibilityLabel("Coral")
                Button("Reset") { color = Palette.accent; result = "Pick a color with your voice."; text = "" }
            }.buttonStyle(.bordered).controlSize(.large)
            TextField("Practice text", text: $text).textFieldStyle(.roundedBorder).accessibilityLabel("Practice text")
            HStack {
                Button("Send message") { result = "Practice only: nothing was sent." }
                Text("A local practice action; nothing is sent externally.").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            HStack { Button("Show command bar") { model.showCommandBar?() }; Spacer(); Text("No external side effects").font(.system(size: 10)).foregroundStyle(Palette.muted) }
        }.padding(30).frame(width: 475).background(Palette.background).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}
