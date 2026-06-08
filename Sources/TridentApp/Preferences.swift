import Foundation
import TridentCore

/// Bounds and recommended presets for the swipe-distance slider, in millimetres of
/// real finger travel (so the feel is identical on any size of trackpad). The default
/// lives in `TridentCore.GestureTuning` so the engine and the UI share one source of
/// truth; only the UI-only slider bounds live here.
enum SwipeTuning {
    static let minMM: Float = 1.5
    static let maxMM: Float = 20
    static let defaultMM = GestureTuning.swipeDistanceDefaultMM
}

/// Bounds and recommended presets for the palm-rejection slider, in millimetres of
/// ignored edge band. The contact-size cap is derived from the band so a single
/// slider captures the whole "strength". The default and the derivation live in
/// `TridentCore.GestureTuning`, shared with the engine.
enum PalmTuning {
    static let minMM: Float = 0
    static let maxMM = GestureTuning.palmEdgeBandMaxMM
    static let defaultMM = GestureTuning.palmEdgeBandDefaultMM
    /// Contact-size cap: a wider ignored band pairs with a stricter size cutoff —
    /// 2.0 at 0 mm down to 1.2 at the maximum band.
    static func maxSize(forEdgeBandMM mm: Float) -> Float {
        GestureTuning.palmMaxSize(forEdgeBandMM: mm)
    }
}

/// `UserDefaults`-backed preferences. `@unchecked Sendable` is sound because the
/// only stored state is `UserDefaults`, which is itself thread-safe.
final class Preferences: @unchecked Sendable {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let enabled = "enabled"
        static let swipeDistanceMM = "swipeDistanceMM"
        static let middleClickEnabled = "middleClickEnabled"
        static let appSwitchEnabled = "appSwitchEnabled"
        static let hapticAppSwitch = "hapticAppSwitch"
        static let palmEdgeBandMM = "palmEdgeBandMM"
        static let hideMenuBarIcon = "hideMenuBarIcon"
        static let didFirstRunSetup = "didFirstRunSetup"
        static let didOnboarding = "didOnboarding"
    }

    private init() {
        defaults.register(defaults: [
            Keys.enabled: true,
            Keys.swipeDistanceMM: SwipeTuning.defaultMM,
            Keys.middleClickEnabled: true,
            Keys.appSwitchEnabled: true,
            Keys.hapticAppSwitch: false,
            Keys.palmEdgeBandMM: PalmTuning.defaultMM,
        ])
    }

    /// Master switch — pauses all gesture remapping.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    /// Millimetres of horizontal travel required per app-switch step.
    var swipeDistanceMM: Float {
        get { defaults.float(forKey: Keys.swipeDistanceMM) }
        set { defaults.set(newValue, forKey: Keys.swipeDistanceMM) }
    }

    /// Three-finger tap → middle click.
    var middleClickEnabled: Bool {
        get { defaults.bool(forKey: Keys.middleClickEnabled) }
        set { defaults.set(newValue, forKey: Keys.middleClickEnabled) }
    }

    /// Three-finger swipe → app switch.
    var appSwitchEnabled: Bool {
        get { defaults.bool(forKey: Keys.appSwitchEnabled) }
        set { defaults.set(newValue, forKey: Keys.appSwitchEnabled) }
    }

    /// Haptic tap on each app-switch step.
    var hapticAppSwitch: Bool {
        get { defaults.bool(forKey: Keys.hapticAppSwitch) }
        set { defaults.set(newValue, forKey: Keys.hapticAppSwitch) }
    }

    /// Millimetres in from each trackpad edge ignored at gesture start.
    var palmEdgeBandMM: Float {
        get { defaults.float(forKey: Keys.palmEdgeBandMM) }
        set { defaults.set(newValue, forKey: Keys.palmEdgeBandMM) }
    }

    /// Hide the menu bar icon. Trident keeps running; reopening the app restores it.
    var hideMenuBarIcon: Bool {
        get { defaults.bool(forKey: Keys.hideMenuBarIcon) }
        set { defaults.set(newValue, forKey: Keys.hideMenuBarIcon) }
    }

    /// Whether the one-time first-launch setup (e.g. enabling Launch at Login by
    /// default) has already run. The user's later choices then stick.
    var didFirstRunSetup: Bool {
        get { defaults.bool(forKey: Keys.didFirstRunSetup) }
        set { defaults.set(newValue, forKey: Keys.didFirstRunSetup) }
    }

    /// Whether the first-run onboarding wizard has been shown. Reset by the user
    /// reopening it from the menu's Setup Assistant.
    var didOnboarding: Bool {
        get { defaults.bool(forKey: Keys.didOnboarding) }
        set { defaults.set(newValue, forKey: Keys.didOnboarding) }
    }
}
