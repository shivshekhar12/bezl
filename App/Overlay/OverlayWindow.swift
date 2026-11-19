import AppKit

/// A borderless, transparent, click-through panel covering one whole screen, above everything,
/// on every Space, never focusable.
final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovable = false
        // Above full-screen apps and the menu bar, below the cursor. `.screenSaver` (1000) keeps
        // the rim visible over the menu bar and full-screen video without covering system alerts
        // that use higher levels (e.g. the screen-lock UI and the cursor layer).
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
