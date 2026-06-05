import AppKit
import ApplicationServices
import TridentCore

/// Drives the app: requests Accessibility, runs the engine when permitted and
/// enabled, and keeps the menu bar in sync. Everything here is main-actor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine = TridentEngine()
    private var menuBar: MenuBarController!
    private var permissionTimer: Timer?
    private var engineRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // An accessory app has no Dock tile, and its asset-catalog app icon isn't
        // reliably resolved for system UI (alerts, notifications). Set it explicitly
        // from a bundled image so those surfaces show the trident, not a blank icon.
        if let icon = NSImage(named: "AppIconImage") {
            NSApp.applicationIconImage = icon
        }

        applyConfig()
        runFirstLaunchSetupIfNeeded()

        // Optional haptic tap on each app-switch step. (A three-finger tap lifts the
        // fingers before the middle click fires, so a tap haptic can't be felt —
        // hence no middle-click haptic.) Fires on the callback thread; hop to main
        // for NSHapticFeedbackManager.
        engine.onActionPerformed = { action in
            guard case .appSwitchStep = action, Preferences.shared.hapticAppSwitch else { return }
            DispatchQueue.main.async {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }

        menuBar = MenuBarController(
            onToggleEnabled: { [weak self] in self?.toggleEnabled() },
            onToggleMiddleClick: { [weak self] in self?.toggleMiddleClick() },
            onToggleAppSwitch: { [weak self] in self?.toggleAppSwitch() },
            onSetSwipeDistance: { [weak self] in self?.setSwipeDistance($0) },
            onSetPalmEdgeBand: { [weak self] in self?.setPalmEdgeBand($0) },
            onResetSwipe: { [weak self] in self?.resetSwipe() },
            onResetPalm: { [weak self] in self?.resetPalm() },
            onToggleHaptics: { [weak self] in self?.toggleHaptics() },
            onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            onHideMenuBarIcon: { [weak self] in self?.hideMenuBarIcon() },
            onOpenAccessibility: { Self.openAccessibilitySettings() },
            onQuit: { NSApp.terminate(nil) }
        )

        // Honour a previously chosen "hide" across launches. Reopening the app
        // (see applicationShouldHandleReopen) brings the icon back.
        menuBar.setIconVisible(!Preferences.shared.hideMenuBarIcon)

        // Prompt for Accessibility on first launch if it isn't granted yet.
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }

        refresh()
        // Poll so the engine starts the moment permission is granted (and stops if
        // it is later revoked) without requiring a relaunch.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    /// Reopening Trident (from Finder/Spotlight/Launchpad, or a second `open`) while
    /// it's already running brings a hidden menu bar icon back — the documented way
    /// to recover it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if Preferences.shared.hideMenuBarIcon {
            Preferences.shared.hideMenuBarIcon = false
            menuBar.setIconVisible(true)
        }
        return true
    }

    // MARK: - Menu actions

    private func toggleEnabled() {
        Preferences.shared.isEnabled.toggle()
        refresh()
    }

    private func toggleMiddleClick() {
        Preferences.shared.middleClickEnabled.toggle()
        applyConfig()
        refresh()
    }

    private func toggleAppSwitch() {
        Preferences.shared.appSwitchEnabled.toggle()
        applyConfig()
        refresh()
    }

    private func setSwipeDistance(_ mm: Float) {
        Preferences.shared.swipeDistanceMM = mm
        engine.setSwipeDistance(mm)
        refresh()
    }

    private func setPalmEdgeBand(_ mm: Float) {
        Preferences.shared.palmEdgeBandMM = mm
        engine.setPalmRejection(edgeBandMM: mm, maxSize: PalmTuning.maxSize(forEdgeBandMM: mm))
        refresh()
    }

    private func toggleHaptics() {
        Preferences.shared.hapticAppSwitch.toggle()
        refresh()
    }

    private func resetSwipe() {
        Preferences.shared.swipeDistanceMM = SwipeTuning.defaultMM
        engine.setSwipeDistance(SwipeTuning.defaultMM)
        refresh()
    }

    private func resetPalm() {
        Preferences.shared.palmEdgeBandMM = PalmTuning.defaultMM
        engine.setPalmRejection(edgeBandMM: PalmTuning.defaultMM,
                                maxSize: PalmTuning.maxSize(forEdgeBandMM: PalmTuning.defaultMM))
        refresh()
    }

    /// One-time setup on the very first launch: enable Launch at Login by default.
    /// The user can turn it back off afterwards and that choice sticks.
    private func runFirstLaunchSetupIfNeeded() {
        guard !Preferences.shared.didFirstRunSetup else { return }
        do {
            try LoginItem.setEnabled(true)
            // Record the one-time setup as done only after it actually succeeded, so a
            // transient registration failure is retried on the next launch instead of
            // being silently skipped forever.
            Preferences.shared.didFirstRunSetup = true
        } catch {
            NSLog("Trident: initial login-item registration failed: \(error)")
        }
    }

    /// Push all gesture preferences into the engine.
    private func applyConfig() {
        let prefs = Preferences.shared
        engine.setSwipeDistance(prefs.swipeDistanceMM)
        engine.setMiddleClickEnabled(prefs.middleClickEnabled)
        engine.setAppSwitchEnabled(prefs.appSwitchEnabled)
        engine.setPalmRejection(edgeBandMM: prefs.palmEdgeBandMM,
                                maxSize: PalmTuning.maxSize(forEdgeBandMM: prefs.palmEdgeBandMM))
    }

    private func toggleLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            NSLog("Trident: failed to update login item: \(error)")
        }
        refresh()
    }

    /// Hide the menu bar icon after confirming, since it's the only way into the app.
    private func hideMenuBarIcon() {
        let alert = NSAlert()
        alert.messageText = "Hide Trident’s menu bar icon?"
        alert.informativeText = "Trident keeps running in the background. To show the "
            + "icon again, open Trident from Finder, Spotlight, or Launchpad."
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        if let icon = NSImage(named: "AppIconImage") { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Preferences.shared.hideMenuBarIcon = true
        menuBar.setIconVisible(false)
    }

    private static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - State

    /// Reconcile the engine and menu with current permission + preferences.
    private func refresh() {
        let trusted = AXIsProcessTrusted()
        let shouldRun = trusted && Preferences.shared.isEnabled

        if shouldRun && !engineRunning {
            engineRunning = engine.start()
        } else if !shouldRun && engineRunning {
            engine.stop()
            engineRunning = false
        }

        let prefs = Preferences.shared
        menuBar.update(
            accessibilityGranted: trusted,
            enabled: prefs.isEnabled,
            running: engineRunning,
            middleClickEnabled: prefs.middleClickEnabled,
            appSwitchEnabled: prefs.appSwitchEnabled,
            swipeDistanceMM: prefs.swipeDistanceMM,
            palmEdgeBandMM: prefs.palmEdgeBandMM,
            hapticFeedback: prefs.hapticAppSwitch,
            launchAtLogin: LoginItem.isEnabled
        )
    }
}
