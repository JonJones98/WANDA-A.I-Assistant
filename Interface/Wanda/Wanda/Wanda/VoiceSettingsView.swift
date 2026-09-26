//
//  VoiceSettingsView.swift
//  Wanda
//

import SwiftUI

struct VoiceSettingsView: View {
    @ObservedObject var settings: VoiceSettings
    @Binding var readRepliesAloud: Bool
    @Binding var wakeWordEnabled: Bool
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

            Toggle("Listen for “Hey Wanda”", isOn: $wakeWordEnabled)
            Text("Say “Hey Wanda” or “Hi Wanda”, wait for the chime, then ask. Listening happens on your Mac; the mic stays on while this is enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
