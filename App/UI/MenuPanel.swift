import AppKit
import BezlCore
import SwiftUI
import UniformTypeIdentifiers

struct MenuPanel: View {
    @Bindable var model: AppModel
    @State private var selectedDisplay: String = "all"
    @State private var newPresetName = ""
    @State private var showDiagnostics = false
    @State private var showDisplay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.settings.isActive {
                Divider()
                colorSection
                Divider()
                motionSection
                Divider()
                shapeSection
                Divider()
                displaySection
            }
            Divider()
            permissions
            footer
        }
        .padding(16)
        .frame(width: 320)
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            GradientSwatch(primary: model.settings.look.primary, secondary: model.settings.look.secondary,
                           album: model.settings.look.colorSource == .albumArt ? model.nowPlaying.palette : nil)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bezl").font(.headline)
                Text(model.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Toggle("On", isOn: $model.settings.isActive)
                .labelsHidden()
                .help("Turn Bezl on or off (⌃⌥⌘L)")
        }
    }

    // MARK: Color

    private var colorSection: some View {
        Section {
            Picker("Color", selection: $model.settings.look.colorSource) {
                Text("Album art").tag(ColorSource.albumArt)
                Text("My colors").tag(ColorSource.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                ColorPicker("Primary", selection: colorBinding(\.primary), supportsOpacity: false)
                ColorPicker("Secondary", selection: colorBinding(\.secondary), supportsOpacity: false)
            }
            .font(.caption)
            labeledSlider("Balance", value: $model.settings.look.primaryWeight, in: 0.1...0.9,
                          display: { "\(Int(($0 * 100).rounded())) / \(Int(((1 - $0) * 100).rounded()))" })
            labeledSlider("Drift", value: $model.settings.look.rotationSpeed, in: 0...6,
                          display: { $0 < 0.05 ? "Off" : String(format: "%.1f rpm", $0) })
            if model.settings.look.colorSource == .albumArt {
                Text(model.nowPlaying.track == nil
                     ? "Plays from Music or Spotify set the colors. Until then, your colors are used."
                     : "Colors follow the album art. These are the fallback colors.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            sectionTitle("Color")
        }
    }

    // MARK: Motion

    private var motionSection: some View {
        Section {
            Picker("Motion", selection: $model.settings.look.motion) {
                Text("Beat").tag(AnimationMode.beat)
                Text("Breathe").tag(AnimationMode.breathe)
                Text("Still").tag(AnimationMode.still)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.settings.look.motion == .beat {
                Toggle("Music sync", isOn: $model.settings.musicSync)
                    .font(.caption)
                labeledSlider("Beat strength", value: $model.settings.look.beatStrength, in: 0...1, display: percent)
                    .disabled(!model.settings.musicSync)
            }
        } header: {
            sectionTitle("Motion")
        }
    }

    // MARK: Shape

    private var shapeSection: some View {
        Section {
            labeledSlider("Thickness", value: $model.settings.look.thickness, in: 1...40,
                          display: { String(format: "%.0f pt", $0) })
            labeledSlider("Glow", value: $model.settings.look.glow, in: 0...1, display: percent)
            labeledSlider("Brightness", value: $model.settings.look.intensity, in: 0.05...1, display: percent)
            presetsMenu
        } header: {
            sectionTitle("Shape")
        }
    }

    private var presetsMenu: some View {
        Menu("Presets") {
            ForEach(model.allPresets) { preset in
                Button(preset.name) { model.applyPreset(preset) }
            }
            Divider()
            Button("Save Current Look…") { promptForPresetName() }
            Button("Import…") { importPreset() }
            if !model.customPresets.isEmpty {
                Menu("Export") {
                    ForEach(model.customPresets) { p in Button(p.name) { exportPreset(p) } }
                }
                Menu("Delete") {
                    ForEach(model.customPresets) { p in Button(p.name) { model.deletePreset(p) } }
                }
            }
        }
        .font(.caption)
    }

    // MARK: Displays

    private var displaySection: some View {
        DisclosureGroup(isExpanded: $showDisplay) {
          VStack(alignment: .leading, spacing: 10) {
            if model.displays.count > 1 {
                Picker("Display", selection: $selectedDisplay) {
                    ForEach(model.displays) { d in Text(d.name).tag(d.id) }
                }
                .font(.caption)
            }
            if let display = currentDisplay {
                Toggle("Light this display", isOn: displayBinding(display.id, \.enabled))
                    .font(.caption)
                if display.hasNotch {
                    Toggle("Follow the notch", isOn: displayBinding(display.id, \.followNotch))
                        .font(.caption)
                }
                HStack {
                    Toggle("Custom corners", isOn: Binding(
                        get: { model.displaySettings(display.id).cornerRadius != nil },
                        set: { on in model.updateDisplay(display.id) { $0.cornerRadius = on ? 10 : nil } }))
                        .font(.caption)
                }
                if model.displaySettings(display.id).cornerRadius != nil {
                    labeledSlider("Corner radius", value: Binding(
                        get: { model.displaySettings(display.id).cornerRadius ?? 0 },
                        set: { v in model.updateDisplay(display.id) { $0.cornerRadius = v } }),
                                  in: 0...40, display: { String(format: "%.0f pt", $0) })
                }
            }
            Toggle("Hide in full-screen apps", isOn: $model.settings.hideInFullScreen).font(.caption)
            Toggle("Hide from screenshots & sharing", isOn: $model.settings.hideFromScreenCapture).font(.caption)
            Toggle("Launch at login", isOn: $model.launchAtLogin).font(.caption)
          }
          .padding(.top, 8)
        } label: {
            sectionTitle("Display & Behavior")
        }
        .onAppear {
            if !model.displays.contains(where: { $0.id == selectedDisplay }) {
                selectedDisplay = (NSScreen.main?.bezlDisplayID).flatMap { id in
                    model.displays.contains { $0.id == id } ? id : nil
                } ?? model.displays.first?.id ?? "all"
            }
        }
    }

    private var currentDisplay: DisplayInfo? {
        model.displays.first { $0.id == selectedDisplay } ?? model.displays.first
    }

    // MARK: Permissions

    @ViewBuilder
    private var permissions: some View {
        let denied = model.nowPlaying.deniedApps
        if model.needsAudioPermission || model.audioError != nil || !denied.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if model.needsAudioPermission {
                    permissionRow("Bezl can't hear system audio.", button: "Open Settings") { SystemSettingsLink.systemAudio() }
                }
                if let error = model.audioError {
                    permissionRow("Audio capture failed: \(error)", button: "Open Settings") { SystemSettingsLink.systemAudio() }
                }
                ForEach(MusicApp.allCases.filter { denied.contains($0) }, id: \.self) { app in
                    permissionRow("Bezl can't read \(app.displayName)'s artwork.", button: "Open Settings") {
                        SystemSettingsLink.automation()
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }

    private func permissionRow(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action).font(.caption)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                DiagnosticsView(model: model)
            }
            .font(.caption)
            HStack {
                Button("About Bezl") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.caption)
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func labeledSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                               display: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range).labelsHidden()
        }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<LookSettings, RGB>) -> Binding<Color> {
        Binding(
            get: {
                let c = model.settings.look[keyPath: keyPath]
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
            },
            set: { color in
                guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
                model.settings.look[keyPath: keyPath] = RGB(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                                                            b: Double(ns.blueComponent))
            })
    }

    private func displayBinding(_ id: String, _ keyPath: WritableKeyPath<DisplaySettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.displaySettings(id)[keyPath: keyPath] },
                set: { v in model.updateDisplay(id) { $0[keyPath: keyPath] = v } })
    }

    private func promptForPresetName() {
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Name this look."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "My look"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            model.saveCurrentAsPreset(named: field.stringValue)
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { model.importPreset(from: url) }
    }

    private func exportPreset(_ preset: Preset) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(preset.name).\(Preset.fileExtension)"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { model.exportPreset(preset, to: url) }
    }
}

/// Small rounded swatch previewing the current gradient.
struct GradientSwatch: View {
    var primary: RGB
    var secondary: RGB
    var album: Palette?

    var body: some View {
        let p = album?.primary ?? primary
        let s = album?.secondary ?? secondary
        RoundedRectangle(cornerRadius: 7)
            .strokeBorder(
                AngularGradient(colors: [color(p), color(s), color(p)], center: .center),
                lineWidth: 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.85)))
            .shadow(color: color(p).opacity(0.6), radius: 4)
    }

    private func color(_ c: RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }
}

/// Live audio readout, for checking capture and tuning.
struct DiagnosticsView: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let s = model.lightState
            let stats = model.audioStats
            VStack(alignment: .leading, spacing: 4) {
                meter("Level", s.level)
                meter("Pulse", s.pulse)
                Group {
                    Text(String(format: "RMS %.0f dBFS · %.0f Hz", s.rmsDB, stats.sampleRate))
                    Text("Beats detected: \(stats.onsetCount)")
                    if let t = model.nowPlaying.track {
                        Text("\(t.app.displayName): \(t.title) — \(t.artist)\(t.isPlaying ? "" : " (paused)")")
                            .lineLimit(1)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private func meter(_ label: String, _ v: Double) -> some View {
        HStack {
            Text(label).font(.caption2).frame(width: 36, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(Color.accentColor).frame(width: g.size.width * min(max(v, 0), 1))
                }
            }
            .frame(height: 5)
        }
    }
}
