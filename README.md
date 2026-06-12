# Trident

A macOS menu-bar utility that remaps trackpad gestures:

- **Three-finger tap → middle click**
- **Three-finger horizontal swipe → app switch** — right = forward (`⌘Tab`), left = backward (`⌘⇧Tab`)

A quick swipe switches to the adjacent app instantly; leaving your fingers resting
keeps the app-switcher HUD up so you can scrub through several apps, then lift to
commit. Trident lives in the menu bar — no Dock icon, no window to manage.

## Install

1. Download the latest **Trident.dmg** from the
   [Releases page](https://github.com/cyanyux/trident/releases/latest).
2. Open it and drag **Trident** onto the **Applications** folder.
3. Launch Trident from Applications. The first time, macOS blocks it with
   *"Apple could not verify 'Trident' is free of malware."* — Trident is signed but
   not notarized by Apple (it's a free, open-source tool). To allow it:
   open **System Settings → Privacy & Security**, scroll down to the Trident notice,
   click **Open Anyway**, and confirm. You only do this once.
4. Grant **Accessibility** when prompted (or in
   **System Settings → Privacy & Security → Accessibility**) — Trident needs it to
   read the trackpad and post the remapped events.
5. On first run Trident walks you through one trackpad setting it needs you to
   change, because macOS uses a **three-finger swipe to switch Spaces** by default
   (see [Recommended System Settings](#recommended-system-settings)).

**Updates are automatic.** Trident checks for new versions in the background and
offers to install them; you can also trigger a check from the menu bar via
**Check for Updates…**. Because every release keeps the same signing identity, your
Accessibility grant carries across updates — no re-granting.

## Requirements

- macOS 26 (Tahoe) or later
- A built-in or Magic Trackpad
- Accessibility permission (granted on first launch)

## Recommended System Settings

macOS itself uses a **three-finger horizontal swipe** to switch Spaces /
full-screen apps by default, which collides with Trident's app-switch swipe.
Trident's first-run assistant detects this and walks you through the fix; to do it
manually, set **System Settings → Trackpad → More Gestures → Swipe between
full-screen applications** to a different finger count (e.g. four). Otherwise a
three-finger swipe triggers both actions at once.

## Support

Trident is free and open source. If it makes your trackpad nicer to live with,
you can [buy me a coffee on Ko-fi](https://ko-fi.com/cyanyux) ☕

---

# For developers

Everything below is for people who want to build Trident themselves or hack on
the code.

## Build

```sh
brew install xcodegen        # one-time
./scripts/setup-signing.sh   # one-time — see "Signing" below
./build.sh                   # Release (or: ./build.sh Debug)
```

Requires Xcode with the macOS 26 SDK (Swift 6). The build links the private
`MultitouchSupport` framework from `/System/Library/PrivateFrameworks` to read raw
trackpad touches. The app is **not** sandboxed (required for trackpad access and
event synthesis).

### Signing

Trident needs Accessibility permission, and macOS ties that grant to the app's
code signature. A plain ad-hoc signature changes identity on every build, so the
grant would be lost each rebuild. `scripts/setup-signing.sh` creates a stable
self-signed **"Trident Dev"** certificate in your login keychain; `build.sh` then
signs with it, giving a fixed code requirement so **you grant Accessibility once
and it survives rebuilds**. Without the cert, `build.sh` falls back to ad-hoc
signing (works, but you'll re-grant after each build). To undo: delete the
"Trident Dev" certificate in Keychain Access.

## Design notes: stray-click suppression

When three fingers don't land or lift perfectly together, the trackpad can briefly
see one or two fingers — which, with *Tap to click* enabled, macOS would turn into a
stray left or two-finger **secondary (right) click** next to Trident's middle click.
Trident installs a tightly-scoped event tap that suppresses native left/right mouse
clicks **only while a three-finger gesture is active** (and for ~300 ms after), so
those leaks can't fire. Normal clicking is untouched.

## Releasing & auto-update (maintainers)

Trident updates itself with [Sparkle](https://sparkle-project.org). Releases are
signed with a stable self-signed identity (so Accessibility persists) and an EdDSA
key (so Sparkle trusts the update); they are **not** Apple-notarized, which is why
new users see the one-time Gatekeeper step above. The feed (`appcast.xml`) and the
downloads are hosted on this public repo's Releases.

**One-time setup:**

```sh
brew install create-dmg           # designed installer DMG (background, drag-to-Applications layout)
./scripts/setup-signing.sh        # stable "Trident Dev" code-sign identity
./scripts/setup-sparkle-keys.sh   # EdDSA update key → private in keychain, public in Info.plist
.sparkle/bin/generate_keys -x sparkle_private_key.pem   # back up the private key somewhere safe (NOT git)
gh auth login                     # GitHub CLI, if not already
```

The repo must be **public** so Sparkle can fetch `appcast.xml` and the assets
without authentication.

**Cut a release:**

```sh
./scripts/release.sh 1.1          # marketing version; build number auto-increments
```

That builds + signs (including the embedded Sparkle helpers), packages a **DMG**
(for new installs) and a **ZIP** (what Sparkle downloads to self-update), EdDSA-signs
the update, regenerates `appcast.xml`, commits the version bump + feed, pushes a
`v1.1` tag, and creates the GitHub Release with both assets. Existing installs pick
up the update within a day (or instantly via **Check for Updates…**).

> ⚠️ Losing the Sparkle private key means existing installs can no longer verify
> your updates. Keep the backed-up `.pem` safe.

## Project layout

```
Sources/TridentCore/   UI-free gesture pipeline (static library)
  MultitouchSupport.swift   private-framework C bindings
  TouchModels.swift         MTTouch / MTPoint / MTVector layout
  DeviceMonitor.swift       device lifecycle + callback guard
  GestureRecognizer.swift   tap + swipe state machine (hot path)
  GestureEventSuppressor.swift  gesture-scoped event tap (stray-click guard, cursor freeze)
  ActionSynthesizer.swift   middle click + held-⌘ app switch
  TridentEngine.swift       wires it together
Sources/TridentApp/    menu-bar accessory app (menu, onboarding, login item)
  Updater.swift             Sparkle auto-update wrapper
Tests/TridentCoreTests/ gesture-recognizer unit tests
project.yml            XcodeGen project spec
build.sh               generate + build (+ stable re-sign incl. Sparkle)
scripts/
  setup-signing.sh          stable code-sign identity (Accessibility persistence)
  setup-sparkle-keys.sh     EdDSA update-signing key + public key into Info.plist
  release.sh                build → package → sign → appcast → GitHub Release
  lib-sparkle.sh            fetches Sparkle's CLI tools on demand
appcast.xml            Sparkle update feed (served from the public repo)
```

## License

[MIT](LICENSE)

## Acknowledgments

- [MiddleDrag](https://github.com/NullPointerDepressiveDisorder/MiddleDrag) — a
  shipping trackpad→middle-click app whose `MultitouchSupport` plumbing served as
  a valuable reference for Trident's touch-reading layer.
- [Sparkle](https://sparkle-project.org) — the auto-update framework.
