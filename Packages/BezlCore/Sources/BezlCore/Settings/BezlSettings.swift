import Foundation

public enum AnimationMode: String, Codable, Sendable, CaseIterable {
    case beat, breathe, still
}

public enum ColorSource: String, Codable, Sendable, CaseIterable {
    /// Follow the current track's artwork (falls back to the manual colors).
    case albumArt
    /// Always use the manual colors ("override album color").
    case manual
}

/// Per-display options, keyed by the display's stable UUID string.
public struct DisplaySettings: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var followNotch: Bool = true
    /// nil = automatic (10 pt top corners on notched displays, square elsewhere).
    public var cornerRadius: Double?

    public init(enabled: Bool = true, followNotch: Bool = true, cornerRadius: Double? = nil) {
        self.enabled = enabled
        self.followNotch = followNotch
        self.cornerRadius = cornerRadius
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        followNotch = try c.decodeIfPresent(Bool.self, forKey: .followNotch) ?? true
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius)
    }
}

/// The visual subset of settings, which is what presets store.
public struct LookSettings: Codable, Sendable, Equatable {
    public var primary: RGB = RGB(hex: 0xFF5E3A)
    public var secondary: RGB = RGB(hex: 0x7A5CFF)
    /// Share of the loop covered by the primary color (0.1...0.9).
    public var primaryWeight: Double = 0.6
    public var colorSource: ColorSource = .albumArt
    public var motion: AnimationMode = .beat
    /// Rim band width in points (1...40): "hairline" to "broad band".
    public var thickness: Double = 14
    /// 0...1 — how far the light spills inward.
    public var glow: Double = 0.55
    /// 0...1 — overall brightness.
    public var intensity: Double = 0.85
    /// 0...1 — how hard beats push brightness and thickness.
    public var beatStrength: Double = 0.7
    /// Slow drift of the gradient around the screen, in turns per minute (0 = off).
    public var rotationSpeed: Double = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = LookSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primary = try c.decodeIfPresent(RGB.self, forKey: .primary) ?? d.primary
        secondary = try c.decodeIfPresent(RGB.self, forKey: .secondary) ?? d.secondary
        primaryWeight = try c.decodeIfPresent(Double.self, forKey: .primaryWeight) ?? d.primaryWeight
        colorSource = (try? c.decodeIfPresent(ColorSource.self, forKey: .colorSource)) ?? d.colorSource
        motion = (try? c.decodeIfPresent(AnimationMode.self, forKey: .motion)) ?? d.motion
        thickness = try c.decodeIfPresent(Double.self, forKey: .thickness) ?? d.thickness
        glow = try c.decodeIfPresent(Double.self, forKey: .glow) ?? d.glow
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? d.intensity
        beatStrength = try c.decodeIfPresent(Double.self, forKey: .beatStrength) ?? d.beatStrength
        rotationSpeed = try c.decodeIfPresent(Double.self, forKey: .rotationSpeed) ?? d.rotationSpeed
    }

    /// Clamps every value into its supported range.
    public var sanitized: LookSettings {
        var s = self
        s.primaryWeight = min(max(primaryWeight, 0.1), 0.9)
        s.thickness = min(max(thickness, 1), 40)
        s.glow = min(max(glow, 0), 1)
        s.intensity = min(max(intensity, 0), 1)
        s.beatStrength = min(max(beatStrength, 0), 1)
        s.rotationSpeed = min(max(rotationSpeed, -10), 10)
        s.primary = primary.clamped
        s.secondary = secondary.clamped
        return s
    }
}

public struct BezlSettings: Codable, Sendable, Equatable {
    public static let storageKey = "settings.v1"

    public var isActive: Bool = true
    public var look = LookSettings()
    /// When off, beat mode behaves like still mode (no audio capture at all).
    public var musicSync: Bool = true
    public var displays: [String: DisplaySettings] = [:]
    public var hideFromScreenCapture: Bool = false
    public var hideInFullScreen: Bool = false
    public var hasCompletedOnboarding: Bool = false
    /// Show a Dock icon (regular app) instead of living only in the menu bar.
    public var showInDock: Bool = false
    /// Experimental: keep the glow and a mini player visible over the lock screen.
    public var lockScreenPlayer: Bool = false
    /// Check GitHub Releases for a newer version once a day. Off by default (network request).
    public var checkForUpdatesAutomatically: Bool = false
    public var lastUpdateCheck: Date?
    /// The user agreed to send track title + artist to LRCLIB to fetch lyrics.
    public var lyricsConsent: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = BezlSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? d.isActive
        look = try c.decodeIfPresent(LookSettings.self, forKey: .look) ?? d.look
        musicSync = try c.decodeIfPresent(Bool.self, forKey: .musicSync) ?? d.musicSync
        displays = try c.decodeIfPresent([String: DisplaySettings].self, forKey: .displays) ?? d.displays
        hideFromScreenCapture = try c.decodeIfPresent(Bool.self, forKey: .hideFromScreenCapture) ?? d.hideFromScreenCapture
        hideInFullScreen = try c.decodeIfPresent(Bool.self, forKey: .hideInFullScreen) ?? d.hideInFullScreen
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? d.showInDock
        lockScreenPlayer = try c.decodeIfPresent(Bool.self, forKey: .lockScreenPlayer) ?? d.lockScreenPlayer
        checkForUpdatesAutomatically = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdatesAutomatically)
            ?? d.checkForUpdatesAutomatically
        lastUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        lyricsConsent = try c.decodeIfPresent(Bool.self, forKey: .lyricsConsent) ?? d.lyricsConsent
    }

    public func display(_ id: String) -> DisplaySettings {
        displays[id] ?? DisplaySettings()
    }

    public static func decode(_ data: Data) -> BezlSettings? {
        try? JSONDecoder().decode(BezlSettings.self, from: data)
    }

    public func encoded() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(self)
    }
}
