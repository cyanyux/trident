import AppKit
import ApplicationServices
import SwiftUI

/// Hosts the first-run wizard and the standalone "free the swipe" help panel, and
/// drives their live detection (Accessibility + the trackpad Spaces conflict) from
/// a poll timer while a window is open. Accessory app, so it activates itself and
/// orders the window front rather than relying on a Dock launch.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {

    private let model = OnboardingModel()
    private var wizardWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var pollTimer: Timer?
    private let onComplete: () -> Void

    init(
        onSetMiddleClick: @escaping (Bool) -> Void,
        onSetAppSwitch: @escaping (Bool) -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        super.init()
        model.onSetMiddleClick = onSetMiddleClick
        model.onSetAppSwitch = onSetAppSwitch
        model.onOpenAccessibility = { AccessibilitySettings.prompt(); AccessibilitySettings.openSettings() }
        model.onOpenTrackpad = { Self.openTrackpadSettings() }
        model.onFinish = { [weak self] in self?.wizardWindow?.close() }
    }

    // MARK: - Presentation

    /// Show the full first-run wizard (also reachable later via the menu).
    func present() {
        // Reflect current prefs without re-triggering the menu's enable-help flow
        // (these go through setAppSwitchEnabled, not the menu's toggleAppSwitch).
        model.middleClickEnabled = Preferences.shared.middleClickEnabled
        model.appSwitchEnabled = Preferences.shared.appSwitchEnabled
        model.stepIndex = 0
        refreshDetections()

        if wizardWindow == nil {
            let host = NSHostingController(rootView: OnboardingView(model: model))
            wizardWindow = makeWindow(host, title: "Welcome to Trident")
        }
        startPolling()
        bringToFront(wizardWindow)
    }

    /// Show the focused trackpad-conflict helper. Call only when the conflict is
    /// actually present (otherwise enabling app-switch should just work silently).
    func presentSwipeConflictHelp() {
        refreshDetections()
        if helpWindow == nil {
            let host = NSHostingController(
                rootView: SwipeConflictHelpView(model: model) { [weak self] in self?.helpWindow?.close() }
            )
            helpWindow = makeWindow(host, title: "Swipe → Switch App")
        }
        startPolling()
        bringToFront(helpWindow)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        let closed = notification.object as? NSWindow
        if closed == wizardWindow {
            // Finishing or dismissing the wizard counts as "seen" so it won't reappear
            // on every launch; the menu's Setup Assistant reopens it on demand.
            Preferences.shared.didOnboarding = true
            wizardWindow = nil
        } else if closed == helpWindow {
            helpWindow = nil
        }
        if wizardWindow == nil && helpWindow == nil { stopPolling() }
        onComplete()
    }

    // MARK: - Detection

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDetections() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshDetections() {
        // Authoritative (probe-backed) check, so a revoke during onboarding is reflected too
        // — AXIsProcessTrusted()'s cache stays stale-true after a revoke.
        model.accessibilityGranted = AccessibilityMonitor.isTrusted()
        model.swipeConflictResolved = !TrackpadSettings.threeFingerHorizSwipeActive
    }

    // MARK: - Window helpers

    private func makeWindow(_ vc: NSViewController, title: String) -> NSWindow {
        let win = NSWindow(contentViewController: vc)
        win.title = title
        // Transparent, full-height titlebar so the Liquid Glass background flows behind
        // it; the SwiftUI content adds top padding to clear the traffic lights.
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false   // we clear our own reference in windowWillClose
        win.delegate = self
        // Size to the SwiftUI content *before* centering. center() called while the
        // window is still zero-size (the hosting controller hasn't laid out yet) leaves
        // it pinned near the top, since the content then grows downward from there.
        vc.view.layoutSubtreeIfNeeded()
        win.setContentSize(vc.view.fittingSize)
        win.center()
        return win
    }

    private func bringToFront(_ win: NSWindow?) {
        guard let win else { return }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: - Settings deep links

    private static func openTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Reads the live macOS trackpad gesture preference that conflicts with Trident's
/// app-switch swipe.
enum TrackpadSettings {
    /// True when a three-finger horizontal swipe still drives "Swipe between
    /// full-screen apps" (the Spaces switch) — i.e. the conflict is unresolved.
    ///
    /// Checks both the built-in and Bluetooth (Magic Trackpad) preference domains.
    /// The key is absent until the user changes it, and the macOS default has the
    /// gesture ON — so "no value anywhere" is treated as active.
    ///
    /// Known limit: with both a built-in and a Magic Trackpad where one is explicitly
    /// disabled and the other has never been touched (key absent → default ON), this
    /// reports "resolved" while the untouched device still conflicts. Distinguishing
    /// that needs per-device enumeration (which domain maps to a *connected* trackpad);
    /// the single-trackpad cases — the overwhelming majority — are exact.
    static var threeFingerHorizSwipeActive: Bool {
        let key = "TrackpadThreeFingerHorizSwipeGesture" as CFString
        var sawDisabled = false
        for domain in ["com.apple.AppleMultitouchTrackpad",
                       "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
            let app = domain as CFString
            CFPreferencesAppSynchronize(app)   // flush cfprefsd cache so a just-made change is seen
            // CopyAppValue searches the full host cascade (any-host + by-host). These
            // keys live in the any-host domain on at least some Macs, which a by-host-only
            // read (kCFPreferencesCurrentHost) missed — the original detection bug.
            // Read as NSNumber, not `as? Int`: the value can be stored as a CFBoolean, which
            // bridges to NSNumber but would intermittently fail an `as? Int` cast (→ read as
            // absent → mis-reported as ON). NSNumber covers both CFNumber and CFBoolean.
            if let value = CFPreferencesCopyAppValue(key, app) as? NSNumber {
                if value.intValue != 0 { return true }   // a trackpad still has 3-finger swipe → conflict
                sawDisabled = true
            }
        }
        // Found an explicit 0 → resolved. Absent in every domain → macOS default is ON.
        return !sawDisabled
    }
}
