import SwiftUI

/// Menu-bar accessory app. All behavior lives in `AppDelegate`; the `Settings`
/// scene exists only because `App` requires a body — the app shows no windows.
@main
struct TridentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
