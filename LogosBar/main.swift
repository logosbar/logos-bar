// LogosBar — a small floating toolbar of one-click shortcuts for Logos Bible Software.
//
// Each button runs a short "recipe" of steps against the Logos panel you last worked in:
// click a word on its ribbon (opening the right ribbon tab first), pick an item from a
// dropdown, send a keystroke, or run a command through the Go box. Recipes live in
// ~/Library/Application Support/LogosBar/actions.json so labels can be adjusted without
// rebuilding the app.

import Cocoa
import ApplicationServices

let logosBundleID = "com.logos.desktop.logos"
let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LogosBar")
let actionsURL = supportDir.appendingPathComponent("actions.json")
let logURL = supportDir.appendingPathComponent("LogosBar.log")
let dumpURL = supportDir.appendingPathComponent("what-logosbar-sees.txt")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Action recipes

struct Step: Codable {
    var tab: String?        // ribbon tab that holds `press` (opened only if `press` isn't already showing)
    var press: String?      // control label to press in the active panel
    var menuItem: String?   // item to choose from the dropdown the previous step opened
    var keys: String?       // keystroke sent to Logos, e.g. "cmd+f"
    var go: String?         // text to run through the Go box, e.g. "Copy Bible Verses"
    var wait: Double?       // pause in seconds
    var layoutPrompt: Bool? // ask whether to save the current layout or open one, then do it
    var layout: String?     // saved layout to open, by name
    var saveLayout: String? // name to save the current panels under
    var copyQuote: Bool?    // copy the selection, keeping only the citation's author, title and page
}

struct Action: Codable, Identifiable {
    var id: String
    var label: String
    var symbol: String      // SF Symbol name
    var steps: [Step]
    var enabled: Bool?      // nil means shown, so older actions.json files keep every button

    var isEnabled: Bool {
        get { enabled ?? true }
        set { enabled = newValue }
    }
}

let defaultActions: [Action] = [
    Action(id: "pageNumbers", label: "Toggle page numbers", symbol: "number.square",
           steps: [Step(tab: "Formatting", press: "Markers"), Step(menuItem: "Page numbers"),
                   Step(keys: "escape", wait: 0.15)]),
    Action(id: "contents", label: "Toggle table of contents", symbol: "list.bullet.indent",
           steps: [Step(keys: "shift+cmd+c")]),
    Action(id: "find", label: "Find in this panel", symbol: "magnifyingglass",
           steps: [Step(keys: "cmd+f")]),
    Action(id: "visualFilters", label: "Toggle visual filters", symbol: "camera.filters",
           steps: [Step(tab: "Formatting", press: "Visual Filters"), Step(menuItem: "Show Visual Filters"),
                   Step(keys: "escape", wait: 0.15)]),
    // Logos's own shortcuts, shown next to these options in the View tab's dropdowns.
    Action(id: "parallel", label: "Toggle parallel text", symbol: "rectangle.split.2x1",
           steps: [Step(keys: "shift+cmd+m")]),
    Action(id: "interlinear", label: "Toggle interlinear", symbol: "character.textbox",
           steps: [Step(keys: "cmd+i")]),
    Action(id: "copyVerses", label: "Copy Bible Verses", symbol: "doc.on.doc",
           steps: [Step(keys: "opt+cmd+b")]),
    Action(id: "copyQuote", label: "Copy quote with short citation", symbol: "text.quote",
           steps: [Step(copyQuote: true)]),
    Action(id: "layouts", label: "Save or open a layout", symbol: "rectangle.3.group",
           steps: [Step(layoutPrompt: true)]),
]

func saveActions(_ actions: [Action]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do { try encoder.encode(actions).write(to: actionsURL) } catch { log("Couldn't save actions.json: \(error)") }
}

func loadActions() -> [Action] {
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: actionsURL.path) {
        saveActions(defaultActions)
    }
    do {
        var actions = try JSONDecoder().decode([Action].self, from: Data(contentsOf: actionsURL))
        // Buttons added in later versions join the end of an existing actions.json.
        let missing = defaultActions.filter { action in !actions.contains { $0.id == action.id } }
        if !missing.isEmpty {
            actions += missing
            saveActions(actions)
        }
        return actions
    } catch {
        log("actions.json could not be read (\(error)); using built-in defaults")
        return defaultActions
    }
}

// MARK: - Floating toolbar

final class ToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The handle along the floating toolbar's leading edge (top edge when vertical): a tinted strip
/// of dots, set apart from the buttons. Dragging it moves the toolbar.
final class GripView: NSView {
    var vertical = false { didSet { needsDisplay = true } }
    var scale: CGFloat = 1 { didSet { needsDisplay = true } }
    static let baseThickness: CGFloat = 16

    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        bounds.fill()
        // Two columns of four dots, turned sideways when the toolbar is vertical.
        let columns = vertical ? 4 : 2, rows = vertical ? 2 : 4
        let dot = 2.5 * scale, gap = 3 * scale
        let width = CGFloat(columns) * dot + CGFloat(columns - 1) * gap
        let height = CGFloat(rows) * dot + CGFloat(rows - 1) * gap
        let origin = NSPoint(x: bounds.midX - width / 2, y: bounds.midY - height / 2)
        NSColor.controlAccentColor.withAlphaComponent(0.6).setFill()
        for column in 0..<columns {
            for row in 0..<rows {
                NSBezierPath(ovalIn: NSRect(x: origin.x + CGFloat(column) * (dot + gap),
                                            y: origin.y + CGFloat(row) * (dot + gap),
                                            width: dot, height: dot)).fill()
            }
        }
    }
}

/// A toolbar button that lifts under the pointer: a raised accent-tinted tile behind an accent icon.
final class HoverButton: NSButton {
    var restingTint: NSColor = .labelColor { didSet { updateLook() } }
    /// Overrides the icon color while the button's action runs or after it fails.
    var statusTint: NSColor? { didSet { updateLook() } }
    var scale: CGFloat = 1 { didSet { updateLook() } }
    private var hovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Always active: the toolbar's panel never becomes the key window.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateLook() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateLook() }

    func updateLook() {
        contentTintColor = statusTint ?? (hovered ? .controlAccentColor : restingTint)
        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = 6 * scale
        layer.masksToBounds = false
        layer.backgroundColor = hovered ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : nil
        layer.borderWidth = hovered ? 0.5 * scale : 0
        layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = hovered ? 0.25 : 0
        layer.shadowRadius = 2 * scale
        layer.shadowOffset = CGSize(width: 0, height: -1 * scale)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let driver = LogosDriver()
    let queue = DispatchQueue(label: "LogosBar.driver")
    let prefs = Preferences()
    lazy var settingsWindow = SettingsWindowController(prefs: prefs)
    var panel: ToolbarPanel!
    var background: NSVisualEffectView!
    var pill: NSView!
    var grip: GripView!
    var gripAlongLeft: [NSLayoutConstraint] = []
    var gripAlongTop: [NSLayoutConstraint] = []
    var stack: NSStackView!
    var busy = false
    var helpMenuFrame: CGRect?   // last known position of Logos's Help menu
    var positioning = false      // true while LogosBar moves the toolbar itself, so it isn't saved as the user's spot
    var following = false        // true while looking for the active panel's tab

    var placement: Placement { prefs.placement }
    /// The buttons shown on the toolbar, in order. Button tags index into this.
    var visibleActions: [Action] { prefs.actions.filter(\.isEnabled) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        prefs.changed = { [weak self] in self?.applyPlacement() }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            log("Waiting for Accessibility permission")
        }
        // The ribbon buttons read the screen; ask now so both prompts come together.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateVisibility), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateVisibility), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Remember where the user last clicked in Logos; that's the panel Logos treats as active.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == logosBundleID,
                  let screenHeight = NSScreen.screens.first?.frame.height else { return }
            let location = NSEvent.mouseLocation
            let point = CGPoint(x: location.x, y: screenHeight - location.y)
            self?.queue.async { self?.driver.lastClickInLogos = point }
            // A click may have made another panel active; give Logos a moment to move its orange strip.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.followActivePanel() }
        }
        // Keyboard and menu commands can switch panels too, so keep checking while Logos is in front.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.followActivePanel() }
        updateVisibility()
        if CommandLine.arguments.contains("--dump") { saveUIMap() }
        if CommandLine.arguments.contains("--settings") {
            showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let frame = self.settingsWindow.frame { self.saveSnapshot(of: frame, name: "settings.png") }
            }
        } else if CommandLine.arguments.contains("--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.saveSnapshot(of: self.panel.frame.insetBy(dx: -60, dy: -8), name: "snapshot.png")
            }
        }
        runFromCommandLine()
    }

    func buildPanel() {
        panel = ToolbarPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false

        let container = NSView()
        container.menu = makeMenu()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10   // also rounds the grip's outer corners
        panel.contentView = container

        background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(background)

        stack = NSStackView()
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        // Docked, a solid pill behind the icons reads against any menu bar or wallpaper.
        pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 7
        pill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pill, positioned: .below, relativeTo: stack)
        // Above the stack so it gets the clicks in its strip.
        grip = GripView()
        grip.toolTip = "Drag to move"
        grip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grip)
        gripAlongLeft = [
            grip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grip.topAnchor.constraint(equalTo: container.topAnchor),
            grip.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            grip.widthAnchor.constraint(equalToConstant: GripView.baseThickness),
        ]
        gripAlongTop = [
            grip.topAnchor.constraint(equalTo: container.topAnchor),
            grip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grip.heightAnchor.constraint(equalToConstant: GripView.baseThickness),
        ]
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pill.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pill.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            pill.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        applyPlacement()
        NotificationCenter.default.addObserver(
            self, selector: #selector(floatingToolbarMoved), name: NSWindow.didMoveNotification, object: panel)
    }

    /// Restyles and repositions the toolbar for the current placement.
    func applyPlacement() {
        let docked = placement == .menuBar
        panel.level = docked ? .statusBar : .floating
        panel.isMovableByWindowBackground = placement == .floating
        panel.hasShadow = !docked
        let light = prefs.dockedStyle == .light
        panel.appearance = docked ? NSAppearance(named: light ? .aqua : .darkAqua) : nil
        pill.layer?.backgroundColor = (light ? NSColor(white: 0.97, alpha: 0.92) : NSColor(white: 0.12, alpha: 0.88)).cgColor
        pill.layer?.borderWidth = light ? 0.5 : 0
        pill.layer?.borderColor = NSColor(white: 0, alpha: 0.15).cgColor
        background.isHidden = docked
        pill.isHidden = !docked
        // Above the active panel LogosBar places the toolbar itself, so there's nothing to drag.
        grip.isHidden = placement != .floating
        panel.contentView?.layer?.masksToBounds = !docked
        positioning = true
        rebuildButtons()
        if placement == .floating {
            // The size comes from the buttons; put the top-left corner back where the user left it.
            panel.setFrameTopLeftPoint(savedFloatingTopLeft())
        }
        positioning = false
        refreshMenus()
        updateVisibility()
    }

    /// Where the floating toolbar's top-left corner was last dragged to, if that's still on a screen.
    /// (AppKit's own frame autosave moves the toolbar to another monitor when its size changes.)
    func savedFloatingTopLeft() -> NSPoint {
        var saved = UserDefaults.standard.string(forKey: "floatingTopLeft").map(NSPointFromString)
        if saved == nil, let old = UserDefaults.standard.string(forKey: "NSWindow Frame LogosBarPanel") {
            // Carry over the position saved by earlier versions: "x y width height …".
            let numbers = old.split(separator: " ").compactMap { Double($0) }
            if numbers.count >= 4 { saved = NSPoint(x: numbers[0], y: numbers[1] + numbers[3]) }
        }
        if let saved, NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: saved.x + 10, y: saved.y - 10)) }) {
            return saved
        }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: screen.midX - 150, y: screen.maxY - 60)
    }

    @objc func floatingToolbarMoved() {
        guard placement == .floating, !positioning else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)), forKey: "floatingTopLeft")
    }

    /// Places the toolbar in the menu bar, just right of Logos's Help menu.
    func dockAfterHelpMenu() {
        // Only trust Logos's menu bar position while Logos is in front; with LogosBar's Settings
        // open, Logos can report it on another display.
        let logosInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == logosBundleID
        let cached = helpMenuFrame
        queue.async { [driver] in
            let help: CGRect
            if let cached, !logosInFront {
                help = cached
            } else {
                do { help = try driver.lastMenuFrame() } catch {
                    log("Menu bar placement: \(error)")
                    return
                }
            }
            DispatchQueue.main.async {
                self.helpMenuFrame = help
                guard self.placement == .menuBar, let primary = NSScreen.screens.first else { return }
                // Logos reports its menu items taller than the menu bar, so size to the menu bar itself.
                var height = primary.frame.maxY - primary.visibleFrame.maxY
                if height < 20 { height = 24 }   // menu bar set to hide automatically
                let frame = NSRect(x: help.maxX + 8, y: primary.frame.maxY - height, width: self.barSize().width, height: height)
                guard frame != self.panel.frame else { return }
                self.panel.setFrame(frame, display: true)
                log("Docked after Help at \(frame)")
            }
        }
    }

    /// Floats the toolbar just above the orange strip on the active panel's tab, kept on screen. When
    /// there's no room above, it sits to the right of the panel's input box, else at the top of the
    /// panel's content.
    func followActivePanel() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard placement == .abovePanel, !following, panel.isVisible,
              front == logosBundleID || front == Bundle.main.bundleIdentifier else { return }
        following = true
        queue.async { [driver] in
            let found = try? driver.activeTabStrip()
            let header = found.flatMap { try? driver.header(below: $0.tabRow) }
            DispatchQueue.main.async {
                self.following = false
                guard self.placement == .abovePanel, let found, let primary = NSScreen.screens.first else { return }
                // Convert from the top-left origin used by Accessibility to AppKit's bottom-left origin.
                let size = self.panel.frame.size
                var origin = NSPoint(x: found.orange.minX, y: primary.frame.maxY - found.orange.minY)
                let point = NSPoint(x: origin.x + 1, y: origin.y - 1)
                let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? primary).visibleFrame
                origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
                if origin.y + size.height > visible.maxY {
                    // A panel at the top of the screen has no room above it. Sit beside its input box
                    // when the bar fits there; otherwise hang below its tabs and anything under them
                    // (input box, ribbon), at the top of its content, so it hides none of them.
                    let gap: CGFloat = 8
                    if let input = header?.input, let header, input.maxX + gap + size.width <= header.roomRight - gap {
                        origin.x = input.maxX + gap
                        origin.y = primary.frame.maxY - input.midY - size.height / 2
                    } else {
                        origin.y = primary.frame.maxY - (header?.contentTop ?? found.tabRow.maxY) - size.height
                    }
                }
                guard origin != self.panel.frame.origin else { return }
                self.positioning = true
                self.panel.setFrameOrigin(origin)
                self.positioning = false
            }
        }
    }

    func rebuildButtons() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let docked = placement == .menuBar
        stack.orientation = prefs.vertical && !docked ? .vertical : .horizontal
        let side = buttonSide
        // Everything on the floating bar grows with the chosen size; the docked bar never does.
        let scale = docked ? 1 : prefs.size.scale
        let pad = 6 * scale
        stack.spacing = 2 * scale
        panel.contentView?.layer?.cornerRadius = 10 * scale
        background.layer?.cornerRadius = 10 * scale
        // A thin outline in the grip's accent color, drawn over the edges of everything inside.
        panel.contentView?.layer?.borderWidth = docked ? 0 : 1.5 * scale
        panel.contentView?.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        // Floating, the grip strip takes the leading edge (the top when vertical); leave room for it.
        let horizontal = stack.orientation == .horizontal
        let gripThickness = GripView.baseThickness * scale
        grip.vertical = !horizontal
        grip.scale = scale
        gripAlongLeft.last?.constant = gripThickness
        gripAlongTop.last?.constant = gripThickness
        NSLayoutConstraint.deactivate(gripAlongLeft + gripAlongTop)
        NSLayoutConstraint.activate(horizontal ? gripAlongLeft : gripAlongTop)
        let gripRoom = placement == .floating ? gripThickness + pad : pad
        stack.edgeInsets = docked ? NSEdgeInsets(top: 0, left: 5, bottom: 0, right: 5)
            : NSEdgeInsets(top: horizontal ? pad : gripRoom, left: horizontal ? gripRoom : pad, bottom: pad, right: pad)
        for (index, action) in visibleActions.enumerated() {
            let image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.label)
                ?? NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: action.label)!
            let button = HoverButton(image: image, target: self, action: #selector(runAction(_:)))
            button.tag = index
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.toolTip = action.label
            // Monochrome keeps layered symbols (like the visual-filters circles) fully opaque.
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: docked ? 14 : 17 * scale, weight: .regular)
                .applying(.preferringMonochrome())
            button.scale = scale
            button.restingTint = self.iconColor
            button.widthAnchor.constraint(equalToConstant: side).isActive = true
            button.heightAnchor.constraint(equalToConstant: side).isActive = true
            button.menu = makeMenu()
            stack.addArrangedSubview(button)
        }
        if docked {
            dockAfterHelpMenu()
        } else {
            let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            panel.setContentSize(barSize())
            panel.setFrameTopLeftPoint(topLeft)
        }
    }

    var buttonSide: CGFloat { placement == .menuBar ? 24 : 32 * prefs.size.scale }
    var iconColor: NSColor {
        guard placement == .menuBar else { return .labelColor }
        return prefs.dockedStyle == .light ? NSColor(white: 0.1, alpha: 1) : .white
    }

    /// The toolbar's size for its buttons, spacing and padding.
    func barSize() -> NSSize {
        let count = CGFloat(visibleActions.count)
        let length = count * buttonSide + max(count - 1, 0) * stack.spacing
        let insets = stack.edgeInsets
        return stack.orientation == .horizontal
            ? NSSize(width: length + insets.left + insets.right, height: buttonSide + insets.top + insets.bottom)
            : NSSize(width: buttonSide + insets.left + insets.right, height: length + insets.top + insets.bottom)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Edit Actions…", action: #selector(editActions), keyEquivalent: "")
        menu.addItem(withTitle: "Reload Actions", action: #selector(reloadActions), keyEquivalent: "")
        menu.addItem(withTitle: "Show What LogosBar Sees", action: #selector(saveUIMap), keyEquivalent: "")
        menu.addItem(withTitle: "Show Log", action: #selector(showLog), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LogosBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) && $0.action != nil { $0.target = self } }
        return menu
    }

    @objc func showSettings() { settingsWindow.show() }

    @objc func updateVisibility() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // LogosBar itself counts too, so the bar stays in view while Settings is open.
        let logosInFront = front == logosBundleID || front == Bundle.main.bundleIdentifier
        // Docked, the bar belongs next to Logos's menus, which only show while Logos is in front.
        let wanted = placement == .menuBar ? logosInFront : (!prefs.onlyWithLogos || logosInFront)
        if wanted && !visibleActions.isEmpty {
            if placement == .menuBar { dockAfterHelpMenu() }
            panel.orderFrontRegardless()
            followActivePanel()
        } else {
            panel.orderOut(nil)
        }
    }

    @objc func runAction(_ sender: HoverButton) {
        let actions = visibleActions
        guard !busy, actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        if action.steps.contains(where: { $0.layoutPrompt == true }) {
            if let steps = layoutStepsFromCommandLine() {
                perform(action, steps: steps, from: sender)
            } else {
                showLayoutsMenu(for: action, from: sender)
            }
            return
        }
        perform(action, steps: action.steps, from: sender)
    }

    func perform(_ action: Action, steps: [Step], from sender: HoverButton) {
        var action = action
        action.steps = steps
        busy = true
        sender.statusTint = .controlAccentColor
        let collapseRibbon = prefs.collapseRibbon
        let quoteDestination = prefs.quoteDestination
        queue.async { [driver] in
            driver.quoteDestination = quoteDestination
            var failure: String?
            do { try driver.run(action, collapseRibbon: collapseRibbon) } catch { failure = "\(error)" }
            DispatchQueue.main.async {
                self.busy = false
                if let failure {
                    log("\(action.id): \(failure)")
                    NSSound.beep()
                    sender.statusTint = .systemRed
                    sender.toolTip = "\(action.label)\n⚠︎ \(failure)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        sender.statusTint = nil
                    }
                } else {
                    log("\(action.id): ok")
                    sender.statusTint = nil
                    sender.toolTip = action.label
                }
            }
        }
    }

    // MARK: Layouts

    /// `--layout <name>` and `--save-layout <name>` answer the Layouts menu, for testing from the command line.
    func layoutStepsFromCommandLine() -> [Step]? {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--layout"), flag + 1 < arguments.count {
            return [Step(layout: arguments[flag + 1])]
        }
        if let flag = arguments.firstIndex(of: "--save-layout"), flag + 1 < arguments.count {
            return [Step(saveLayout: arguments[flag + 1])]
        }
        return nil
    }

    /// The Layouts button's choice while its menu is open.
    var pendingLayoutAction: (action: Action, button: HoverButton)?

    /// Drops down a menu under the Layouts button: Save Current Layout, the most recently saved
    /// layouts (the active one ticked), then Open Other Layout.
    func showLayoutsMenu(for action: Action, from button: HoverButton) {
        let active = queue.sync { [driver] in (try? driver.activeLayoutName()) ?? nil }
        let recent = driver.savedLayoutNames(limit: prefs.recentLayoutCount)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(layoutMenuItem("Save Current Layout…", tag: 0))
        if !recent.isEmpty {
            menu.addItem(.separator())
            for name in recent {
                let item = layoutMenuItem(name, tag: 2)
                item.representedObject = name
                item.state = name == active ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(layoutMenuItem("Open Other Layout…", tag: 1))
        pendingLayoutAction = (action, button)
        let below = NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: below, in: button)
    }

    func layoutMenuItem(_ title: String, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(layoutMenuChose(_:)), keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    @objc func layoutMenuChose(_ item: NSMenuItem) {
        guard let (action, button) = pendingLayoutAction else { return }
        pendingLayoutAction = nil
        let steps: [Step]?
        switch item.tag {
        case 0: steps = askForLayoutToSave()
        case 1: steps = askForLayoutToOpen().flatMap(stepsToOpen)
        default: steps = (item.representedObject as? String).flatMap(stepsToOpen)
        }
        if let steps { perform(action, steps: steps, from: button) }
    }

    /// The steps that open a saved layout, first saving the open panels if they aren't a saved layout
    /// and the user names them.
    func stepsToOpen(_ name: String) -> [Step]? {
        let active = queue.sync { [driver] in (try? driver.activeLayoutName()) ?? nil }
        guard active?.isEmpty ?? true else { return [Step(layout: name)] }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Layout name"
        let ask = NSAlert()
        ask.messageText = "Name the current layout?"
        ask.informativeText = "The panels you have open aren’t saved as a layout. Give them a name to keep them before opening “\(name)”."
        ask.accessoryView = field
        ask.addButton(withTitle: "Save and Open")
        ask.addButton(withTitle: "Don’t Save")
        ask.addButton(withTitle: "Cancel")
        ask.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        switch ask.runModal() {
        case .alertFirstButtonReturn:
            let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
            return newName.isEmpty ? [Step(layout: name)] : [Step(saveLayout: newName), Step(layout: name)]
        case .alertSecondButtonReturn: return [Step(layout: name)]
        default: return nil
        }
    }

    /// Asks for the name of a saved layout to open, offering every layout saved in Logos.
    func askForLayoutToOpen() -> String? {
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        field.addItems(withObjectValues: driver.savedLayoutNames(limit: 200))
        field.placeholderString = "Layout name"
        field.completes = true
        let ask = NSAlert()
        ask.messageText = "Open Layout"
        ask.informativeText = "Type or choose the name of the layout to open."
        ask.accessoryView = field
        ask.addButton(withTitle: "Open")
        ask.addButton(withTitle: "Cancel")
        ask.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard ask.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Asks for the name to save the current layout under, offering the active layout's name.
    func askForLayoutToSave() -> [Step]? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = queue.sync { [driver] in (try? driver.activeLayoutName()) ?? nil } ?? ""
        field.placeholderString = "Layout name"
        let ask = NSAlert()
        ask.messageText = "Save Layout"
        ask.informativeText = "Save the open panels as a layout. Keep the active layout’s name to update it, or type a new name."
        ask.accessoryView = field
        ask.addButton(withTitle: "Save")
        ask.addButton(withTitle: "Cancel")
        ask.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard ask.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : [Step(saveLayout: name)]
    }

    func refreshMenus() {
        panel.contentView?.menu = makeMenu()
        grip.menu = makeMenu()
        stack.arrangedSubviews.forEach { $0.menu = makeMenu() }
    }
    @objc func editActions() { NSWorkspace.shared.open(actionsURL) }
    @objc func reloadActions() { prefs.reloadActions() }
    @objc func showLog() { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }

    /// Writes what LogosBar can see of the active panel, for adjusting actions.json.
    @objc func saveUIMap() {
        queue.async { [driver] in
            do {
                try driver.describeActivePanel().write(to: dumpURL, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([dumpURL]) }
            } catch {
                log("UI map: \(error)")
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
    }

    /// `--snapshot` and `--settings` save a picture of part of the screen, for checking how LogosBar looks.
    func saveSnapshot(of frame: NSRect, name: String) {
        guard let primary = NSScreen.screens.first else { return }
        // Convert from AppKit's bottom-left origin to the top-left origin used for capture.
        let rect = CGRect(x: frame.minX, y: max(primary.frame.maxY - frame.maxY, 0), width: frame.width, height: frame.height)
        let url = supportDir.appendingPathComponent(name)
        queue.async { [driver] in
            do {
                let image = try driver.capture(rect)
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                try data?.write(to: url)
                log("Snapshot saved")
            } catch {
                log("Snapshot: \(error)")
            }
        }
    }

    /// `--run <id>` runs one action at launch, for testing from the command line.
    func runFromCommandLine() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--run"), flag + 1 < arguments.count,
              let index = visibleActions.firstIndex(where: { $0.id == arguments[flag + 1] }),
              let button = stack.arrangedSubviews.compactMap({ $0 as? HoverButton }).first(where: { $0.tag == index }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.runAction(button) }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
