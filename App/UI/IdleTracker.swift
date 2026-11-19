import AppKit
import Observation

/// Detects a few seconds without mouse or keyboard input in Bezl's windows, so full-screen
/// chrome can fade away and leave only the artwork (and lyrics). Any input wakes it.
@MainActor
@Observable
final class IdleTracker {
    private(set) var isIdle = false
    var delay: TimeInterval = 3

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var timer: Timer?

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                             .leftMouseDragged, .scrollWheel, .keyDown, .flagsChanged]
        monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.poke() }
            return event
        }
        poke()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.invalidate()
        timer = nil
        if isIdle { isIdle = false }
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    /// Registers activity: wake up and restart the countdown.
    func poke() {
        if isIdle { isIdle = false }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.goIdle() }
        }
    }

    private func goIdle() {
        guard monitor != nil else { return }
        isIdle = true
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}
