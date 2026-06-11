import AppKit
import ApplicationServices
import TridentCore

/// Drives the app: requests Accessibility, runs the engine when permitted and
/// enabled, and keeps the menu bar in sync. Everything here is main-actor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine = TridentEngine()
    private var menuBar: MenuBarController!
    private var updater: Updater!
    private var onboarding: OnboardingController!
    private var permissionTimer: Timer?
    private var engineRunning = false
    /// Last permission state observed by `refresh()`. Drives the adaptive poll cadence.
    private var lastTrusted = false

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

        // Owns the whole auto-update lifecycle; created once and held for the app's
        // lifetime so its scheduled background checks keep running.
        updater = Updater()

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
            onCheckForUpdates: { [weak self] in self?.updater.checkForUpdates() },
            onShowOnboarding: { [weak self] in self?.onboarding.present() },
            onOpenAccessibility: { AccessibilitySettings.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )

        // Drives the first-run wizard and the later "free the swipe" help panel.
        onboarding = OnboardingController(
            onSetMiddleClick: { [weak self] in self?.setMiddleClickEnabled($0) },
            onSetAppSwitch: { [weak self] in self?.setAppSwitchEnabled($0) },
            // Reprobe: the wizard usually closes right after the user granted
            // Accessibility, and the engine should start immediately, not at next poll.
            onComplete: { [weak self] in self?.refresh(reprobe: true) }
        )

        // Honour a previously chosen "hide" across launches. Reopening the app
        // (see applicationShouldHandleReopen) brings the icon back.
        menuBar.setIconVisible(!Preferences.shared.hideMenuBarIcon)

        refresh(reprobe: true)
        // Poll to start the engine when permission is granted and stop it if revoked,
        // without a relaunch. The interval adapts to the current state (see
        // schedulePermissionPoll): snappy while not-yet-trusted so a grant made with no
        // onboarding window open still starts the engine within ~2 s, relaxed once trusted
        // so the per-tick live-revoke probe runs rarely.
        schedulePermissionPoll(trusted: lastTrusted)

        // The multitouch devices are enumerated once per engine start, and the framework
        // can tear its device objects down across sleep — so restart the engine on wake,
        // or gestures could go silently dead until a relaunch. Late arrivals (a Bluetooth
        // trackpad reconnecting after wake) are caught by the poll's device-list check.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        }

        // First launch: run the wizard (it drives the Accessibility grant + trackpad
        // setup). Afterwards, only re-prompt for Accessibility if it's been revoked.
        if !Preferences.shared.didOnboarding {
            onboarding.present()
        } else if !AXIsProcessTrusted() {
            AccessibilitySettings.prompt()
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
        setMiddleClickEnabled(!Preferences.shared.middleClickEnabled)
    }

    private func toggleAppSwitch() {
        let enabled = !Preferences.shared.appSwitchEnabled
        setAppSwitchEnabled(enabled)
        // Enabling swipe→switch is only useful once the three-finger swipe is freed
        // from Spaces. If the user turns it on (from the menu) while that conflict is
        // still live, guide them through the fix — silently no-op when already resolved.
        if enabled, TrackpadSettings.threeFingerHorizSwipeActive {
            onboarding.presentSwipeConflictHelp()
        }
    }

    /// Canonical gesture-pref setters (guarded against redundant work). Both the menu
    /// `toggle*` actions and the onboarding wizard route through these; the
    /// swipe-conflict helper is layered on top only in `toggleAppSwitch` (the menu
    /// path), since the wizard has its own trackpad step.
    private func setMiddleClickEnabled(_ on: Bool) {
        guard Preferences.shared.middleClickEnabled != on else { return }
        Preferences.shared.middleClickEnabled = on
        applyConfig()
        refresh()
    }

    private func setAppSwitchEnabled(_ on: Bool) {
        guard Preferences.shared.appSwitchEnabled != on else { return }
        Preferences.shared.appSwitchEnabled = on
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
        let enable = !LoginItem.isEnabled
        if enable, LoginItem.requiresApproval {
            // Registered but switched off / awaiting approval in System Settings —
            // register() can't flip that back; only the user can, so take them there.
            LoginItem.openSettings()
            refresh()
            return
        }
        do {
            try LoginItem.setEnabled(enable)
        } catch {
            NSLog("Trident: failed to update login item: \(error)")
            presentLoginItemError(error, enabling: enable)
        }
        refresh()
    }

    /// A failed toggle silently snapping back reads as a dead checkbox — say what
    /// happened and offer the Settings pane where it can always be fixed by hand.
    private func presentLoginItemError(_ error: Error, enabling: Bool) {
        let alert = NSAlert()
        alert.messageText = enabling
            ? "Couldn’t enable Launch at Login"
            : "Couldn’t disable Launch at Login"
        alert.informativeText = error.localizedDescription
            + "\n\nYou can also manage this under System Settings ▸ General ▸ Login Items & Extensions."
        alert.addButton(withTitle: "Open Login Items Settings")
        alert.addButton(withTitle: "Cancel")
        if let icon = NSImage(named: "AppIconImage") { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            LoginItem.openSettings()
        }
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

    // MARK: - Permission polling

    /// One poll tick: reconcile, then re-arm the timer at a cadence chosen by the result.
    /// (Only the timer path re-arms; direct `refresh()` calls from menu actions don't, so a
    /// burst of toggles can't perturb the poll cadence.)
    private func pollTick() {
        // A trackpad connected or dropped since the engine enumerated devices? Restart so
        // it reads the current set (a Magic Trackpad arriving after launch is otherwise
        // never registered; one that reconnected is registered on a dead handle).
        if engineRunning, engine.deviceListChanged() {
            restartEngine()
        }
        refresh(reprobe: true)
        schedulePermissionPoll(trusted: lastTrusted)
    }

    /// Stop and (via `refresh`) restart the engine so it re-enumerates devices — after
    /// wake, or when the trackpad set changed. No-op unless the engine is running.
    private func restartEngine() {
        guard engineRunning else { return }
        engine.stop()
        engineRunning = false
        refresh()
    }

    /// (Re)arm the one-shot permission timer. Fast (2 s) while NOT trusted: that path is
    /// cheap — `AXIsProcessTrusted()` reads false, so `AccessibilityMonitor.isTrusted()`
    /// short-circuits and the active-tap revoke probe never runs — and a snappy tick means
    /// the engine starts within ~2 s of the user granting Accessibility even when no
    /// onboarding window is open to catch it first. Relaxed (5 s) once trusted: every tick
    /// there pays for the live-revoke probe, and a revoke is rare and — with the tap
    /// gesture-scoped — no longer a freeze risk, so a few seconds' notice is harmless.
    private func schedulePermissionPoll(trusted: Bool) {
        permissionTimer?.invalidate()
        let interval: TimeInterval = trusted ? 5.0 : 2.0
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTick() }
        }
        // .common, not the default mode: a default-mode timer doesn't fire while a menu
        // is being tracked or a modal alert runs, which silently paused revoke detection
        // for as long as the status menu stayed open.
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    // MARK: - State

    /// Reconcile the engine and menu with current permission + preferences.
    ///
    /// `reprobe` re-checks the live Accessibility state via `AccessibilityMonitor` — the
    /// authoritative check (not bare AXIsProcessTrusted(), whose cache stays stale-true
    /// after a revoke), so the engine stops and the menu reflects reality when the user
    /// turns Accessibility off while we're running. Only the poll (and launch/onboarding
    /// completion) reprobe; menu actions use the cached state — a continuous slider drag
    /// fires this on every tick, and each probe is a WindowServer round-trip that has no
    /// business running per-tick when the poll re-checks within seconds anyway.
    private func refresh(reprobe: Bool = false) {
        let trusted = reprobe ? AccessibilityMonitor.isTrusted() : lastTrusted
        lastTrusted = trusted
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
