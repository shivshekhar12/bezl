import AppKit
import SwiftUI

@main
struct BezlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.settings.isActive ? "rays" : "circle.dotted")
                .accessibilityLabel("Bezl")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !model.settings.hasCompletedOnboarding {
            showOnboarding()
        } else {
            model.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    private func showOnboarding() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Bezl"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in
            self?.finishOnboarding()
        })
        window.center()
        window.delegate = self
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finishOnboarding() {
        onboardingWindow?.delegate = nil
        onboardingWindow?.close()
        onboardingWindow = nil
        model.settings.hasCompletedOnboarding = true
        // Starting the model starts the audio tap and reads Music/Spotify, which is when macOS
        // shows its permission prompts — right after the user read why.
        model.start()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === onboardingWindow {
            DispatchQueue.main.async { self.finishOnboarding() }
        }
    }
}
