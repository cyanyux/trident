import SwiftUI

/// State + navigation for the first-run wizard. `@MainActor` because it drives UI
/// and is poked by the controller's poll timer on the main thread.
@MainActor
final class OnboardingModel: ObservableObject {

    /// Live-detected, refreshed by `OnboardingController`'s poll timer.
    @Published var accessibilityGranted = false
    @Published var swipeConflictResolved = false

    /// User choices. Each change is pushed straight into the engine via the closures
    /// so toggling here behaves exactly like the menu toggles.
    @Published var middleClickEnabled = true {
        didSet { onSetMiddleClick?(middleClickEnabled) }
    }
    @Published var appSwitchEnabled = true {
        didSet {
            onSetAppSwitch?(appSwitchEnabled)
            // Turning swipe off drops the trackpad step; re-clamp so an index past the
            // shrunken list can't strand navigation (Back would land on the same step)
            // or leave the page dots with no active dot.
            stepIndex = min(stepIndex, steps.count - 1)
        }
    }

    @Published var stepIndex = 0

    var onSetMiddleClick: ((Bool) -> Void)?
    var onSetAppSwitch: ((Bool) -> Void)?
    var onOpenAccessibility: (() -> Void)?
    var onOpenTrackpad: (() -> Void)?
    var onFinish: (() -> Void)?

    enum Step: Hashable { case welcome, accessibility, gestures, trackpad, done }

    /// The Trackpad step exists only to free the swipe gesture, so it's dropped when
    /// the user opts out of swipe→switch.
    var steps: [Step] {
        var s: [Step] = [.welcome, .accessibility, .gestures]
        if appSwitchEnabled { s.append(.trackpad) }
        s.append(.done)
        return s
    }

    var currentStep: Step { steps[min(stepIndex, steps.count - 1)] }
    var isFirst: Bool { stepIndex == 0 }
    var isLast: Bool { currentStep == .done }

    /// Accessibility is mandatory — the engine can't post events without it, so
    /// forward navigation is blocked on that step until it's granted. The trackpad
    /// conflict is only *guided* (swipe still half-works without the fix), so it is
    /// deliberately never gated here.
    var canProceed: Bool {
        !(currentStep == .accessibility && !accessibilityGranted)
    }

    func next() {
        guard canProceed else { return }
        if isLast { onFinish?(); return }
        stepIndex = min(stepIndex + 1, steps.count - 1)
    }

    func back() { stepIndex = max(stepIndex - 1, 0) }
}

/// The first-run setup wizard.
///
/// Layout follows the native pattern (macOS Setup Assistant, Raycast, CleanShot X):
/// a **pinned header** — one hero glyph + title + subtitle in a fixed slot at the
/// top — with only the body swapping per step, so the title never jumps as you
/// navigate. Per Apple's Liquid Glass guidance the **content layer stays clean**
/// (no glass, no decorative backgrounds; hierarchy from layout + type), and glass
/// lives only on the **functional layer**: the footer nav, grouped in a
/// `GlassEffectContainer`. The window picks up the system's glass chrome for free.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // CONTENT LAYER — clean, no glass. Anchored to the top so the hero +
            // title sit at the same height on every step; the body flows beneath.
            stepContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 40)
                .animation(.snappy(duration: 0.22), value: model.stepIndex)
            Spacer(minLength: 20)
            // FUNCTIONAL LAYER — the only Liquid Glass in the view.
            footer
        }
        .frame(width: 560, height: 470)
    }

    // MARK: - Steps

    @ViewBuilder private var stepContent: some View {
        switch model.currentStep {
        case .welcome: welcome
        case .accessibility: accessibility
        case .gestures: gestures
        case .trackpad: trackpad
        case .done: done
        }
    }

    private var welcome: some View {
        step(
            hero: {
                Image("AppIconImage")
                    .resizable().frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            },
            title: "Welcome to Trident",
            subtitle: "Trackpad gestures, remapped."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                featureRow(symbol: "hand.tap.fill", tint: .blue,
                           title: "Tap → Middle Click",
                           detail: "A three-finger tap — open links in a new tab, close tabs, or paste in Terminal.")
                featureRow(symbol: "hand.draw.fill", tint: .indigo,
                           title: "Swipe → Switch App",
                           detail: "A three-finger swipe — flick to your last app, or hold to scrub through more.")
            }
        }
    }

    private var accessibility: some View {
        step(
            hero: { heroSymbol("accessibility", .blue) },
            title: "Grant Accessibility",
            subtitle: "Trident needs Accessibility permission to read the trackpad and post your remapped clicks and keystrokes."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // Same action+result composition as the trackpad step: open the external
                // pane on the left, live confirmation pinned right. "Granted" (not
                // "Accessibility granted") since the button already names the permission.
                HStack(spacing: 16) {
                    Button("Open Accessibility Settings…") { model.onOpenAccessibility?() }
                        .controlSize(.large)
                    Spacer(minLength: 12)
                    StatusRow(ok: model.accessibilityGranted,
                              okText: "Granted",
                              pendingText: "Not granted yet")
                }
                if !model.accessibilityGranted {
                    Text("Trident can't continue until this is on. Enable **Trident** in the list, then return here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var gestures: some View {
        step(
            hero: { heroSymbol("switch.2", .blue) },
            title: "Choose your gestures",
            subtitle: "Turn on the mappings you want. You can change these any time from the menu bar."
        ) {
            VStack(spacing: 0) {
                toggleRow(
                    isOn: $model.middleClickEnabled,
                    title: "Tap → Middle Click",
                    detail: "Three-finger tap."
                )
                Divider()
                toggleRow(
                    isOn: $model.appSwitchEnabled,
                    title: "Swipe → Switch App",
                    detail: "Three-finger horizontal swipe."
                )
            }
        }
    }

    private var trackpad: some View {
        step(
            hero: { heroSymbol("hand.draw.fill", .indigo) },
            title: "Free the three-finger swipe",
            subtitle: "macOS already uses a three-finger swipe to switch Spaces — the same gesture Trident needs. Reassign it below:"
        ) {
            // Two clean zones: the recipe panel, then an action+result row. Pressing the
            // button is what flips the live status, so they belong on one line — action
            // left, confirmation pinned right — rather than floating as loose stacked items.
            VStack(alignment: .leading, spacing: 20) {
                TrackpadInstruction()
                HStack(spacing: 16) {
                    Button("Open Trackpad Settings…") { model.onOpenTrackpad?() }
                        .controlSize(.large)
                    Spacer(minLength: 12)
                    StatusRow(ok: model.swipeConflictResolved,
                              okText: "Three-finger swipe is free",
                              pendingText: "Still set to three fingers")
                }
            }
        }
    }

    private var done: some View {
        step(
            hero: { heroSymbol("checkmark.seal.fill", .green) },
            title: "You're all set",
            subtitle: "Trident is running in the background."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if model.middleClickEnabled {
                    summaryRow("Three-finger tap performs a middle click.")
                }
                if model.appSwitchEnabled {
                    summaryRow("Three-finger swipe switches apps.")
                }
                summaryRow("Find settings any time in the menu bar (the trident icon).")
                summaryRow("Trident updates itself automatically.")
            }
        }
    }

    // MARK: - Step scaffold (pinned header + body)

    /// Hero glyph (fixed-height slot) + title + subtitle, then the step's body.
    /// The fixed hero slot keeps the title at a constant height across steps.
    private func step<Hero: View, Body: View>(
        @ViewBuilder hero: () -> Hero,
        title: String,
        subtitle: String,
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 18) {
                hero().frame(height: 60, alignment: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.largeTitle.bold())
                    Text(subtitle).font(.title3).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            body()
        }
    }

    private func heroSymbol(_ name: String, _ tint: Color) -> some View {
        HeroChip(symbol: name, tint: tint)
    }

    // MARK: - Footer (functional layer — Liquid Glass)

    private var footer: some View {
        GlassEffectContainer(spacing: 12) {
            HStack {
                Button("Back") { model.back() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .opacity(model.isFirst ? 0 : 1)
                    .disabled(model.isFirst)
                Spacer()
                PageDots(count: model.steps.count, index: model.stepIndex)
                Spacer()
                Button(model.isLast ? "Done" : "Continue") { model.next() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canProceed)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    // MARK: - Content building blocks (no glass)

    private func featureRow(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func toggleRow(isOn: Binding<Bool>, title: String, detail: String) -> some View {
        // Custom row (text + Spacer + label-less switch) instead of a plain Toggle, so
        // every switch pins to the trailing edge and they line up regardless of label
        // width. A bare Toggle hugs its label and leaves the switches misaligned.
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func summaryRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text)
            Spacer(minLength: 0)
        }
    }
}

/// Shown when the user enables Swipe → Switch App from the menu *after* onboarding
/// (so they never saw the wizard's trackpad step) and the three-finger swipe is
/// still bound to Spaces. Only presented when the conflict is actually present.
struct SwipeConflictHelpView: View {
    @ObservedObject var model: OnboardingModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HeroChip(symbol: "hand.draw.fill", tint: .indigo)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Free the three-finger swipe").font(.largeTitle.bold())
                    Text("You turned on Swipe → Switch App. macOS uses that same three-finger swipe to switch Spaces — reassign it below so they don't collide:")
                        .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                TrackpadInstruction()
                StatusRow(ok: model.swipeConflictResolved,
                          okText: "Three-finger swipe is free",
                          pendingText: "Still set to three fingers")
            }
            GlassEffectContainer(spacing: 12) {
                HStack {
                    Button("Open Trackpad Settings…") { model.onOpenTrackpad?() }
                        .buttonStyle(.glass).controlSize(.large)
                    Spacer()
                    Button(model.swipeConflictResolved ? "Done" : "Later") { onClose() }
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 22)
        .frame(width: 520)
    }
}

// MARK: - Shared content components (no glass — these live on the content layer)

/// Hero glyph in a tinted rounded-square chip — the same visual language as the
/// welcome step's feature rows (and System Settings' section icons), so every step
/// header reads as part of one family instead of a bare floating symbol.
struct HeroChip: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 28, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 60, height: 60)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A ✓/pending status line. State is conveyed by the symbol + color, not a background.
struct StatusRow: View {
    let ok: Bool
    let okText: String
    let pendingText: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.secondary)
                .symbolEffect(.bounce, value: ok)
            Text(ok ? okText : pendingText)
                .foregroundStyle(ok ? Color.primary : Color.secondary)
        }
        .font(.headline)
    }
}

/// The trackpad fix, as a short breadcrumb of where to go plus one emphasized
/// sentence of what to change — instead of cramming the long setting name into a
/// giant chip. Subtle content fill only (no glass — glass is the functional layer).
struct TrackpadInstruction: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A gear eyebrow + breadcrumb tells the user this path lives *in System
            // Settings*; the whole recipe sits in one bordered panel so it reads as a
            // single "do this here" unit rather than chips floating on the page.
            HStack(spacing: 7) {
                Image(systemName: "gearshape.fill").font(.caption).foregroundStyle(.secondary)
                crumb("Trackpad")
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                crumb("More Gestures")
            }
            Text("Set **“Swipe between full-screen apps”** to **Four Fingers** (or Off).")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    private func crumb(_ text: String) -> some View {
        Text(text).font(.callout.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }
}

/// Simple progress dots for the wizard footer.
struct PageDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
