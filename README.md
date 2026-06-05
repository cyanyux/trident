# Trident

A macOS 26 menu-bar utility that remaps trackpad gestures:

- **Three-finger tap → middle click**
- **Three-finger horizontal swipe → app switch** — right = forward (`⌘Tab`), left = backward (`⌘⇧Tab`)

A quick swipe switches to the adjacent app instantly; leaving your fingers resting
keeps the app-switcher HUD up so you can scrub through several apps, then lift to
commit. Background accessory app — no Dock icon, no main window.

## Build

```sh
brew install xcodegen        # one-time
./scripts/setup-signing.sh   # one-time — see "Signing" below
./build.sh                   # Release (or: ./build.sh Debug)
```

The build links the private `MultitouchSupport` framework from
`/System/Library/PrivateFrameworks`. The app is **not** sandboxed (required for
trackpad access and event synthesis).

### Signing

Trident needs Accessibility permission, and macOS ties that grant to the app's
code signature. A plain ad-hoc signature changes identity on every build, so the
grant would be lost each rebuild. `scripts/setup-signing.sh` creates a stable
self-signed **"Trident Dev"** certificate in your login keychain; `build.sh` then
signs with it, giving a fixed code requirement so **you grant Accessibility once
and it survives rebuilds**. Without the cert, `build.sh` falls back to ad-hoc
signing (works, but you'll re-grant after each build). To undo: delete the
"Trident Dev" certificate in Keychain Access.

## Permissions

Launch `Trident.app`, then grant **Accessibility** in
**System Settings → Privacy & Security → Accessibility**. Trident prompts on first
launch and starts automatically once the permission is granted.

## Robustness: stray clicks

When three fingers don't land or lift perfectly together, the trackpad can briefly
see one or two fingers — which, with *Tap to click* enabled, macOS would turn into a
stray left or two-finger **secondary (right) click** next to Trident's middle click.
Trident installs a tightly-scoped event tap that suppresses native left/right mouse
clicks **only while a three-finger gesture is active** (and for ~300 ms after), so
those leaks can't fire. Normal clicking is untouched.

## Recommended System Settings

The OS gestures below aren't mouse clicks, so the leak-guard above doesn't cover
them. To avoid a redundant native action you may want to free up the two gestures
Trident uses (**System Settings → Trackpad**):

- **Point & Click → Look up & data detectors:** set to *Force Click with one finger*
  (or off), so a three-finger **tap** isn't also a Look Up.
- **More Gestures → Swipe between full-screen apps / pages:** set to a finger count
  other than three (e.g. four), so a three-finger **horizontal swipe** isn't also a
  page / full-screen swipe.

Both are optional — Trident works without them; you may just see a redundant native
action.

## Project layout

```
Sources/TridentCore/   UI-free gesture pipeline (static library)
  MultitouchSupport.swift   private-framework C bindings
  TouchModels.swift         MTTouch / MTPoint / MTVector layout
  DeviceMonitor.swift       device lifecycle + callback guard
  GestureRecognizer.swift   tap + swipe state machine (hot path)
  ActionSynthesizer.swift   middle click + held-⌘ app switch
  TridentEngine.swift       wires it together
Sources/TridentApp/    menu-bar accessory app
Tests/TridentCoreTests/ gesture-recognizer unit tests
project.yml            XcodeGen project spec
build.sh               generate + build
```
