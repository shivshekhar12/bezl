import AppKit
import SwiftUI

/// One-time welcome that explains the two permissions so the system prompts appear in context.
struct OnboardingView: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                GradientSwatch(primary: model.settings.look.primary, secondary: model.settings.look.secondary)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading) {
                    Text("Welcome to Bezl").font(.bezlTitle2.bold())
                    Text("Ambient light around your screen that moves with your music.")
                        .foregroundStyle(.secondary)
                }
            }
            step(icon: "waveform", title: "Listen to system audio",
                 detail: "To pulse on the beat, Bezl analyzes what your Mac is playing, on-device. It never records and never uses the microphone. macOS will ask once.")
            step(icon: "music.note", title: "Read album art from Music and Spotify",
                 detail: "To match the album colors, Bezl asks those apps for the current artwork. macOS asks the first time each app is playing. Bezl never opens them for you.")
            step(icon: "menubar.rectangle", title: "Tune it from the menu bar",
                 detail: "Click the Bezl icon to change colors, motion, thickness and glow. Press ⌃⌥⌘L to turn the light on or off.")
            HStack {
                Spacer()
                Button("Get Started") { close() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func step(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.bezlTitle3).frame(width: 26).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bezlHeadline)
                Text(detail).font(.bezlCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
