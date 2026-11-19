import AppKit
import BezlCore
import SwiftUI
import UniformTypeIdentifiers

struct MenuPanel: View {
    @Bindable var model: AppModel
    /// Hosted in the Settings window (expanded sections, no Quit shortcut clash).
    var inWindow = false
    @State private var selectedDisplay: String = "all"
    @State private var newPresetName = ""
    @State private var showDiagnostics = false
    @State private var showDisplay = false
    @State private var showBehavior = false
    @State private var showUpdates = false

    var body: some View {
        VStack(alignment: .leading, spacing: inWindow ? 20 : 14) {
            if inWindow { card { header } } else { header }
            if model.settings.isActive {
                separator
                colorSection
                separator
                motionSection
                separator
                shapeSection
                separator
                displaySection
                separator
                behaviorSection
            }
            separator
            permissions
            footer
        }
        .padding(inWindow ? 14 : 16)
        .tint(accent)
        .frame(width: inWindow ? nil : 320)
        .frame(maxWidth: inWindow ? .infinity : nil, alignment: .leading)
        .onAppear { if inWindow { showDisplay = true; showBehavior = true; showUpdates = true } }
        .toggleStyle(RowToggleStyle())
        .controlSize(.small)
        .font(.bezlCaption)
    }

    // MARK: Grouping (glass style in the player, plain in the menu bar)

    /// Hairline between sections in the compact menu bar panel; cards replace it in the player.
    @ViewBuilder private var separator: some View {
        if !inWindow { Divider() }
    }

    /// Album color for switches and sliders (system accent when the art is gray or absent).
    private var accent: Color {
        if let p = model.nowPlaying.palette, !p.isNeutral, model.settings.look.colorSource == .albumArt {
            return Color(.sRGB, red: p.primary.r, green: p.primary.g, blue: p.primary.b)
        }
        return Color(.sRGB, red: model.settings.look.primary.r, green: model.settings.look.primary.g,
                     blue: model.settings.look.primary.b)
    }

    /// A titled group: a rounded inset card on glass (System Settings style) in the player,
    /// a plain titled block in the menu bar.
    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: inWindow ? 8 : 14) {
            sectionTitle(title)
                .padding(.leading, inWindow ? 6 : 0)
            if inWindow { card(content: content) } else { content() }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            GradientSwatch(primary: model.settings.look.primary, secondary: model.settings.look.secondary,
                           album: model.settings.look.colorSource == .albumArt ? model.nowPlaying.palette : nil)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bezl").font(.bezlHeadline)
                Text(model.statusLine)
                    .font(.bezlCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if !inWindow {
            Button {
                model.togglePlayer()
            } label: {
                Image(systemName: "play.rectangle")
            }
            .buttonStyle(.borderless)
            .help("Open the player")
            Button {
                model.togglePlayerFullScreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Full screen stage mode: black except the bezel glow and the player")
            }
            Toggle("On", isOn: $model.settings.isActive)
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Turn Bezl on or off (⌃⌥⌘L)")
        }
    }

    // MARK: Color

    private var colorSection: some View {
        group("Color") {
            Picker("Color", selection: $model.settings.look.colorSource) {
                Text("Album art").tag(ColorSource.albumArt)
                Text("My colors").tag(ColorSource.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            row("Colors") {
                HStack(spacing: 8) {
                    ColorPicker("Primary", selection: colorBinding(\.primary), supportsOpacity: false)
                        .labelsHidden().help("Primary color")
                    ColorPicker("Secondary", selection: colorBinding(\.secondary), supportsOpacity: false)
                        .labelsHidden().help("Secondary color")
                }
            }
            labeledSlider("Balance", value: $model.settings.look.primaryWeight, in: 0.1...0.9,
                          display: { "\(Int(($0 * 100).rounded())) / \(Int(((1 - $0) * 100).rounded()))" })
            labeledSlider("Drift", value: $model.settings.look.rotationSpeed, in: 0...6,
                          display: { $0 < 0.05 ? "Off" : String(format: "%.1f rpm", $0) })
            if model.settings.look.colorSource == .albumArt {
                Text(liveAlbumPalette != nil
                     ? "Showing the colors from the album art. Pick a color to use your own instead."
                     : model.nowPlaying.track == nil
                        ? "Play something in Music or Spotify to use its album colors. Until then, these are used."
                        : "This album is black and white, so these colors are used instead.")
                    .font(.bezlCaption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Motion

    private var motionSection: some View {
        group("Motion") {
            Picker("Motion", selection: $model.settings.look.motion) {
                Text("Beat").tag(AnimationMode.beat)
                Text("Breathe").tag(AnimationMode.breathe)
                Text("Still").tag(AnimationMode.still)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.settings.look.motion == .beat {
                Toggle("Music sync", isOn: $model.settings.musicSync)
                labeledSlider("Beat strength", value: $model.settings.look.beatStrength, in: 0...1, display: percent)
                    .disabled(!model.settings.musicSync)
            }
        }
    }

    // MARK: Shape

    private var shapeSection: some View {
        group("Shape") {
            labeledSlider("Thickness", value: $model.settings.look.thickness, in: 1...40,
                          display: { String(format: "%.0f pt", $0) })
            labeledSlider("Glow", value: $model.settings.look.glow, in: 0...1, display: percent)
            labeledSlider("Brightness", value: $model.settings.look.intensity, in: 0.05...1, display: percent)
            row("Presets") { presetsMenu }
        }
    }

    private var presetsMenu: some View {
        Menu("Choose…") {
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
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.bezlCaption)
    }

    // MARK: Displays

    private var displaySection: some View {
        CollapsibleSection(title: "Display", isExpanded: $showDisplay, carded: inWindow) {
            if model.displays.count > 1 {
                row("Display") {
                    Picker("Display", selection: $selectedDisplay) {
                        ForEach(model.displays) { d in Text(d.name).tag(d.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if let display = currentDisplay {
                Toggle("Light this display", isOn: displayBinding(display.id, \.enabled))
                if display.hasNotch {
                    Toggle("Follow the notch", isOn: displayBinding(display.id, \.followNotch))
                }
                Toggle("Custom corners", isOn: Binding(
                    get: { model.displaySettings(display.id).cornerRadius != nil },
                    set: { on in model.updateDisplay(display.id) { $0.cornerRadius = on ? 10 : nil } }))
                if model.displaySettings(display.id).cornerRadius != nil {
                    labeledSlider("Corner radius", value: Binding(
                        get: { model.displaySettings(display.id).cornerRadius ?? 0 },
                        set: { v in model.updateDisplay(display.id) { $0.cornerRadius = v } }),
                                  in: 0...40, display: { String(format: "%.0f pt", $0) })
                }
            }
        }
        .onAppear {
            if !model.displays.contains(where: { $0.id == selectedDisplay }) {
                selectedDisplay = (NSScreen.main?.bezlDisplayID).flatMap { id in
                    model.displays.contains { $0.id == id } ? id : nil
                } ?? model.displays.first?.id ?? "all"
            }
        }
    }

    private var behaviorSection: some View {
        CollapsibleSection(title: "Behavior", isExpanded: $showBehavior, carded: inWindow) {
            Toggle("Hide in full-screen apps", isOn: $model.settings.hideInFullScreen)
            Toggle("Hide from screenshots & sharing", isOn: $model.settings.hideFromScreenCapture)
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            Toggle("Show in Dock", isOn: $model.settings.showInDock)
            Toggle("Lock screen player (beta)", isOn: $model.settings.lockScreenPlayer)
                .help("Keeps the glow and a mini player above the lock screen when macOS allows it.")
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
            Text(text).font(.bezlCaption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action).font(.bezlCaption)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: inWindow ? 20 : 14) {
            CollapsibleSection(title: "Updates", isExpanded: $showUpdates, carded: inWindow) {
                row("Version \(model.updates.currentVersion)") {
                    Button("Check Now") { model.checkForUpdates() }
                        .disabled(model.updates.status == .checking)
                }
                Toggle("Check automatically", isOn: $model.settings.checkForUpdatesAutomatically)
                if !model.updates.statusText.isEmpty {
                    row(model.updates.statusText, secondary: true) {
                        if case let .available(_, url) = model.updates.status {
                            Button("Download") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                Text("Checks GitHub Releases. Nothing is downloaded automatically.")
                    .font(.bezlCaption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            separator
            CollapsibleSection(title: "Diagnostics", isExpanded: $showDiagnostics, carded: inWindow) {
                DiagnosticsView(model: model)
            }
            separator
            HStack {
                Button("About Bezl") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Spacer()
                Button("Quit Bezl") { NSApp.terminate(nil) }
                    .keyboardShortcut(inWindow ? nil : KeyboardShortcut("q"))
            }
            .font(.bezlCaption)
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased()).font(.bezlCaption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    /// A label on the left and a control aligned to the right edge, like a settings table row.
    private func row<Control: View>(_ title: String, secondary: Bool = false,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(secondary ? .secondary : .primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            control()
        }
        .font(.bezlCaption)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .font(.bezlCaption)
            Slider(value: value, in: range).labelsHidden()
        }
    }

    /// The album's palette when it's the one lighting the rim (album mode, colorful art).
    private var liveAlbumPalette: Palette? {
        guard model.settings.look.colorSource == .albumArt,
              let p = model.nowPlaying.palette, !p.isNeutral else { return nil }
        return p
    }

    /// Color wells show whatever is lighting the rim: the album's colors in album mode,
    /// your own otherwise. Picking a color while following the album switches to "My colors",
    /// starting from the album's palette so the other color doesn't jump.
    private func colorBinding(_ keyPath: WritableKeyPath<LookSettings, RGB>) -> Binding<Color> {
        Binding(
            get: {
                let c: RGB
                if let album = liveAlbumPalette {
                    c = keyPath == \.primary ? album.primary : album.secondary
                } else {
                    c = model.settings.look[keyPath: keyPath]
                }
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
            },
            set: { color in
                guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
                let picked = RGB(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
                var look = model.settings.look
                if let album = liveAlbumPalette {
                    look.primary = album.primary
                    look.secondary = album.secondary
                    look.colorSource = .manual
                }
                look[keyPath: keyPath] = picked
                model.settings.look = look
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
                .font(.bezlCaption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private func meter(_ label: String, _ v: Double) -> some View {
        HStack {
            Text(label).font(.bezlCaption2).frame(width: 36, alignment: .leading)
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


/// Settings-table toggle: label on the left, switch right-aligned, full row width.
struct RowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
                .font(.bezlCaption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// A section whose header matches the static ones (COLOR, MOTION…) but can collapse.
/// Content is not indented, so its rows line up with every other section.
struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    /// Glass-style inset card around the content (used in the player's settings drawer).
    var carded = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: carded ? 8 : 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(title.uppercased())
                        .font(.bezlCaption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.bezlCaption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .padding(.horizontal, carded ? 6 : 0)
            if isExpanded {
                if carded {
                    VStack(alignment: .leading, spacing: 12) { content() }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.07)))
                } else {
                    content()
                }
            }
        }
    }
}
