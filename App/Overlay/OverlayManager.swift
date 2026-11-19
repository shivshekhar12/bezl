import AppKit
import BezlCore

/// Information about a connected display, for the UI and per-display settings.
struct DisplayInfo: Identifiable, Equatable {
    let id: String           // stable UUID string
    let name: String
    let hasNotch: Bool
}

/// Keeps exactly one overlay window per connected, enabled display.
@MainActor
final class OverlayManager {
    private struct Entry {
        let window: OverlayWindow
        let view: GlowView
    }

    private let lighting: LightingController
    private var entries: [String: Entry] = [:]
    private var animating = false
    private var hidden = false            // sleep, full-screen hiding, or master switch
    private(set) var displays: [DisplayInfo] = []
    var onDisplaysChanged: (() -> Void)?

    init(lighting: LightingController) {
        self.lighting = lighting
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private var lastSettings = BezlSettings()

    private func screensChanged() {
        apply(lastSettings)
        onDisplaysChanged?()
    }

    /// Creates, updates or removes windows to match the screens and settings.
    func apply(_ settings: BezlSettings) {
        lastSettings = settings
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.bezlDisplayID else { return nil }
            return DisplayInfo(id: id, name: screen.localizedName, hasNotch: screen.safeAreaInsets.top > 0)
        }

        guard let context = MetalContext.shared else { return }
        var seen = Set<String>()
        for screen in NSScreen.screens {
            guard let id = screen.bezlDisplayID else { continue }
            let ds = settings.display(id)
            guard settings.isActive, ds.enabled else { continue }
            seen.insert(id)

            let geometry = EdgeGeometry.make(
                width: screen.frame.width, height: screen.frame.height,
                safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryLeftWidth: screen.auxiliaryTopLeftArea.map { Double($0.width) },
                auxiliaryRightWidth: screen.auxiliaryTopRightArea.map { Double($0.width) },
                cornerRadiusOverride: ds.cornerRadius)

            if let entry = entries[id] {
                if entry.window.frame != screen.frame {
                    entry.window.setFrame(screen.frame, display: true)
                }
                entry.view.geometry = geometry
                entry.view.followNotch = ds.followNotch
                entry.view.preferredFramesPerSecond = frameRate(for: screen)
                entry.window.sharingType = settings.hideFromScreenCapture ? .none : .readOnly
            } else {
                let window = OverlayWindow(screen: screen)
                if lockScreenLevel { window.level = LockScreenController.level }
                let view = GlowView(frame: NSRect(origin: .zero, size: screen.frame.size), context: context,
                                    lighting: lighting, geometry: geometry, followNotch: ds.followNotch)
                view.autoresizingMask = NSView.AutoresizingMask([.width, .height])
                view.preferredFramesPerSecond = frameRate(for: screen)
                setMode(view, animating: animating)
                window.contentView = view
                window.sharingType = settings.hideFromScreenCapture ? .none : .readOnly
                entries[id] = Entry(window: window, view: view)
                if !hidden { window.orderFrontRegardless() }
            }
        }
        for (id, entry) in entries where !seen.contains(id) {
            entry.window.orderOut(nil)
            entry.window.close()
            entries[id] = nil
        }
        setNeedsDisplay()
    }

    func setNeedsDisplay() {
        for entry in entries.values { entry.view.needsDisplay = true }
    }

    /// Unpauses the display-linked render loop while something is moving.
    func setAnimating(_ on: Bool) {
        guard on != animating else { return }
        animating = on
        for entry in entries.values { setMode(entry.view, animating: on) }
    }

    /// MTKView modes: display-link driven (unpaused, no setNeedsDisplay) while animating;
    /// draw-on-demand (paused + setNeedsDisplay) otherwise, which costs nothing when idle.
    private func setMode(_ view: GlowView, animating on: Bool) {
        view.enableSetNeedsDisplay = !on
        view.isPaused = !on
        if !on { view.needsDisplay = true }
    }

    /// EXPERIMENTAL: lift the glow above the lock screen's shield while locked.
    private var lockScreenLevel = false
    func setLockScreenMode(_ on: Bool) {
        guard on != lockScreenLevel else { return }
        lockScreenLevel = on
        for entry in entries.values {
            entry.window.level = on ? LockScreenController.level : .screenSaver
            if !hidden { entry.window.orderFrontRegardless() }
        }
    }

    /// Hides every overlay (screens asleep, full-screen app, etc.) without destroying windows.
    func setHidden(_ hide: Bool) {
        guard hide != hidden else { return }
        hidden = hide
        for entry in entries.values {
            if hide { entry.window.orderOut(nil) } else { entry.window.orderFrontRegardless() }
        }
    }

    /// Hides the overlay only on the given displays (full-screen detection).
    func setHidden(displayIDs: Set<String>) {
        guard !hidden else { return }
        for (id, entry) in entries {
            if displayIDs.contains(id) { entry.window.orderOut(nil) } else { entry.window.orderFrontRegardless() }
        }
    }

    func refreshFrameRates() {
        for screen in NSScreen.screens {
            guard let id = screen.bezlDisplayID, let entry = entries[id] else { continue }
            entry.view.preferredFramesPerSecond = frameRate(for: screen)
        }
    }

    private func frameRate(for screen: NSScreen) -> Int {
        let maxRate = max(screen.maximumFramesPerSecond, 60)
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? min(60, maxRate) : maxRate
    }
}

extension NSScreen {
    var displayNumber: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// A display UUID that survives reboots and re-plugging (unlike the display number).
    var bezlDisplayID: String? {
        guard let number = displayNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
