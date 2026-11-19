import AppKit
import SwiftUI

/// An AppKit window hosting a SwiftUI view, created on demand and released on close.
/// AppKit (instead of a SwiftUI `Window` scene) so the app delegate and model can open it
/// directly, e.g. from a Dock click.
@MainActor
final class HostedWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let title: String
    private let size: NSSize
    private let minSize: NSSize?
    private let style: NSWindow.StyleMask
    private let allowsFullScreen: Bool
    private let autosaveName: String
    private let makeContent: () -> AnyView
    var onVisibilityChange: ((Bool) -> Void)?
    var onFullScreenChange: ((Bool) -> Void)?

    init(title: String, size: NSSize, minSize: NSSize? = nil,
         style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView],
         allowsFullScreen: Bool = false, autosaveName: String, content: @escaping () -> AnyView) {
        self.title = title
        self.size = size
        self.minSize = minSize
        self.style = style
        self.allowsFullScreen = allowsFullScreen
        self.autosaveName = autosaveName
        self.makeContent = content
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                             backing: .buffered, defer: false)
            w.title = title
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.acceptsMouseMovedEvents = true   // lets the idle tracker see pointer movement
            w.isReleasedWhenClosed = false
            if let minSize { w.contentMinSize = minSize }
            if allowsFullScreen { w.collectionBehavior.insert(.fullScreenPrimary) }
            w.contentView = NSHostingView(rootView: makeContent())
            w.delegate = self
            w.center()
            w.setFrameAutosaveName(autosaveName)
            // Never let macOS restore these windows (e.g. back into full screen) on relaunch.
            // A menu-bar (accessory) app can't reliably re-enter full screen, which left the
            // player as a screen-sized window with its title bar hidden under the menu bar.
            w.isRestorable = false
            window = w
        }
        if let window, !isFullScreen { Self.keepOnScreen(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        onVisibilityChange?(true)
    }

    func close() {
        window?.close()
    }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    /// Enters or leaves native full screen (opening the window first if needed).
    func toggleFullScreen() {
        guard allowsFullScreen else { return }
        if !isVisible { show() }
        window?.toggleFullScreen(nil)
    }

    /// Fits the window inside the screen's visible area (below the menu bar, above the Dock),
    /// so its title bar and close button are always reachable whatever frame was saved.
    static func keepOnScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = window.frame
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        if f != window.frame { window.setFrame(f, display: true) }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let window { Self.keepOnScreen(window) }
    }

    func windowWillEnterFullScreen(_ notification: Notification) { onFullScreenChange?(true) }
    func windowWillExitFullScreen(_ notification: Notification) { onFullScreenChange?(false) }

    func windowWillClose(_ notification: Notification) {
        if isFullScreen { onFullScreenChange?(false) }
        window?.contentView = nil
        window = nil
        onVisibilityChange?(false)
    }
}
