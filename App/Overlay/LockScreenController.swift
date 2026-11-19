import AppKit
import BezlCore
import SwiftUI

/// EXPERIMENTAL lock-screen mode. When the screen locks, raise the glow windows and a small
/// now-playing card to the shielding window level, the highest level public API exposes.
/// macOS may still draw the lock screen above them; whether this shows depends on the OS version.
@MainActor
final class LockScreenController {
    private let model: AppModel
    private var observers: [NSObjectProtocol] = []
    private var card: NSPanel?
    private(set) var isLocked = false
    var onLockChange: ((Bool) -> Void)?

    /// One above the shielding window (the layer macOS uses for the lock/login shield).
    static var level: NSWindow.Level { NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1) }

    init(model: AppModel) {
        self.model = model
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(true) }
        })
        observers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(false) }
        })
    }

    private func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        onLockChange?(locked)
        if locked && model.settings.lockScreenPlayer { showCard() } else { hideCard() }
    }

    func settingChanged() {
        if isLocked && model.settings.lockScreenPlayer { showCard() } else { hideCard() }
    }

    private func showCard() {
        guard let screen = NSScreen.main else { return }
        if card == nil {
            let size = NSSize(width: 380, height: 112)
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = Self.level
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: LockScreenCard(model: model))
            card = panel
        }
        guard let card else { return }
        let frame = screen.frame
        card.setFrameOrigin(NSPoint(x: frame.midX - card.frame.width / 2, y: frame.minY + frame.height * 0.16))
        card.orderFrontRegardless()
    }

    private func hideCard() {
        card?.orderOut(nil)
    }
}

/// Glassy mini player for the lock screen (display only; the lock screen takes no clicks).
struct LockScreenCard: View {
    let model: AppModel

    var body: some View {
        let np = model.nowPlaying
        let glow = np.palette?.primary ?? model.settings.look.primary
        HStack(spacing: 14) {
            ArtworkView(data: np.artworkData, glow: glow, cornerRadius: 10)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(np.track?.title ?? "Not Playing").font(.bezlHeadline).lineLimit(1)
                Text(np.track?.artist ?? "").font(.bezlSubheadline).foregroundStyle(.secondary).lineLimit(1)
                ProgressRow(nowPlaying: np).padding(.top, 4)
            }
        }
        .padding(18)
        .frame(width: 380, height: 112)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .preferredColorScheme(.dark)
    }
}
