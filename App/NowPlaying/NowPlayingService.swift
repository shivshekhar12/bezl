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
    var isPlaying: Bool
    var artworkURL: String?
}

/// Follows Music and Spotify through their distributed notifications (no polling) and reads
/// track info + artwork with AppleScript. Never launches either app.
@MainActor
@Observable
final class NowPlayingService {
    private(set) var track: Track?
    private(set) var palette: Palette?
    private(set) var deniedApps: Set<MusicApp> = []
    var onPaletteChange: ((Palette?) -> Void)?

    @ObservationIgnored private var lastPlayingApp: MusicApp?
    @ObservationIgnored private var paletteCache: [String: Palette] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

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
    }

    func stop() {
        for o in observers {
            DistributedNotificationCenter.default().removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        observers.removeAll()
        refreshTask?.cancel()
        started = false
        track = nil
        setPalette(nil)
    }

    /// Asks the user for Automation access by touching each running app once.
    func requestAccess() {
        refresh()
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
            if chosen != self.track { self.track = chosen }
            await self.updatePalette(for: chosen)
        }
    }

    private func choose(from tracks: [Track]) -> Track? {
        let playing = tracks.filter(\.isPlaying)
        if let last = lastPlayingApp, let t = playing.first(where: { $0.app == last }) { return t }
        if let t = playing.first { return t }
        if let last = lastPlayingApp, let t = tracks.first(where: { $0.app == last }) { return t }
        return tracks.first
    }

    // MARK: - AppleScript

    private func readTrack(_ app: MusicApp) async -> Track? {
        // Guard again right before scripting: `tell application` would launch a quit app.
        guard app.isRunning else { return nil }
        let source: String
        switch app {
        case .music:
            source = """
            tell application id "com.apple.Music"
                set playerState to player state as string
                if playerState is "playing" or playerState is "paused" then
                    try
                        set t to current track
                        return playerState & linefeed & (persistent ID of t) & linefeed & (name of t) & linefeed & (artist of t)
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
                        return playerState & linefeed & (id of t) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (artwork url of t)
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
            guard parts.count >= 4 else { return nil }
            return Track(app: app, id: parts[1], title: parts[2], artist: parts[3],
                         isPlaying: parts[0] == "playing",
                         artworkURL: parts.count >= 5 ? parts[4] : nil)
        case let .failure(code, message):
            if result.isPermissionDenied { deniedApps.insert(app) }
            log.error("\(app.displayName, privacy: .public) script failed (\(code)): \(message, privacy: .public)")
            return nil
        case .data:
            return nil
        }
    }

    private func artworkData(for track: Track) async -> Data? {
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
            // Spotify only exposes a URL; this download of the cover image is Bezl's only
            // network request besides update checks. No user data is sent.
            guard let string = track.artworkURL, let url = URL(string: string),
                  url.scheme == "https" else { return nil }
            return try? await session.data(from: url).0
        }
    }

    // MARK: - Palette

    private func updatePalette(for track: Track?) async {
        guard let track else { setPalette(nil); return }
        let key = "\(track.app.rawValue):\(track.id)"
        if let cached = paletteCache[key] { setPalette(cached); return }
        guard let data = await artworkData(for: track) else {
            if self.track?.id == track.id { setPalette(nil) }
            return
        }
        let palette = await Task.detached(priority: .utility) { ArtworkPalette.palette(fromImageData: data) }.value
        guard !Task.isCancelled, self.track?.id == track.id else { return }
        if let palette {
            paletteCache[key] = palette
            cacheOrder.append(key)
            if cacheOrder.count > 20 { paletteCache[cacheOrder.removeFirst()] = nil }
        }
        setPalette(palette)
    }

    private func setPalette(_ new: Palette?) {
        guard new != palette else { return }
        palette = new
        onPaletteChange?(new)
    }
}
