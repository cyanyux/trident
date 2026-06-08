import AppKit
import ApplicationServices

/// Single source of truth for the Accessibility permission flow — the system trust
/// prompt and the Settings deep-link — shared by the menu, the first-run wizard, and
/// the launch-time / dismiss fallbacks. Keeps the URL and the prompt options in one
/// place so the call sites can't drift apart.
enum AccessibilitySettings {

    /// Ask macOS to show its "allow Accessibility" prompt. No-op when already
    /// trusted; the prompt itself offers a button into the Settings pane.
    static func prompt() {
        guard !AXIsProcessTrusted() else { return }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Open System Settings ▸ Privacy & Security ▸ Accessibility directly.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
