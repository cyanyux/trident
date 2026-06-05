import AppKit

/// Owns the `NSStatusItem` and its menu. Pure UI — it calls back into the
/// `AppDelegate` for every action and is told what to display via `update(...)`.
///
/// The interactive controls live in a single embedded view (`panel`) rather than as
/// plain menu items. Controls inside a menu-item view handle their own clicks, so
/// the menu stays open while you flip toggles and drag sliders — you adjust several
/// things in one pass instead of reopening after each change.
@MainActor
final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    // Callbacks into the app.
    private let onToggleEnabled: () -> Void
    private let onToggleMiddleClick: () -> Void
    private let onToggleAppSwitch: () -> Void
    private let onSetSwipeDistance: (Float) -> Void
    private let onSetPalmEdgeBand: (Float) -> Void
    private let onResetSwipe: () -> Void
    private let onResetPalm: () -> Void
    private let onToggleHaptics: () -> Void
    private let onToggleLaunchAtLogin: () -> Void
    private let onHideMenuBarIcon: () -> Void
    private let onOpenAccessibility: () -> Void
    private let onQuit: () -> Void

    // Plain menu items (info / navigation — fine for these to dismiss the menu).
    private let statusLine = NSMenuItem()
    private let accessibilityItem = NSMenuItem()

    // Controls inside the embedded panel, kept for state updates.
    private let panel = NSStackView()
    private let enabledButton = NSButton()
    private let middleClickButton = NSButton()
    private let appSwitchButton = NSButton()
    private let hapticButton = NSButton()
    private let launchButton = NSButton()
    private let swipeSlider = NSSlider()
    private let palmSlider = NSSlider()
    private let swipeValueLabel = NSTextField(labelWithString: "")
    private let palmValueLabel = NSTextField(labelWithString: "")
    private var swipeResetButton: NSButton!
    private var palmResetButton: NSButton!

    private let panelWidth: CGFloat = 300
    private var contentWidth: CGFloat { panelWidth - 28 }

    init(
        onToggleEnabled: @escaping () -> Void,
        onToggleMiddleClick: @escaping () -> Void,
        onToggleAppSwitch: @escaping () -> Void,
        onSetSwipeDistance: @escaping (Float) -> Void,
        onSetPalmEdgeBand: @escaping (Float) -> Void,
        onResetSwipe: @escaping () -> Void,
        onResetPalm: @escaping () -> Void,
        onToggleHaptics: @escaping () -> Void,
        onToggleLaunchAtLogin: @escaping () -> Void,
        onHideMenuBarIcon: @escaping () -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onToggleEnabled = onToggleEnabled
        self.onToggleMiddleClick = onToggleMiddleClick
        self.onToggleAppSwitch = onToggleAppSwitch
        self.onSetSwipeDistance = onSetSwipeDistance
        self.onSetPalmEdgeBand = onSetPalmEdgeBand
        self.onResetSwipe = onResetSwipe
        self.onResetPalm = onResetPalm
        self.onToggleHaptics = onToggleHaptics
        self.onToggleLaunchAtLogin = onToggleLaunchAtLogin
        self.onHideMenuBarIcon = onHideMenuBarIcon
        self.onOpenAccessibility = onOpenAccessibility
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
    }

    private func buildMenu() {
        if let button = statusItem.button {
            // Monochrome trident matching the app icon. A template image is tinted by
            // AppKit to suit the menu bar's light/dark appearance automatically.
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            icon?.accessibilityDescription = "Trident"
            button.image = icon
        }

        menu.autoenablesItems = false

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        buildPanel()
        let panelItem = NSMenuItem()
        panelItem.view = panel
        menu.addItem(panelItem)

        menu.addItem(.separator())

        accessibilityItem.target = self
        accessibilityItem.action = #selector(openAccessibility)
        menu.addItem(accessibilityItem)

        menu.addItem(.separator())

        let hide = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideMenuBarIcon), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        let quit = NSMenuItem(title: "Quit Trident", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func buildPanel() {
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 8
        panel.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true

        configure(enabledButton, title: "Enable Trident", action: #selector(toggleEnabled))
        enabledButton.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        panel.addArrangedSubview(enabledButton)

        configure(middleClickButton, title: "Tap → Middle Click", action: #selector(toggleMiddleClick))
        panel.addArrangedSubview(indent(middleClickButton))
        configure(appSwitchButton, title: "Swipe → Switch App", action: #selector(toggleAppSwitch))
        panel.addArrangedSubview(indent(appSwitchButton))

        panel.addArrangedSubview(separatorLine())
        swipeResetButton = addSliderSection(title: "Swipe sensitivity", slider: swipeSlider, value: swipeValueLabel,
                         min: SwipeTuning.minMM, max: SwipeTuning.maxMM, defaultMM: SwipeTuning.defaultMM,
                         action: #selector(swipeChanged(_:)), resetAction: #selector(resetSwipeTapped))

        panel.addArrangedSubview(separatorLine())
        palmResetButton = addSliderSection(title: "Palm rejection (edge band)", slider: palmSlider, value: palmValueLabel,
                         min: PalmTuning.minMM, max: PalmTuning.maxMM, defaultMM: PalmTuning.defaultMM,
                         action: #selector(palmChanged(_:)), resetAction: #selector(resetPalmTapped))

        panel.addArrangedSubview(separatorLine())
        configure(hapticButton, title: "Haptic Feedback", action: #selector(toggleHaptics))
        panel.addArrangedSubview(hapticButton)
        let hapticNote = makeLabel("When switching apps", secondary: true)
        panel.addArrangedSubview(indent(hapticNote))
        panel.setCustomSpacing(2, after: hapticButton)

        panel.addArrangedSubview(separatorLine())
        configure(launchButton, title: "Launch at Login", action: #selector(toggleLaunchAtLogin))
        panel.addArrangedSubview(launchButton)

        // Resolve Auto Layout so the menu has a concrete size to lay the view out at.
        panel.layoutSubtreeIfNeeded()
        panel.frame = NSRect(origin: .zero, size: panel.fittingSize)
    }

    // MARK: - Panel builders

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.setButtonType(.switch)          // checkbox
        button.title = title
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Wrap a control with a leading inset so it reads as nested under its heading.
    private func indent(_ view: NSView, by inset: CGFloat = 18) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: inset).isActive = true
        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.spacing = 0
        return row
    }

    private func separatorLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return box
    }

    private func makeLabel(_ text: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        if secondary {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }
        return label
    }

    @discardableResult
    private func addSliderSection(title: String, slider: NSSlider, value: NSTextField,
                                  min: Float, max: Float, defaultMM: Float,
                                  action: Selector, resetAction: Selector) -> NSButton {
        let titleLabel = makeLabel(title)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        value.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [titleLabel, value])
        top.orientation = .horizontal
        top.distribution = .fill
        top.translatesAutoresizingMaskIntoConstraints = false
        top.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        slider.minValue = Double(min)
        slider.maxValue = Double(max)
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        // Default note on the left, this section's own reset button on the right.
        let defaultLabel = makeLabel("Default: \(fmtShort(defaultMM)) mm", secondary: true)
        defaultLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let resetButton = NSButton(title: "Reset to Default", target: self, action: resetAction)
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        resetButton.setContentHuggingPriority(.required, for: .horizontal)
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        let bottom = NSStackView(views: [defaultLabel, resetButton])
        bottom.orientation = .horizontal
        bottom.distribution = .fill
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        panel.addArrangedSubview(top)
        panel.addArrangedSubview(slider)
        panel.addArrangedSubview(bottom)
        panel.setCustomSpacing(6, after: top)
        panel.setCustomSpacing(4, after: slider)
        return resetButton
    }

    private func fmtShort(_ mm: Float) -> String {
        mm == mm.rounded() ? String(Int(mm)) : String(format: "%.1f", mm)
    }

    private func fmtValue(_ mm: Float) -> String {
        String(format: "%.1f mm", mm)
    }

    /// Set a slider only when it actually differs, so a live drag (which round-trips
    /// through `update`) isn't fought by a redundant programmatic set.
    private func setSlider(_ slider: NSSlider, to value: Float) {
        if abs(slider.floatValue - value) > 0.001 { slider.floatValue = value }
    }

    /// Show or hide the status item. Hiding leaves Trident running; the position is
    /// remembered so the icon returns to the same spot when shown again.
    func setIconVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    // MARK: - State

    /// Refresh titles, check marks, and slider positions to reflect current state.
    func update(
        accessibilityGranted: Bool,
        enabled: Bool,
        running: Bool,
        middleClickEnabled: Bool,
        appSwitchEnabled: Bool,
        swipeDistanceMM: Float,
        palmEdgeBandMM: Float,
        hapticFeedback: Bool,
        launchAtLogin: Bool
    ) {
        if !accessibilityGranted {
            statusLine.title = "Needs Accessibility permission"
        } else if running {
            statusLine.title = "Active"
        } else if !enabled {
            statusLine.title = "Paused"
        } else {
            statusLine.title = "Inactive"
        }

        enabledButton.state = enabled ? .on : .off

        // The per-gesture toggles and tuning controls only take effect while the master
        // switch is on, so disable them all together when it's off.
        middleClickButton.state = middleClickEnabled ? .on : .off
        appSwitchButton.state = appSwitchEnabled ? .on : .off
        middleClickButton.isEnabled = enabled
        appSwitchButton.isEnabled = enabled
        swipeSlider.isEnabled = enabled
        palmSlider.isEnabled = enabled
        swipeResetButton.isEnabled = enabled
        palmResetButton.isEnabled = enabled

        setSlider(swipeSlider, to: swipeDistanceMM)
        swipeValueLabel.stringValue = fmtValue(swipeDistanceMM)
        setSlider(palmSlider, to: palmEdgeBandMM)
        palmValueLabel.stringValue = fmtValue(palmEdgeBandMM)

        hapticButton.state = hapticFeedback ? .on : .off
        launchButton.state = launchAtLogin ? .on : .off

        accessibilityItem.title = accessibilityGranted
            ? "Accessibility: Granted"
            : "Grant Accessibility Permission…"

        if let button = statusItem.button {
            button.appearsDisabled = !(accessibilityGranted && enabled)
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled() { onToggleEnabled() }
    @objc private func toggleMiddleClick() { onToggleMiddleClick() }
    @objc private func toggleAppSwitch() { onToggleAppSwitch() }
    @objc private func toggleHaptics() { onToggleHaptics() }
    @objc private func toggleLaunchAtLogin() { onToggleLaunchAtLogin() }
    @objc private func hideMenuBarIcon() { onHideMenuBarIcon() }
    @objc private func resetSwipeTapped() { onResetSwipe() }
    @objc private func resetPalmTapped() { onResetPalm() }
    @objc private func quit() { onQuit() }
    @objc private func openAccessibility() { onOpenAccessibility() }

    @objc private func swipeChanged(_ sender: NSSlider) { onSetSwipeDistance(sender.floatValue) }
    @objc private func palmChanged(_ sender: NSSlider) { onSetPalmEdgeBand(sender.floatValue) }
}
