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
    private var lastLaunchAtLogin = false
    private var lastImDenied = false

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

        // A mid-gesture force-disable of our tap is the shape an Accessibility revoke
        // takes — reprobe right away so the engine stops and the menu reflects it now,
        // rather than on the next (deliberately slow) poll tick. Rare enough that the
        // main-thread probe inside refresh() is the right trade.
        engine.onTapForceDisabled = { [weak self] in
            DispatchQueue.main.async { self?.refresh(reprobe: true) }
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
            onOpenInputMonitoring: { InputMonitoring.openSettings() },
            // Menu opens reprobe — one WindowServer round-trip on a rare, explicit
            // user action — so the menu NEVER shows a stale permission state even
            // though the poll now ticks slowly.
            onMenuWillOpen: { [weak self] in self?.refresh(reprobe: true) },
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

        // Raw MultitouchSupport frames travel the IOHID path — on macOS 26.3+ they
        // never arrive until Input Monitoring is granted (a separate switch from
        // Accessibility). Asking once at launch prompts only if undetermined; a
        // later denial is surfaced by the menu's "Needs Input Monitoring" state.
        InputMonitoring.requestAccess()

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
        // trackpad reconnecting after wake) are caught by the 5 s device lane.
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
        // If a revoke happened inside the last ~30 s window (poll hasn't noticed),
        // a ⌘-up posted now is silently dropped — and unlike the poll path there's
        // no future start() to recover on. Nothing more can be done post-exit; the
        // user clears a stuck ⌘ with a physical press. Kill the timers and flag
        // first: a poll completion already queued on main could otherwise call
        // restartEngine() and re-register devices mid-teardown.
        engineRunning = false
        permissionTimer?.invalidate()
        deviceTimer?.invalidate()
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
            refresh(reprobe: true)
            return
        }
        do {
            try LoginItem.setEnabled(enable)
        } catch {
            NSLog("Trident: failed to update login item: \(error)")
            presentLoginItemError(error, enabling: enable)
        }
        // Reprobe: setEnabled just mutated the state — a cached refresh would
        // repaint the checkbox with the stale pre-toggle value.
        refresh(reprobe: true)
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
        NSApp.activate()
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
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Preferences.shared.hideMenuBarIcon = true
        menuBar.setIconVisible(false)
    }

    // MARK: - Permission polling

    /// Set while a poll's background checks are in flight, so an overlapping tick
    /// skips the work instead of queueing a second probe behind the first.
    private var pollInFlight = false
    /// Bumped by `reconcile` on every permission flip. A poll captures it at launch;
    /// if it moved before the completion lands, state changed under the probe and
    /// the sample is stale — discard and re-probe rather than overwrite fresher truth.
    private var reconcileEpoch = 0

    private var deviceTimer: Timer?
    private var devicePollInFlight = false

    /// One poll tick: gather the expensive state OFF the main thread, then reconcile.
    ///
    /// The old poll did three synchronous daemon round-trips on main every 2–5 s for
    /// the app's lifetime — a WindowServer handshake (`AccessibilityMonitor`), an
    /// IOKit device enumeration, and a service-management query (`LoginItem`) — and
    /// the `.common` timer fires during menu tracking and live slider drags, so each
    /// tick was a periodic mid-interaction micro-stall. Now split by cost: this tick
    /// keeps the daemon round-trips (rare events — a deliberate slow lane), while the
    /// cheap local IOKit enumeration rides `devicePollTick`'s 5 s lane. The probe is
    /// also the only re-grant detector, so it can't go away — it goes to a utility
    /// queue instead, and the result hops back to main to reconcile.
    /// (Re-arms come from this tick's tail plus reconcile's flip and failed-start
    /// paths — a burst of non-reprobe `refresh()` calls can't perturb the cadence.)
    private func pollTick() {
        guard !pollInFlight else {
            schedulePermissionPoll(trusted: lastTrusted)
            return
        }
        pollInFlight = true
        let epoch = reconcileEpoch
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Device-list changes are NOT probed here — they ride the faster
            // devicePollTick cadence (5 s) since a reconnected trackpad is the
            // common case, while this tick pays for the WindowServer probe.
            let trusted = AccessibilityMonitor.isTrusted()
            let loginEnabled = LoginItem.isEnabled
            let imDenied = InputMonitoring.isDenied   // TCC round-trip — off-main too
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pollInFlight = false
                // State flipped while we probed (an event-detected revoke, a wake
                // restart): the sample is stale — a pre-flip `trusted: true` landing
                // now would restart an engine reconcile just stopped. Discard and
                // re-probe against the new state instead.
                guard epoch == self.reconcileEpoch else {
                    self.pollTick()
                    return
                }
                // Reconcile FIRST: it owns the revoke transition (notePermissionLost
                // must run BEFORE the engine stops, and stop only happens on a fresh
                // trusted→untrusted edge). If restartEngine ran first, its stop→start
                // would cycle the synthesizer — clearing the press bookkeeping — before
                // the reconcile could record that a release may have been dropped.
                self.reconcile(trusted: trusted, launchAtLogin: loginEnabled,
                               imDenied: imDenied)
                self.schedulePermissionPoll(trusted: self.lastTrusted)
            }
        }
    }

    /// (Re)arm the one-shot DEVICE timer — the fast lane. A connected/reconnected
    /// trackpad is the COMMON lifecycle event (Bluetooth wake, an external Magic
    /// Trackpad arriving after launch), so it can't wait for the maintenance poll's
    /// 30 s cadence. Runs only while the engine runs: a stopped monitor's list is
    /// empty, so an untrusted/disabled app pays nothing at all.
    private func scheduleDevicePoll() {
        deviceTimer?.invalidate()
        let timer = Timer(timeInterval: 5.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.devicePollTick() }
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        deviceTimer = timer
    }

    /// One beat of the device lane: enumerate off-main, restart the engine on main
    /// if the trackpad set changed. `MTDeviceCreateList` is a local IOKit call —
    /// microseconds, no daemon round-trip — so it can afford the fast cadence.
    private func devicePollTick() {
        guard engineRunning else { return }          // stopped mid-flight — stay disarmed
        guard !devicePollInFlight else { scheduleDevicePoll(); return }
        devicePollInFlight = true
        let engine = self.engine            // @unchecked Sendable — safe to touch off-main
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let changed = engine.deviceListChanged()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.devicePollInFlight = false
                // A changed set means a reconnected trackpad is registered on a dead
                // handle — restart so it re-enumerates. engineRunning can only have
                // flipped via reconcile on this same thread, so the check is exact.
                if changed, self.engineRunning { self.restartEngine() }
                if self.engineRunning { self.scheduleDevicePoll() }
            }
        }
    }

    /// Stop and (via `reconcile`) restart the engine so it re-enumerates devices — after
    /// wake, or when the trackpad set changed. No-op unless the engine is running.
    private func restartEngine() {
        guard engineRunning else { return }
        // The poll can't have run while the Mac was asleep, so a revoke may have
        // landed in the gap — reprobe now. If it did, reconcile() IS the stop
        // path: it notes the lost permission (a release posted during teardown
        // can be silently dropped) before tearing down. Otherwise stop here and
        // let reconcile start fresh.
        let trusted = AccessibilityMonitor.isTrusted()
        if trusted {
            engine.stop()
            engineRunning = false
        }
        reconcile(trusted: trusted, launchAtLogin: LoginItem.isEnabled,
                  imDenied: InputMonitoring.isDenied)
    }

    /// (Re)arm the one-shot permission timer. Fast (2 s) while NOT trusted: that path is
    /// cheap — `AXIsProcessTrusted()` reads false, so `AccessibilityMonitor.isTrusted()`
    /// short-circuits and the active-tap revoke probe never runs — and a snappy tick means
    /// the engine starts within ~2 s of the user granting Accessibility even when no
    /// onboarding window is open to catch it first. Relaxed (30 s) once trusted: a revoke
    /// is a once-in-a-lifetime event, a mid-gesture revoke arrives instantly via the tap's
    /// force-disable callback, the menu reprobes on every open, and trackpad changes
    /// ride the 5 s device lane — so this tick only has to cover idle revokes and
    /// login-item drift, neither of which needs seconds-level latency.
    /// `tolerance` lets the OS coalesce the wakeups with other work — a 24/7 menu-bar
    /// app firing an exact-precision timer every few seconds measurably resists idle
    /// power management.
    private func schedulePermissionPoll(trusted: Bool) {
        permissionTimer?.invalidate()
        // Trusted ticks are SLOW: a revoke is a deliberate trip into System Settings —
        // once-in-the-app's-lifetime rare — and a mid-gesture revoke now arrives via
        // the tap's force-disable event instantly, so this tick only covers the idle
        // case (plus login-item drift). 30 s of a stale "running" state after an idle
        // revoke is a fine trade for one-sixth the wakeups.
        // Fast cadence isn't only for untrusted: trusted+enabled with a dead engine
        // is a HUNGRY state — a start that found zero devices (the wake path can
        // race the framework's post-sleep re-enumeration; a Bluetooth drop can
        // outrun re-announcement) retries at 2 s until the trackpad comes back.
        let hungry = Preferences.shared.isEnabled && !engineRunning
        let interval: TimeInterval = trusted && !hungry ? 30.0 : 2.0
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTick() }
        }
        timer.tolerance = interval * 0.2
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
    /// turns Accessibility off while we're running. Only one-shot callers (launch,
    /// onboarding completion) reprobe — the poll probes off-main and lands here via
    /// `reconcile`, a mid-gesture revoke lands via `onTapForceDisabled`, and menu
    /// actions use the cached state: a continuous slider drag fires this on every
    /// tick, and each probe is a WindowServer round-trip that has no business
    /// running per-tick.
    private func refresh(reprobe: Bool = false) {
        // Non-reprobe refreshes (slider drags, toggle flips — fired per tick) reuse
        // the stored values: even the TTL-cached reads would pay a daemon round-trip
        // every 0.5 s during a continuous drag. The poll and every reprobe path
        // (menuWillOpen, launch, onboarding) keep them fresh.
        reconcile(trusted: reprobe ? AccessibilityMonitor.isTrusted() : lastTrusted,
                  launchAtLogin: reprobe ? LoginItem.isEnabled : lastLaunchAtLogin,
                  imDenied: reprobe ? InputMonitoring.isDenied : lastImDenied)
    }

    /// The single funnel every permission observation goes through: start or stop the
    /// engine to match `trusted && isEnabled`, then repaint the menu. Called on main —
    /// directly by `refresh`, and as the completion half of each background poll.
    /// `imDenied` is a parameter (not a read) so the poll can probe it off-main —
    /// `InputMonitoring.isDenied` is a TCC daemon round-trip on a cache miss.
    private func reconcile(trusted: Bool, launchAtLogin: Bool, imDenied: Bool) {
        let wasTrusted = lastTrusted
        lastTrusted = trusted
        lastLaunchAtLogin = launchAtLogin
        lastImDenied = imDenied
        let shouldRun = trusted && Preferences.shared.isEnabled

        if shouldRun && !engineRunning {
            engineRunning = engine.start()
            if !engineRunning {
                // The start found zero devices — the wake path races the
                // framework's post-sleep re-enumeration, and a Bluetooth drop can
                // outrun re-announcement. Re-arm the poll NOW at the fast cadence
                // (schedulePermissionPoll reads the hungry state itself) — the
                // device lane can't cover this: it only runs while the engine
                // runs, and deviceListChanged() is false while stopped.
                schedulePermissionPoll(trusted: trusted)
            }
        } else if !shouldRun && engineRunning {
            // A fresh REVOKE (not a user pause): releases posted during teardown may be
            // silently dropped even though they report success, leaving ⌘ physically
            // down. Tell the synthesizer before stopping — the note lands on the serial
            // event queue ahead of stop()'s drain, so the next start's prepare() knows
            // to re-post the finishers.
            if wasTrusted, !trusted { engine.notePermissionLost() }
            engine.stop()
            engineRunning = false
        }

        // The device lane follows the engine's lifetime: trackpad changes only
        // matter while running, so it arms on start and dies on stop — an
        // untrusted/disabled app doesn't pay for it at all.
        if engineRunning, deviceTimer == nil { scheduleDevicePoll() }
        if !engineRunning { deviceTimer?.invalidate(); deviceTimer = nil }

        if wasTrusted != trusted {
            // A flip seen OUTSIDE the poll — the tap's force-disable event, the wake
            // reprobe in restartEngine, onboarding — must re-arm the timer at the new
            // cadence now: an event-detected revoke would otherwise leave the stale
            // 30 s trusted timer armed, and a quick re-grant would wait ~36 s to be
            // noticed. (Poll-sourced flips arm again at pollTick's tail — harmless:
            // each arm invalidates the previous.) The epoch bump tells an in-flight
            // poll its sample went stale under it, so a pre-flip `trusted` can't land
            // after us and resurrect a just-stopped engine.
            reconcileEpoch += 1
            schedulePermissionPoll(trusted: trusted)
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
            launchAtLogin: launchAtLogin,
            inputMonitoringDenied: imDenied
        )
    }
}
