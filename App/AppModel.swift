import AppKit
import BezlCore
import Observation
import os
import SwiftUI

private let log = Logger(subsystem: "io.github.shivshekhar12.bezl", category: "app")

/// Owns settings and every service, and decides what should be running.
@MainActor
@Observable
final class AppModel {
    var settings: BezlSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
            apply(previous: oldValue)
        }
    }
    private(set) var customPresets: [Preset] = []
    private(set) var displays: [DisplayInfo] = []
    private(set) var audioError: String?
    /// The tap runs but has delivered pure digital silence while a track plays: almost always
    /// a denied "System Audio Recording" permission.
    private(set) var audioPermissionSuspect = false
    private(set) var isSilent = true
    var launchAtLogin: Bool = LaunchAtLogin.isEnabled {
        didSet { LaunchAtLogin.set(launchAtLogin) }
    }

    let nowPlaying = NowPlayingService()
    let lyrics = LyricsService()
    let updates = UpdateChecker()
    /// The player window is open (keeps track info and position polling alive).
    private(set) var playerVisible = false
    /// The player is in full-screen "stage" mode: black except the glowing bezel and the player.
    private(set) var playerFullScreen = false
    /// The player's in-app settings drawer is open.
    var playerSettingsOpen = false
    /// The lyrics pane is showing (fetch lyrics for the current track).
    var lyricsVisible = false {
        didSet { if lyricsVisible != oldValue { syncLyrics() } }
    }
    @ObservationIgnored let lighting = LightingController()
    @ObservationIgnored private(set) var analyzer: AudioAnalyzer!
    @ObservationIgnored private var tap: SystemAudioTap!
    @ObservationIgnored private var overlays: OverlayManager!
    @ObservationIgnored private var hotkey: GlobalHotkey?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var healthTimer: Timer?
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var lockScreen: LockScreenController?
    @ObservationIgnored private lazy var playerWindow: HostedWindow = {
        let w = HostedWindow(title: "Bezl", size: NSSize(width: 440, height: 700), minSize: NSSize(width: 380, height: 560),
                             style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             allowsFullScreen: true, autosaveName: "BezlPlayer") { [unowned self] in
            AnyView(PlayerView(model: self))
        }
        w.onVisibilityChange = { [weak self] visible in self?.playerVisibilityChanged(visible) }
        w.onFullScreenChange = { [weak self] on in self?.playerFullScreen = on }
        return w
    }()
    @ObservationIgnored private lazy var settingsWindow = HostedWindow(
        title: "Bezl Settings", size: NSSize(width: 352, height: 720),
        style: [.titled, .closable, .miniaturizable], autosaveName: "BezlSettings"
    ) { [unowned self] in
        AnyView(ScrollView { MenuPanel(model: self, inWindow: true) }.frame(width: 352))
    }

    init() {
        settings = defaults.data(forKey: BezlSettings.storageKey).flatMap(BezlSettings.decode) ?? BezlSettings()
        if let data = defaults.data(forKey: "presets.v1"), let presets = try? JSONDecoder().decode([Preset].self, from: data) {
            customPresets = presets
        }
    }

    // MARK: - Lifecycle

    func start() {
        analyzer = AudioAnalyzer { [weak self] silent in
            self?.isSilent = silent
            self?.lighting.audioActivityChanged()
        }
        tap = SystemAudioTap(ring: analyzer.ring)
        tap.onRestart = { [weak self] rate in self?.analyzer.start(sampleRate: rate) }
        overlays = OverlayManager(lighting: lighting)
        overlays.onDisplaysChanged = { [weak self] in self?.displays = self?.overlays.displays ?? [] }

        let analyzer = self.analyzer!
        lighting.audioSource = { analyzer.current }
        lighting.onAnimationNeedChanged = { [weak self] on in self?.overlays.setAnimating(on) }
        lighting.onRedrawNeeded = { [weak self] in self?.overlays.setNeedsDisplay() }
        nowPlaying.onPaletteChange = { [weak self] palette in self?.lighting.update(albumPalette: palette) }
        lockScreen = LockScreenController(model: self)
        lockScreen?.onLockChange = { [weak self] locked in
            guard let self else { return }
            self.overlays.setLockScreenMode(locked && self.settings.lockScreenPlayer)
        }
        observeTrackForLyrics()

        hotkey = GlobalHotkey { [weak self] in self?.settings.isActive.toggle() }
        observeSystem()
        apply(previous: nil)
        applyDockPolicy()
        checkForUpdatesIfDue()

        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAudioHealth() }
        }
    }

    func shutdown() {
        tap?.stop()
        analyzer?.stop()
        hotkey?.invalidate()
        saveNow()
    }

    // MARK: - Applying settings

    private var wantsAudio: Bool {
        settings.isActive && settings.musicSync && settings.look.motion == .beat && !screensAsleep
    }

    private var wantsNowPlaying: Bool {
        (settings.isActive && settings.look.colorSource == .albumArt && !screensAsleep)
            || playerVisible || settings.lockScreenPlayer
    }

    private func apply(previous: BezlSettings?) {
        guard overlays != nil else { return }   // not started yet (onboarding)
        lighting.update(look: settings.look)
        overlays.apply(settings)
        displays = overlays.displays
        overlays.setHidden(!settings.isActive || screensAsleep)

        // Audio capture runs only when it's needed (privacy + power).
        if wantsAudio && !tap.isRunning {
            do {
                try tap.start()
                analyzer.start(sampleRate: tap.sampleRate)
                audioError = nil
            } catch {
                audioError = error.localizedDescription
            }
        } else if !wantsAudio && tap.isRunning {
            tap.stop()
            analyzer.stop()
            audioPermissionSuspect = false
        }
        lighting.update(audioReactive: tap.isRunning)

        if wantsNowPlaying { nowPlaying.start() } else { nowPlaying.stop() }

        if previous?.hideInFullScreen != settings.hideInFullScreen { updateFullScreenHiding() }
        if previous?.showInDock != settings.showInDock { applyDockPolicy() }
        if previous?.lockScreenPlayer != settings.lockScreenPlayer {
            lockScreen?.settingChanged()
            overlays.setLockScreenMode((lockScreen?.isLocked ?? false) && settings.lockScreenPlayer)
        }
        if previous?.checkForUpdatesAutomatically == false && settings.checkForUpdatesAutomatically {
            checkForUpdatesIfDue()
        }
    }

    // MARK: - Windows

    func showPlayer() { playerWindow.show() }
    func togglePlayer() { playerWindow.toggle() }
    func showSettings() {
        // A normal window can't appear over a full-screen Space; leave stage mode first.
        if playerFullScreen { playerWindow.toggleFullScreen() }
        settingsWindow.show()
    }
    func togglePlayerFullScreen() { playerWindow.toggleFullScreen() }

    private func playerVisibilityChanged(_ visible: Bool) {
        guard visible != playerVisible else { return }
        playerVisible = visible
        nowPlaying.wantsPosition = visible
        if !visible { lyricsVisible = false }
        apply(previous: settings)
        if visible { nowPlaying.refresh() }
    }

    /// Dock icon on/off. With LSUIElement set, the app starts as an accessory (menu bar only).
    private func applyDockPolicy() {
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Switching to accessory hides our windows' app; bring an open window back.
        if policy == .accessory && (playerWindow.isVisible || settingsWindow.isVisible) {
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    // MARK: - Lyrics

    private func observeTrackForLyrics() {
        withObservationTracking {
            _ = nowPlaying.track?.cacheKey
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncLyrics()
                self?.observeTrackForLyrics()
            }
        }
    }

    private func syncLyrics() {
        if lyricsVisible && settings.lyricsConsent {
            lyrics.load(for: nowPlaying.track)
        }
    }

    // MARK: - Updates

    func checkForUpdates() {
        Task {
            await updates.check()
            settings.lastUpdateCheck = Date()
        }
    }

    private func checkForUpdatesIfDue() {
        guard settings.checkForUpdatesAutomatically else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        checkForUpdates()
    }

    // MARK: - Presets

    var allPresets: [Preset] { Preset.builtIns + customPresets }

    func applyPreset(_ preset: Preset) {
        var look = preset.look
        // Keep the user's color source choice unless the preset is explicitly manual.
        if preset.look.colorSource == .albumArt { look.colorSource = .albumArt }
        settings.look = look.sanitized
    }

    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        customPresets.append(Preset(name: trimmed, look: settings.look))
        savePresets()
    }

    func deletePreset(_ preset: Preset) {
        customPresets.removeAll { $0.id == preset.id }
        savePresets()
    }

    func importPreset(from url: URL) {
        do {
            customPresets.append(try Preset.importing(Data(contentsOf: url)))
            savePresets()
        } catch {
            log.error("Preset import failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func exportPreset(_ preset: Preset, to url: URL) {
        try? preset.exportData().write(to: url, options: .atomic)
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(customPresets) { defaults.set(data, forKey: "presets.v1") }
    }

    // MARK: - Display settings helpers

    func displaySettings(_ id: String) -> DisplaySettings { settings.display(id) }

    func updateDisplay(_ id: String, _ edit: (inout DisplaySettings) -> Void) {
        var ds = settings.display(id)
        edit(&ds)
        settings.displays[id] = ds
    }

    // MARK: - Status

    var statusLine: String {
        if !settings.isActive { return "Off" }
        if !displays.isEmpty && displays.allSatisfy({ !settings.display($0.id).enabled }) {
            return "Every display is turned off"
        }
        if settings.look.motion == .still || !settings.musicSync { return statusWithTrack("Steady glow") }
        if settings.look.motion == .breathe { return statusWithTrack("Breathing") }
        if audioError != nil { return "Audio capture unavailable" }
        if audioPermissionSuspect { return "Allow system audio access" }
        if let track = nowPlaying.track, track.isPlaying {
            return "Syncing to \(track.title)"
        }
        return isSilent ? "Waiting for music" : "Listening"
    }

    private func statusWithTrack(_ base: String) -> String {
        if let track = nowPlaying.track, track.isPlaying, settings.look.colorSource == .albumArt {
            return "\(base) · \(track.title)"
        }
        return base
    }

    var needsAudioPermission: Bool { audioPermissionSuspect }

    var audioStats: AudioAnalyzer.Stats { analyzer?.currentStats ?? .init() }
    var lightState: LightState { analyzer?.current ?? LightState() }

    // MARK: - Health and system events

    private func checkAudioHealth() {
        guard tap.isRunning else { return }
        // Pure zeros for 3 s while Music/Spotify says it's playing → permission is likely denied.
        let playing = nowPlaying.track?.isPlaying ?? false
        let suspect = playing && analyzer.currentStats.zeroSeconds > 3
        if suspect != audioPermissionSuspect { audioPermissionSuspect = suspect }
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (AppModel) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            })
        }
        on(ws, NSWorkspace.screensDidSleepNotification) { $0.setScreensAsleep(true) }
        on(ws, NSWorkspace.screensDidWakeNotification) { $0.setScreensAsleep(false) }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.setScreensAsleep(true) }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setScreensAsleep(false) }
        on(ws, NSWorkspace.activeSpaceDidChangeNotification) { $0.updateFullScreenHiding() }
        on(ws, NSWorkspace.didActivateApplicationNotification) { $0.updateFullScreenHiding() }
        on(ws, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.lighting.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            $0.lighting.invalidate()
        }
        on(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) { $0.overlays.refreshFrameRates() }
    }

    private func setScreensAsleep(_ asleep: Bool) {
        guard asleep != screensAsleep else { return }
        screensAsleep = asleep
        apply(previous: settings)
    }

    private func updateFullScreenHiding() {
        guard settings.isActive else { return }
        if settings.hideInFullScreen {
            // Window lists settle shortly after a Space switch.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self.overlays.setHidden(displayIDs: FullScreenDetector.coveredDisplays())
            }
        } else {
            overlays.setHidden(displayIDs: [])
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    private func saveNow() {
        if let data = settings.encoded() { defaults.set(data, forKey: BezlSettings.storageKey) }
    }
}
