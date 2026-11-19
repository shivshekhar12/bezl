import AppKit
import BezlCore
import Foundation
import Observation
import os

private let log = Logger(subsystem: "io.github.shivshekhar12.bezl", category: "nowplaying")

enum MusicApp: String, CaseIterable, Sendable {
    case music, spotify

    var bundleID: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }

    var displayName: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }

    var notificationName: Notification.Name {
        switch self {
        case .music: Notification.Name("com.apple.Music.playerInfo")
        case .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

struct Track: Equatable, Sendable {
    var app: MusicApp
    var id: String
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    /// Seconds; 0 when unknown (e.g. live radio).
    var duration: Double
    var artworkURL: String?

    var cacheKey: String { "\(app.rawValue):\(id)" }
}

enum PlayerCommand: Sendable {
    case playPause, next, previous
    case skip(seconds: Double)
}

/// Follows Music and Spotify through their distributed notifications (no polling) and reads
/// track info + artwork with AppleScript. Never launches either app.
@MainActor
@Observable
final class NowPlayingService {
    private(set) var track: Track?
    private(set) var palette: Palette?
    /// Encoded artwork image (PNG/JPEG) for the player UI.
    private(set) var artworkData: Data?
    private(set) var deniedApps: Set<MusicApp> = []
    /// Last known playback position (seconds) and when it was sampled.
    private(set) var position: Double = 0
    private(set) var positionSampledAt: Date = .distantPast
    var onPaletteChange: ((Palette?) -> Void)?

    /// Poll the playback position (only while a player UI is visible).
    var wantsPosition = false {
        didSet { if wantsPosition != oldValue { updatePositionTimer() } }
    }

    @ObservationIgnored private var lastPlayingApp: MusicApp?
    @ObservationIgnored private var artCache: [String: (palette: Palette?, data: Data)] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var positionTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private(set) var started = false
    @ObservationIgnored private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Playback position extrapolated to now (smooth progress bars and lyrics between polls).
    func currentPosition(at date: Date = Date()) -> Double {
        guard let track else { return 0 }
        var p = position
        if track.isPlaying { p += date.timeIntervalSince(positionSampledAt) }
        return track.duration > 0 ? min(max(p, 0), track.duration) : max(p, 0)
    }

    func start() {
        guard !started else { return }
        started = true
        let center = DistributedNotificationCenter.default()
        for app in MusicApp.allCases {
            observers.append(center.addObserver(forName: app.notificationName, object: nil, queue: .main) { [weak self] note in
                let state = note.userInfo?["Player State"] as? String
                MainActor.assumeIsolated {
                    if state == "Playing" { self?.lastPlayingApp = app }
                    self?.refresh()
                }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated {
                    if MusicApp.allCases.contains(where: { $0.bundleID == bundleID }) { self?.refresh() }
                }
            })
        }
        refresh()
        updatePositionTimer()
    }

    func stop() {
        for o in observers {
            DistributedNotificationCenter.default().removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        observers.removeAll()
        refreshTask?.cancel()
        positionTimer?.invalidate()
        positionTimer = nil
        started = false
        track = nil
        artworkData = nil
        setPalette(nil)
    }

    /// Re-reads state from every running music app and picks the one to follow.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            var tracks: [Track] = []
            for app in MusicApp.allCases where app.isRunning {
                if let t = await self.readTrack(app) { tracks.append(t) }
            }
            guard !Task.isCancelled else { return }
            let chosen = self.choose(from: tracks)
            if chosen != self.track {
                let trackChanged = chosen?.cacheKey != self.track?.cacheKey
                self.track = chosen
                if trackChanged { self.position = 0; self.positionSampledAt = Date() }
            }
            if self.wantsPosition { await self.pollPosition() }
            await self.updateArtwork(for: chosen)
        }
    }

    private func choose(from tracks: [Track]) -> Track? {
        let playing = tracks.filter(\.isPlaying)
        if let last = lastPlayingApp, let t = playing.first(where: { $0.app == last }) { return t }
        if let t = playing.first { return t }
        if let last = lastPlayingApp, let t = tracks.first(where: { $0.app == last }) { return t }
        return tracks.first
    }

    // MARK: - Controls

    func send(_ command: PlayerCommand) {
        guard let app = track?.app, app.isRunning else { return }
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        case let .skip(seconds):
            verb = "set player position to ((player position) + (\(seconds)))"
            position = currentPosition() + seconds   // optimistic UI
            positionSampledAt = Date()
        }
        Task {
            let result = await ScriptRunner.run("tell application id \"\(app.bundleID)\" to \(verb)")
            if result.isPermissionDenied { deniedApps.insert(app) }
            // Music/Spotify also post a notification; refresh anyway for skips (they don't).
            try? await Task.sleep(for: .milliseconds(150))
            refresh()
        }
    }

    // MARK: - Position

    private func updatePositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
        guard wantsPosition, started else { return }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.track?.isPlaying == true else { return }
                Task { await self.pollPosition() }
            }
        }
        Task { await pollPosition() }
    }

    private func pollPosition() async {
        guard let app = track?.app, app.isRunning else { return }
        let result = await ScriptRunner.run("tell application id \"\(app.bundleID)\" to return player position as string")
        if case let .text(text) = result,
           let value = Double(text.replacingOccurrences(of: ",", with: ".")) {
            position = value
            positionSampledAt = Date()
        }
    }

    // MARK: - AppleScript

    private func readTrack(_ app: MusicApp) async -> Track? {
        // Guard again right before scripting: `tell application` would launch a quit app.
        guard app.isRunning else { return nil }
        // Note: `st` is reserved in AppleScript (ordinal suffix) — use descriptive names.
        let source: String
        switch app {
        case .music:
            source = """
            tell application id "com.apple.Music"
                set playerState to player state as string
                if playerState is "playing" or playerState is "paused" then
                    try
                        set t to current track
                        return playerState & linefeed & (persistent ID of t) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as string)
                    end try
                end if
                return playerState
            end tell
            """
        case .spotify:
            source = """
            tell application id "com.spotify.client"
                set playerState to player state as string
                if playerState is "playing" or playerState is "paused" then
                    try
                        set t to current track
                        return playerState & linefeed & (id of t) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (((duration of t) / 1000) as string) & linefeed & (artwork url of t)
                    end try
                end if
                return playerState
            end tell
            """
        }
        let result = await ScriptRunner.run(source)
        switch result {
        case let .text(text):
            deniedApps.remove(app)
            let parts = text.components(separatedBy: "\n")
            guard parts.count >= 6 else { return nil }
            let duration = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
            return Track(app: app, id: parts[1], title: parts[2], artist: parts[3], album: parts[4],
                         isPlaying: parts[0] == "playing", duration: duration,
                         artworkURL: parts.count >= 7 ? parts[6] : nil)
        case let .failure(code, message):
            if result.isPermissionDenied { deniedApps.insert(app) }
            log.error("\(app.displayName, privacy: .public) script failed (\(code)): \(message, privacy: .public)")
            return nil
        case .data:
            return nil
        }
    }

    private func fetchArtwork(for track: Track) async -> Data? {
        switch track.app {
        case .music:
            guard track.app.isRunning else { return nil }
            let result = await ScriptRunner.run("""
            tell application id "com.apple.Music"
                try
                    return raw data of artwork 1 of current track
                end try
                return ""
            end tell
            """)
            if case let .data(data) = result, !data.isEmpty { return data }
            return nil
        case .spotify:
            // Spotify only exposes a URL; downloading the cover image is the one network request
            // Bezl makes for album colors. No user data is sent.
            guard let string = track.artworkURL, let url = URL(string: string),
                  url.scheme == "https" else { return nil }
            return try? await session.data(from: url).0
        }
    }

    // MARK: - Artwork + palette

    private func updateArtwork(for track: Track?) async {
        guard let track else {
            artworkData = nil
            setPalette(nil)
            return
        }
        let key = track.cacheKey
        if let cached = artCache[key] {
            if artworkData != cached.data { artworkData = cached.data }
            setPalette(cached.palette)
            return
        }
        guard let data = await fetchArtwork(for: track) else {
            if self.track?.cacheKey == key { artworkData = nil; setPalette(nil) }
            return
        }
        let palette = await Task.detached(priority: .utility) { ArtworkPalette.palette(fromImageData: data) }.value
        guard !Task.isCancelled, self.track?.cacheKey == key else { return }
        artCache[key] = (palette, data)
        cacheOrder.append(key)
        if cacheOrder.count > 12 { artCache[cacheOrder.removeFirst()] = nil }
        artworkData = data
        setPalette(palette)
    }

    private func setPalette(_ new: Palette?) {
        guard new != palette else { return }
        palette = new
        onPaletteChange?(new)
    }
}
