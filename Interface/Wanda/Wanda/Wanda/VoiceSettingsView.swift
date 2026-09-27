//
//  VoiceSettingsView.swift
//  Wanda
//

import SwiftUI

struct VoiceSettingsView: View {
    @ObservedObject var settings: VoiceSettings
    @Binding var readRepliesAloud: Bool
    @Binding var wakeWordEnabled: Bool
    @Binding var nameOnlyWhenOpen: Bool
    @Binding var nickname: String
    @ObservedObject var headGestures: HeadGestureListener
    @Binding var showsDemoBar: Bool
    let onPreview: () -> Void

    @State private var showAllLanguages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Voice")
                .font(.headline)

            Toggle("Read every reply aloud", isOn: $readRepliesAloud)
            Text("Replies to spoken messages are always read aloud.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show the demo status bar", isOn: $showsDemoBar)
            Text("Turn off to record the demo without it. Esc stops the demo.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Pause music while I talk to Wanda", isOn: $settings.pausesMusic)
            Text("Pauses Spotify and Apple Music when Wanda starts listening, and plays it again after her answer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Lower music while Wanda speaks", isOn: $settings.lowersMusic)
            Text("Turns Spotify and Apple Music down during replies, then back up.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Wake up with", selection: wakeMode) {
                ForEach(WakeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("wakeModePicker")

            switch wakeMode.wrappedValue {
            case .voice:
                Text("Say “Hey Wanda” or “Hi Wanda”, wait for the chime, then ask. Listening happens on your Mac; the mic stays on, so AirPods play music in call quality.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Just say the name when the window is open", isOn: $nameOnlyWhenOpen)
                HStack {
                    Text("Nickname")
                    TextField("Optional, e.g. Jarvis", text: $nickname)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("nicknameField")
                }
                Text(nameHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .nod, .shake, .tilt, .anyGesture:
                Text(gestureHint)
                    .font(.caption)
                    .foregroundStyle(headGestures.status == .denied || headGestures.status == .unsupported ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .off:
                Text("Wanda only listens when you click the mic button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if let voices = settings.voices {
                if !voices.isEmpty { voicePicker(voices) }
                sourceNotes
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading voices…").foregroundStyle(.secondary)
                }
            }

            labeledSlider("Speed", value: $settings.rate, in: VoiceSettings.rateRange,
                          low: "tortoise", high: "hare")
            labeledSlider("Pitch", value: $settings.pitch, in: VoiceSettings.pitchRange,
                          low: "arrow.down", high: "arrow.up")
                .disabled(isKokoroSelected)
            if isKokoroSelected {
                Text("Kokoro voices don't support pitch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(action: onPreview) {
                    Label("Preview", systemImage: "play.fill")
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Reset speed & pitch", action: settings.resetSpeedAndPitch)
            }

        }
        .padding(16)
        .frame(width: 320)
        .task { await settings.loadVoices() }
    }

    private var isKokoroSelected: Bool { settings.kokoroVoiceName != nil }

    /// Wake up mode, stored as the "Hey Wanda" and head gesture settings.
    private var wakeMode: Binding<WakeMode> {
        Binding(
            get: {
                WakeMode(wakeWordEnabled: wakeWordEnabled,
                         gesturesEnabled: headGestures.isEnabled,
                         gesture: headGestures.gesture)
            },
            set: { mode in
                wakeWordEnabled = mode == .voice
                if let gesture = mode.gesture {
                    headGestures.gesture = gesture
                    headGestures.isEnabled = true
                } else {
                    headGestures.isEnabled = false
                }
            }
        )
    }

    private var gestureHint: String {
        let how: String
        switch headGestures.gesture {
        case .nod: how = "Nod twice (yes, yes)"
        case .shake: how = "Shake your head (no, no)"
        case .tilt: how = "Tilt your head to the side and back twice"
        case .any: how = "Nod twice, shake your head, or tilt your head twice"
        }
        switch headGestures.status {
        case .off, .ready:
            return "\(how) with AirPods in to start or stop listening. Uses head tracking, not the mic, so music keeps its full quality. Experimental."
        case .unsupported:
            return "This Mac can't read head movement from AirPods (needs macOS 14 or later)."
        case .denied:
            return "Wanda can't read head movement. Allow Motion & Fitness for Wanda in System Settings → Privacy & Security."
        case .waitingForAirPods:
            return "Waiting for AirPods with head tracking (AirPods Pro, AirPods 3rd gen or later, AirPods Max)."
        }
    }

    private var nameHint: String {
        let names = (["Wanda"] + WakePhrase(nickname: nickname).nicknames.map(\.capitalized))
            .map { "“\($0)”" }
        let list = ListFormatter.localizedString(byJoining: names)
        let open = nameOnlyWhenOpen
            ? "With the window open, just say \(list). "
            : ""
        return open + "With it hidden, say “Hey …” first. Separate several nicknames with commas."
    }

    @ViewBuilder
    private func voicePicker(_ voices: [VoiceOption]) -> some View {
        let shown = showAllLanguages ? voices : voices.filter(\.isEnglish)
        let kokoro = shown.filter { $0.engine == .kokoro }
        let appleByQuality = Dictionary(grouping: shown.filter { $0.engine == .apple }, by: \.quality)
        let selection = Binding(get: { settings.voiceID }, set: { settings.choose($0) })

        Picker("Voice", selection: selection) {
            if !kokoro.isEmpty {
                Section("Kokoro AI voices (run on your Mac)") {
                    ForEach(kokoro) { voice in
                        Text("\(voice.name)\(voice.recommended ? " ★" : "") — \(voice.detail)")
                            .tag(Optional(voice.id))
                    }
                }
            }
            ForEach(appleByQuality.keys.sorted(by: >), id: \.self) { quality in
                Section("Apple · \(quality.label)") {
                    ForEach(appleByQuality[quality] ?? []) { voice in
                        Text("\(voice.name) — \(voice.detail)")
                            .tag(Optional(voice.id))
                    }
                }
            }
        }
        .accessibilityIdentifier("voicePicker")

        Toggle("Show all languages", isOn: $showAllLanguages)
            .font(.caption)

        if let selected = settings.selectedVoice, selected.engine == .apple, selected.quality == .standard {
            Text("Standard Apple voices sound robotic. Try a Kokoro voice (★ = best) for natural speech.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Explains why a group of voices is missing, with a way to retry.
    @ViewBuilder
    private var sourceNotes: some View {
        if settings.kokoroUnavailable || settings.appleVoicesTimedOut {
            VStack(alignment: .leading, spacing: 6) {
                if settings.kokoroUnavailable {
                    Label("Kokoro voices need Wanda's server running with the Kokoro model installed.", systemImage: "server.rack")
                }
                if settings.appleVoicesTimedOut {
                    Label("macOS isn't returning its voice list (its voice service isn't responding).", systemImage: "exclamationmark.triangle")
                }
                Button("Try again") { Task { await settings.loadVoices() } }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeledSlider(
        _ title: String, value: Binding<Float>, in range: ClosedRange<Float>,
        low: String, high: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            HStack(spacing: 8) {
                Image(systemName: low).foregroundStyle(.secondary)
                Slider(value: value, in: range)
                Image(systemName: high).foregroundStyle(.secondary)
            }
        }
    }
}
