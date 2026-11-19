import AppKit
import BezlCore
import SwiftUI

/// The now-playing window: artwork, controls, synced lyrics and quick toggles.
/// Resizable: everything scales with the window. In full screen ("stage mode") the background is
/// pure black so only the glowing bezel and the centered player remain.
struct PlayerView: View {
    @Bindable var model: AppModel
    @State private var showLyrics = false
    @State private var askLyricsConsent = false
    /// Full-screen chrome fades out after a few seconds without input.
    @State private var idle = IdleTracker()
    /// In-app settings drawer (works in full screen, unlike a separate window).
    private var showSettings: Bool {
        get { model.playerSettingsOpen }
        nonmutating set { model.playerSettingsOpen = newValue }
    }

    private var nowPlaying: NowPlayingService { model.nowPlaying }
    /// In stage mode, hide everything but the artwork and lyrics while the user is idle.
    private var chromeHidden: Bool { stage && idle.isIdle && !showSettings }
    private var stage: Bool { model.playerFullScreen }
    private var palette: Palette {
        model.nowPlaying.palette.flatMap { $0.isNeutral ? nil : $0 }
            ?? Palette(primary: model.settings.look.primary, secondary: model.settings.look.secondary)
    }

    /// Layout metrics derived from the available space.
    private struct Metrics {
        var scale: CGFloat
        var art: CGFloat
        var contentWidth: CGFloat

        init(size: CGSize, stage: Bool) {
            // 440 x 700 is the design size; grow with the window, shrink a little below it.
            let raw = min(size.width / 440, size.height / 700)
            scale = min(max(raw, 0.85), stage ? 2.0 : 1.8)
            let artFromHeight = size.height * (stage ? 0.40 : 0.43)
            art = max(160, min(size.width * 0.72, artFromHeight, stage ? 620 : 560))
            contentWidth = min(size.width, stage ? 900 * min(scale, 1.4) : size.width)
        }
    }

    var body: some View {
        GeometryReader { geo in
            // With room to spare, the drawer sits beside the player instead of covering it.
            let drawerWidth: CGFloat = 392   // 360 pt glass card + 16 pt margins
            let sideBySide = showSettings && geo.size.width >= 380 + drawerWidth   // player minimum + drawer
            let playerSize = CGSize(width: geo.size.width - (sideBySide ? drawerWidth : 0), height: geo.size.height)
            let m = Metrics(size: playerSize, stage: stage)
            ZStack {
                background
                if stage {
                    stageLayout(size: playerSize)
                        .frame(width: playerSize.width, height: playerSize.height)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 18 * m.scale) {
                        Spacer(minLength: 28)
                        if let track = nowPlaying.track {
                            if showLyrics {
                                compactHeader(track, m)
                                LyricsPane(model: model, scale: m.scale)
                                    .frame(maxHeight: .infinity)
                            } else {
                                ArtworkView(data: nowPlaying.artworkData, glow: palette.primary, cornerRadius: 18 * m.scale)
                                    .frame(width: m.art, height: m.art)
                                titles(track, m)
                            }
                            ProgressRow(nowPlaying: nowPlaying)
                                .frame(maxWidth: min(m.art + 60, m.contentWidth - 48))
                            controls(track, m)
                            lyricsButton(m)
                        } else {
                            emptyState(m)
                        }
                        Spacer(minLength: 8)
                        toolbar(m)
                            .padding(.bottom, 18 * m.scale)
                    }
                    .frame(maxWidth: m.contentWidth)
                    .padding(.horizontal, 20)
                    .frame(width: playerSize.width)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .trailing) {
                // In full screen on a notched Mac, content starts below the camera-housing strip.
                // GeometryReader reports no inset here, so read it from the screen.
                settingsDrawer(height: geo.size.height, dims: !sideBySide,
                               safeTop: stage ? (NSScreen.main?.safeAreaInsets.top ?? 0) : 0)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: showSettings)
        }
        .frame(minWidth: 380, minHeight: 560)
        .font(.bezlCallout)
        .preferredColorScheme(.dark)
        .alert("Show lyrics?", isPresented: $askLyricsConsent) {
            Button("Allow") {
                model.settings.lyricsConsent = true
                showLyrics = true
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Bezl looks up lyrics on LRCLIB.net, a free, open lyrics database. This sends the song's title, artist, album and length. Nothing else is sent.")
        }
        .onChange(of: showLyrics) { _, on in
            model.lyricsVisible = on
        }
        .onDisappear { model.lyricsVisible = false }
        .background {
            // Keyboard: F toggles stage mode (Esc and ⌃⌘F also work, via macOS).
            Button("") { model.togglePlayerFullScreen() }
                .keyboardShortcut("f", modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: Stage (full screen) layout

    /// Full-screen layout: artwork dead-center, a wide Liquid Glass control panel beneath it,
    /// a floating glass toolbar at the bottom. With lyrics on, the artwork moves left and the
    /// lyrics take the right half of the screen.
    @ViewBuilder
    private func stageLayout(size: CGSize) -> some View {
        let s = min(max(min(size.width / 1512, size.height / 982), 0.75), 1.6)   // relative to a 14" MBP
        // Space reserved under the artwork for the title and the glass controls. The artwork is
        // centered on the screen, so whatever sits below it must fit in the lower half.
        let below: CGFloat = 236 * s
        let art = max(200, min(size.height - 2 * below, size.height * 0.52, size.width * (showLyrics ? 0.3 : 0.4)))
        let panelWidth = min(max(art * 1.2, 480 * s), size.width * (showLyrics ? 0.4 : 0.5))

        ZStack {
            if let track = nowPlaying.track {
                HStack(spacing: 0) {
                    // Main column: artwork centered vertically, controls under it.
                    VStack(spacing: 0) {
                        Spacer(minLength: 0).frame(height: max(0, size.height / 2 - art / 2))
                        ArtworkView(data: nowPlaying.artworkData, glow: palette.primary, cornerRadius: 22 * s)
                            .frame(width: art, height: art)
                        VStack(spacing: 4 * s) {
                            Text(track.title)
                                .font(.bezl(30 * s, .bold))
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.bezl(19 * s))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: panelWidth)
                        .padding(.top, 26 * s)
                        .fadesWhenIdle(chromeHidden)
                        stageControls(track, scale: s)
                            .frame(width: panelWidth)
                            .padding(.top, 20 * s)
                            .fadesWhenIdle(chromeHidden)
                        Spacer(minLength: 0)
                    }
                    .frame(width: showLyrics ? size.width * 0.5 : size.width)

                    if showLyrics {
                        LyricsPane(model: model, scale: 1.35 * s)
                            .frame(width: size.width * 0.42, height: size.height * 0.72)
                            .frame(width: size.width * 0.5)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            } else {
                emptyState(Metrics(size: size, stage: true))
            }
            // Secondary controls float in the otherwise empty top-right corner (clear of the notch).
            VStack {
                HStack {
                    Spacer()
                    stageToolbar(scale: s)
                        .fadesWhenIdle(chromeHidden)
                }
                Spacer()
            }
            .padding(.top, 22 * s)
            .padding(.trailing, 26 * s)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: showLyrics)
        .onAppear { idle.start() }
        .onDisappear { idle.stop() }
    }

    /// One wide glass panel: progress on top, transport in the middle, lyrics toggle at the side.
    private func stageControls(_ track: Track, scale s: CGFloat) -> some View {
        VStack(spacing: 4 * s) {
            ProgressRow(nowPlaying: nowPlaying, scale: s * 0.85)
            HStack(spacing: 0) {
                GlassIconButton(symbol: "quote.bubble\(showLyrics ? ".fill" : "")", size: 16 * s, isOn: showLyrics,
                                help: "Lyrics") { lyricsTapped() }
                Spacer()
                HStack(spacing: 18 * s) {
                    GlassIconButton(symbol: "gobackward.15", size: 17 * s, help: "Back 15 seconds") {
                        nowPlaying.send(.skip(seconds: -15))
                    }
                    GlassIconButton(symbol: "backward.fill", size: 21 * s, help: "Previous") { nowPlaying.send(.previous) }
                    GlassIconButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 30 * s,
                                    help: track.isPlaying ? "Pause" : "Play") { nowPlaying.send(.playPause) }
                        .keyboardShortcut(.space, modifiers: [])
                    GlassIconButton(symbol: "forward.fill", size: 21 * s, help: "Next") { nowPlaying.send(.next) }
                    GlassIconButton(symbol: "goforward.15", size: 17 * s, help: "Forward 15 seconds") {
                        nowPlaying.send(.skip(seconds: 15))
                    }
                }
                Spacer()
                GlassIconButton(symbol: "arrow.down.right.and.arrow.up.left", size: 14 * s,
                                help: "Exit full screen (F or Esc)") { model.togglePlayerFullScreen() }
            }
        }
        .padding(.horizontal, 22 * s)
        .padding(.top, 14 * s)
        .padding(.bottom, 6 * s)
        .bezlGlass(RoundedRectangle(cornerRadius: 24 * s, style: .continuous), tint: color(palette.primary), clear: true)
    }

    private func stageToolbar(scale s: CGFloat) -> some View {
        HStack(spacing: 6 * s) {
            GlassIconButton(symbol: "paintpalette", size: 16 * s, isOn: model.settings.look.colorSource == .albumArt,
                            help: "Colors follow the album art") {
                model.settings.look.colorSource = model.settings.look.colorSource == .albumArt ? .manual : .albumArt
            }
            GlassIconButton(symbol: motionSymbol, size: 16 * s, isOn: model.settings.look.motion != .still,
                            help: "Motion: \(model.settings.look.motion.rawValue.capitalized) (click to change)") {
                let all = AnimationMode.allCases
                let i = all.firstIndex(of: model.settings.look.motion) ?? 0
                model.settings.look.motion = all[(i + 1) % all.count]
            }
            GlassIconButton(symbol: model.settings.isActive ? "lightbulb.fill" : "lightbulb", size: 16 * s,
                            isOn: model.settings.isActive, help: "Turn the light on or off") {
                model.settings.isActive.toggle()
            }
            Divider().frame(height: 18 * s).padding(.horizontal, 4 * s)
            Button { showSettings.toggle() } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
                    .font(.bezl(14 * s, .semibold))
                    .padding(.horizontal, 12 * s)
                    .frame(height: 36 * s)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10 * s)
        .padding(.vertical, 6 * s)
        .bezlGlass(Capsule(), tint: nil, clear: true)
    }

    private func lyricsTapped() {
        if showLyrics { showLyrics = false }
        else if model.settings.lyricsConsent { showLyrics = true }
        else { askLyricsConsent = true }
    }

    // MARK: Settings drawer

    @ViewBuilder
    private func settingsDrawer(height: CGFloat, dims: Bool, safeTop: CGFloat) -> some View {
        if showSettings {
            // Measure the whole window (title bar / notch strip included) so margins are exact.
            GeometryReader { full in
                let layout = DrawerLayout(size: full.size, narrow: dims, stage: stage, notchStrip: safeTop)
                ZStack(alignment: .topLeading) {
                    // Narrow windows: the drawer covers the player, so dim it; click outside to close.
                    if dims {
                        Color.black.opacity(0.35)
                            .onTapGesture { showSettings = false }
                            .transition(.opacity)
                    }
                    drawerCard
                        .frame(width: layout.cardWidth, height: layout.cardHeight)
                        .offset(x: layout.x, y: layout.y)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                .frame(width: full.size.width, height: full.size.height, alignment: .topLeading)
            }
            .ignoresSafeArea()
        }
    }

    /// Where the floating settings card goes. Margins are equal on every side that has room;
    /// in a window it stays clear of the traffic-light buttons.
    private struct DrawerLayout {
        var cardWidth: CGFloat
        var cardHeight: CGFloat
        var x: CGFloat
        var y: CGFloat

        init(size: CGSize, narrow: Bool, stage: Bool, notchStrip: CGFloat) {
            let margin: CGFloat = 16
            cardWidth = min(360, size.width - 2 * margin)
            // Narrow windows center the card; otherwise it hugs the right edge.
            x = narrow ? (size.width - cardWidth) / 2 : size.width - margin - cardWidth
            let top: CGFloat
            let bottom: CGFloat
            if stage {
                // Full screen: the notch strip is unusable, so mirror it at the bottom to center.
                top = notchStrip + margin
                bottom = notchStrip + margin
            } else {
                // Window: the transparent title bar is usable unless the card would cover the
                // traffic lights (they span ~0–80 pt from the left, ~28 pt tall).
                let clearsTrafficLights = x > 84
                let inset: CGFloat = clearsTrafficLights ? margin : 28 + 12
                top = inset
                bottom = inset
            }
            y = top
            cardHeight = max(240, size.height - top - bottom)
        }
    }

    private var drawerCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.bezl(20, .bold))
                Spacer()
                Button {
                    showSettings = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .bezlGlass(Circle(), tint: nil, clear: true)
                .keyboardShortcut(.cancelAction)
                .help("Close settings (Esc)")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 2)
            ScrollView(showsIndicators: false) {
                MenuPanel(model: model, inWindow: true)
            }
            .defaultScrollAnchor(.top)
        }
        // Floating Liquid Glass card, inset from the edges (Apple's glass sheets float).
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .bezlGlass(RoundedRectangle(cornerRadius: 30, style: .continuous), tint: color(palette.primary))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 10)
    }

    // MARK: Pieces

    @ViewBuilder
    private var background: some View {
        if stage {
            // Stage mode: pure black so the bezel glow is the only light around the player.
            Color.black.ignoresSafeArea()
        } else {
            ZStack {
                Color(white: 0.07)
                RadialGradient(colors: [color(palette.primary).opacity(0.35), .clear],
                               center: .top, startRadius: 0, endRadius: 520)
                RadialGradient(colors: [color(palette.secondary).opacity(0.22), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: 480)
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.8), value: palette)
        }
    }

    private func titles(_ track: Track, _ m: Metrics) -> some View {
        VStack(spacing: 4 * m.scale) {
            Text(track.title)
                .font(.bezl(22 * m.scale, .bold))
                .lineLimit(1)
            Text(track.artist)
                .font(.bezl(15 * m.scale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 24)
    }

    private func compactHeader(_ track: Track, _ m: Metrics) -> some View {
        HStack(spacing: 12 * m.scale) {
            ArtworkView(data: nowPlaying.artworkData, glow: palette.primary, cornerRadius: 8 * m.scale)
                .frame(width: 56 * m.scale, height: 56 * m.scale)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.bezl(17 * m.scale, .semibold)).lineLimit(1)
                Text(track.artist).font(.bezl(14 * m.scale)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func controls(_ track: Track, _ m: Metrics) -> some View {
        HStack(spacing: 14 * m.scale) {
            ControlButton(symbol: "gobackward.15", size: 44 * m.scale) { nowPlaying.send(.skip(seconds: -15)) }
                .help("Back 15 seconds")
            ControlButton(symbol: "backward.fill", size: 50 * m.scale) { nowPlaying.send(.previous) }
                .help("Previous")
            ControlButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 64 * m.scale, prominent: true) {
                nowPlaying.send(.playPause)
            }
            .help(track.isPlaying ? "Pause" : "Play")
            .keyboardShortcut(.space, modifiers: [])
            ControlButton(symbol: "forward.fill", size: 50 * m.scale) { nowPlaying.send(.next) }
                .help("Next")
            ControlButton(symbol: "goforward.15", size: 44 * m.scale) { nowPlaying.send(.skip(seconds: 15)) }
                .help("Forward 15 seconds")
        }
    }

    private func lyricsButton(_ m: Metrics) -> some View {
        Button {
            lyricsTapped()
        } label: {
            Label("Lyrics", systemImage: "quote.bubble.fill")
                .font(.bezl(13 * m.scale, .semibold))
                .padding(.horizontal, 14 * m.scale)
                .padding(.vertical, 8 * m.scale)
                .background(Capsule().fill(.white.opacity(showLyrics ? 0.22 : 0.1)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func emptyState(_ m: Metrics) -> some View {
        VStack(spacing: 10 * m.scale) {
            Image(systemName: "music.note")
                .font(.bezl(54 * m.scale, .light))
                .foregroundStyle(.secondary)
            Text("Nothing playing")
                .font(.bezl(20 * m.scale, .semibold))
            Text(nowPlaying.deniedApps.isEmpty
                 ? "Play something in Music or Spotify."
                 : "Allow Bezl to control \(nowPlaying.deniedApps.map(\.displayName).sorted().joined(separator: " and ")) in System Settings → Privacy & Security → Automation.")
                .font(.bezl(13 * m.scale))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300 * m.scale)
        }
        .frame(maxHeight: .infinity)
    }

    private func toolbar(_ m: Metrics) -> some View {
        let size = 38 * min(m.scale, 1.4)
        return HStack(spacing: 10 * min(m.scale, 1.4)) {
            ToolbarToggle(symbol: "paintpalette", isOn: model.settings.look.colorSource == .albumArt,
                          help: "Colors follow the album art", size: size) {
                model.settings.look.colorSource = model.settings.look.colorSource == .albumArt ? .manual : .albumArt
            }
            ToolbarToggle(symbol: motionSymbol, isOn: model.settings.look.motion != .still,
                          help: "Motion: \(model.settings.look.motion.rawValue.capitalized) (click to change)", size: size) {
                let all = AnimationMode.allCases
                let i = all.firstIndex(of: model.settings.look.motion) ?? 0
                model.settings.look.motion = all[(i + 1) % all.count]
            }
            ToolbarToggle(symbol: model.settings.isActive ? "lightbulb.fill" : "lightbulb", isOn: model.settings.isActive,
                          help: "Turn the light on or off", size: size) {
                model.settings.isActive.toggle()
            }
            Button {
                showSettings.toggle()
            } label: {
                Text("Settings")
                    .font(.bezl(13 * min(m.scale, 1.4), .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: size)
                    .background(Capsule().fill(.white.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            ToolbarToggle(symbol: stage ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          isOn: stage, help: stage ? "Exit full screen (F or Esc)" : "Full screen stage mode (F)", size: size) {
                model.togglePlayerFullScreen()
            }
            ToolbarToggle(symbol: "dock.rectangle", isOn: model.settings.showInDock, help: "Show in Dock", size: size) {
                model.settings.showInDock.toggle()
            }
            ToolbarToggle(symbol: "lock.display", isOn: model.settings.lockScreenPlayer,
                          help: "Lock screen player (experimental)", size: size) {
                model.settings.lockScreenPlayer.toggle()
            }
        }
    }

    private var motionSymbol: String {
        switch model.settings.look.motion {
        case .beat: "waveform"
        case .breathe: "wind"
        case .still: "minus"
        }
    }

    private func color(_ c: RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }
}

// MARK: - Components

struct ArtworkView: View {
    var data: Data?
    var glow: RGB
    var cornerRadius: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "music.note").font(.bezl(40, .light)).foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: Color(.sRGB, red: glow.r, green: glow.g, blue: glow.b).opacity(0.55), radius: 28)
        .animation(.easeInOut(duration: 0.4), value: data)
    }
}

struct ControlButton: View {
    var symbol: String
    var size: CGFloat
    var prominent = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.bezl(size * (prominent ? 0.36 : 0.32), .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(prominent ? 0.16 : (hovering ? 0.12 : 0.06))))
                .overlay(Circle().strokeBorder(.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ToolbarToggle: View {
    var symbol: String
    var isOn: Bool
    var help: String
    var size: CGFloat = 38
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.bezl(size * 0.37, .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .background(Circle().fill(.white.opacity(isOn ? 0.18 : 0.07)))
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct ProgressRow: View {
    let nowPlaying: NowPlayingService
    var scale: CGFloat = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let duration = nowPlaying.track?.duration ?? 0
            let position = nowPlaying.currentPosition(at: context.date)
            VStack(spacing: 4) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(.white.opacity(0.8))
                            .frame(width: duration > 0 ? g.size.width * min(position / duration, 1) : 0)
                    }
                }
                .frame(height: 4 * max(scale, 1))
                HStack {
                    Text(format(position))
                    Spacer()
                    Text(duration > 0 ? "-" + format(max(duration - position, 0)) : "")
                }
                .font(.bezlCaption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct LyricsPane: View {
    let model: AppModel
    var scale: CGFloat = 1

    var body: some View {
        switch model.lyrics.state {
        case .idle, .loading:
            ProgressView().controlSize(.small).frame(maxHeight: .infinity)
        case let .synced(lyrics):
            SyncedLyricsView(lyrics: lyrics, nowPlaying: model.nowPlaying, scale: scale)
        case let .plain(text):
            ScrollView {
                Text(text)
                    .font(.bezl(17 * scale, .semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
            }
        case .instrumental:
            message("Instrumental")
        case .notFound:
            message("No lyrics found for this song.")
        case let .failed(error):
            message("Couldn't load lyrics.\n\(error)")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.bezlCallout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SyncedLyricsView: View {
    let lyrics: SyncedLyrics
    let nowPlaying: NowPlayingService
    var scale: CGFloat = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            // Show a line a moment early so it lands with the vocal.
            let current = lyrics.lineIndex(at: nowPlaying.currentPosition(at: context.date) + 0.25)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14 * scale) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.bezl(22 * scale, .bold))
                                .foregroundStyle(.white.opacity(index == current ? 1 : 0.32))
                                .blur(radius: index == current ? 0 : 0.4)
                                .id(index)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 120)
                }
                .onChange(of: current) { _, new in
                    guard let new else { return }
                    withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(new, anchor: .center) }
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            }
            .animation(.easeInOut(duration: 0.3), value: current)
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                     .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}


// MARK: - Glass

extension View {
    /// Apple's Liquid Glass on macOS 26+, frosted material before that.
    /// `clear` uses the highly transparent variant (just a faint color wash and lit edges).
    @ViewBuilder
    func bezlGlass<S: Shape>(_ shape: S, tint: Color?, clear: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let base: Glass = clear ? .clear : .regular
            self.glassEffect(base.tint(tint?.opacity(clear ? 0.06 : 0.18)).interactive(), in: shape)
        } else {
            self.background(clear ? AnyShapeStyle(Color.white.opacity(0.04)) : AnyShapeStyle(.ultraThinMaterial), in: shape)
                .overlay(shape.stroke(.white.opacity(clear ? 0.12 : 0.14), lineWidth: 1))
        }
    }

    /// Fades to nothing (and stops taking clicks) while the player is idle in full screen.
    func fadesWhenIdle(_ hidden: Bool) -> some View {
        self.opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .animation(.easeInOut(duration: hidden ? 0.9 : 0.25), value: hidden)
    }
}

/// A borderless symbol button for glass panels: no circle, soft hover highlight.
struct GlassIconButton: View {
    var symbol: String
    var size: CGFloat
    var isOn: Bool = true
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .frame(width: size * 1.7, height: size * 1.7)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
                .scaleEffect(hovering ? 1.06 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
