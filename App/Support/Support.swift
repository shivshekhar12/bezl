import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Launch at login

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Bezl: launch at login change failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - System Settings deep links

enum SystemSettingsLink {
    static func open(_ anchor: String) {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    static func systemAudio() { open("Privacy_AudioCapture") }
    static func automation() { open("Privacy_Automation") }
}

// MARK: - Global hotkey (Carbon; no Accessibility permission needed)

@MainActor
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Default: ⌃⌥⌘L.
    init(keyCode: UInt32 = UInt32(kVK_ANSI_L), modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey),
         action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotkey.action() }
            return noErr
        }, 1, &spec, context, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x425A_4C21), id: 1)   // 'BZL!'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func invalidate() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}

// MARK: - Full-screen detection

enum FullScreenDetector {
    /// Display IDs whose screen is fully covered by a normal-level window (a full-screen app or video).
    /// Uses only window bounds and layers, which need no Screen Recording permission.
    @MainActor
    static func coveredDisplays() -> Set<String> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var covered = Set<String>()
        for screen in NSScreen.screens {
            guard let number = screen.displayNumber, let id = screen.bezlDisplayID else { continue }
            let bounds = CGDisplayBounds(number)   // global coordinates, top-left origin (same as window list)
            for window in info {
                guard (window[kCGWindowLayer as String] as? Int) == 0,
                      (window[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                      let dict = window[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: dict) else { continue }
                if rect.equalTo(bounds) { covered.insert(id); break }
            }
        }
        return covered
    }
}
