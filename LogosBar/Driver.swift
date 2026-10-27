// Drives Logos on the user's behalf.
//
// Logos draws each panel's ribbon itself, so its buttons aren't visible to Accessibility —
// only the ribbon's outline is. The driver uses Accessibility to find the active panel's
// ribbon, reads the words on it with Vision text recognition, and clicks the matching word.

import Cocoa
import ApplicationServices
import ScreenCaptureKit
import Vision

struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One Logos panel: its ribbon (tab row plus, when expanded, a button row) and the whole panel area.
struct Panel {
    var ribbon: CGRect
    var area: CGRect
    var tabRow: CGRect { CGRect(x: ribbon.minX, y: ribbon.minY, width: ribbon.width, height: min(ribbon.height, 40)) }
    var buttonRow: CGRect? {
        ribbon.height > 50 ? CGRect(x: ribbon.minX, y: ribbon.minY + 40, width: ribbon.width, height: ribbon.height - 40) : nil
    }
}

final class LogosDriver {
    private var preparedPID: pid_t = 0
    private var app: AXUIElement!
    var lastClickInLogos: CGPoint?   // top-left-origin screen coordinates

    var logos: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: logosBundleID).first
    }

    func prepare() throws {
        try prepareAccessibility()
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw DriverError("LogosBar needs Screen Recording permission to read the Logos toolbar (System Settings → Privacy & Security → Screen & System Audio Recording).")
        }
    }

    func prepareAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw DriverError("LogosBar needs Accessibility permission (System Settings → Privacy & Security → Accessibility).")
        }
        guard let logos else { throw DriverError("Logos isn't running.") }
        if logos.processIdentifier != preparedPID {
            preparedPID = logos.processIdentifier
            app = AXUIElementCreateApplication(preparedPID)
            AXUIElementSetMessagingTimeout(app, 2)
        }
    }

    /// Where Logos's last menu-bar menu (Help) sits, so the toolbar can be placed just after it.
    func lastMenuFrame() throws -> CGRect {
        try prepareAccessibility()
        guard let menuBar: AXUIElement = attr(app, "AXMenuBar"),
              let last = children(menuBar).compactMap(frame).max(by: { $0.maxX < $1.maxX }) else {
            throw DriverError("Couldn't find Logos's menu bar.")
        }
        return last
    }

    // MARK: Accessibility helpers

    func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func children(_ element: AXUIElement) -> [AXUIElement] { attr(element, "AXChildren") ?? [] }
    func role(_ element: AXUIElement) -> String { attr(element, "AXRole") ?? "" }

    func label(_ element: AXUIElement) -> String {
        for name in ["AXTitle", "AXDescription", "AXValue"] {
            if let text: String = attr(element, name), !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        }
        return ""
    }

    func frame(_ element: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = attr(element, "AXPosition"),
              let sizeValue: AXValue = attr(element, "AXSize") else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &point)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    func mainWindow() throws -> AXUIElement {
        if let window: AXUIElement = attr(app, "AXMainWindow") { return window }
        if let window: AXUIElement = attr(app, "AXFocusedWindow") { return window }
        if let window = (attr(app, "AXWindows") as [AXUIElement]?)?.first { return window }
        throw DriverError("No Logos window found.")
    }

    func findButton(_ text: String, in root: AXUIElement) -> AXUIElement? {
        var queue = [root], index = 0
        while index < queue.count {
            let element = queue[index]; index += 1
            if role(element) == "AXButton", label(element).caseInsensitiveCompare(text) == .orderedSame { return element }
            queue.append(contentsOf: children(element))
        }
        return nil
    }

    // MARK: Panels

    /// Each panel shows up as a tab strip (scroll area), then the ribbon (a group directly under
    /// it, same width), then the panel's content.
    func panels() throws -> [Panel] {
        var found: [Panel] = []
        func walk(_ element: AXUIElement) {
            let kids = children(element)
            for (i, kid) in kids.enumerated() where i + 1 < kids.count && role(kid) == "AXScrollArea" {
                let next = kids[i + 1]
                guard role(next) == "AXGroup", let strip = frame(kid), let ribbon = frame(next),
                      abs(strip.minX - ribbon.minX) < 2, abs(strip.width - ribbon.width) < 2,
                      abs(strip.maxY - ribbon.minY) < 2 else { continue }
                var area = strip.union(ribbon)
                if i + 2 < kids.count, let content = frame(kids[i + 2]), abs(content.minX - ribbon.minX) < 2 {
                    area = area.union(content)
                }
                found.append(Panel(ribbon: ribbon, area: area))
            }
            kids.forEach(walk)
        }
        walk(try mainWindow())
        return found
    }

    /// The panel Logos treats as active: the one holding keyboard focus, else the one last clicked.
    func activePanel() throws -> Panel {
        let all = try panels()
        guard !all.isEmpty else { throw DriverError("Couldn't find any Logos panels.") }
        var points: [CGPoint] = []
        if let focused: AXUIElement = attr(app, "AXFocusedUIElement"), let rect = frame(focused), rect.width < 5000 {
            points.append(CGPoint(x: rect.midX, y: rect.midY))
        }
        if let click = lastClickInLogos { points.append(click) }
        for point in points {
            if let panel = all.first(where: { $0.area.contains(point) }) { return panel }
        }
        return all[0]
    }

    // MARK: Reading the screen

    func capture(_ rect: CGRect) throws -> CGImage {
        try blocking {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) ?? content.displays.first else {
                throw DriverError("No display to capture.")
            }
            let scale = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            })?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            config.width = Int(rect.width * scale)
            config.height = Int(rect.height * scale)
            config.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    /// Every line of text Vision reads in `rect`, in screen coordinates.
    func readText(in rect: CGRect) throws -> [(text: String, observation: VNRecognizedText, area: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try capture(rect)).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, candidate, rect)
        }
    }

    func screenRect(_ normalized: CGRect, in area: CGRect) -> CGRect {
        CGRect(x: area.minX + normalized.minX * area.width,
               y: area.minY + (1 - normalized.maxY) * area.height,
               width: normalized.width * area.width,
               height: normalized.height * area.height)
    }

    /// Finds `text` on screen inside `rect` and returns where it is. Whole-line matches beat
    /// matches inside a longer line.
    func locate(_ text: String, in rect: CGRect) throws -> CGRect? {
        var best: (rect: CGRect, score: Int)?
        for line in try readText(in: rect) {
            guard let range = line.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            // Require word boundaries so "View" doesn't match "Paged view".
            let before = range.lowerBound == line.text.startIndex ? " " : line.text[line.text.index(before: range.lowerBound)]
            let after = range.upperBound == line.text.endIndex ? " " : line.text[range.upperBound]
            let isWordStart = !before.isLetter, isWordEnd = !after.isLetter
            guard isWordStart && isWordEnd else { continue }
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let score = trimmed.caseInsensitiveCompare(text) == .orderedSame ? 2 : 1
            guard let box = try? line.observation.boundingBox(for: range)?.boundingBox else { continue }
            let hit = screenRect(box, in: line.area)
            if best == nil || score > best!.score { best = (hit, score) }
        }
        return best?.rect
    }

    func visibleText(in rect: CGRect) -> String {
        ((try? readText(in: rect)) ?? []).map(\.text).joined(separator: " · ")
    }

    // MARK: Input

    func activateLogos() {
        guard let logos, !logos.isActive else { return }
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<20 where !logos.isActive { usleep(25_000) }
        usleep(100_000)
    }

    func click(at point: CGPoint) {
        activateLogos()
        let saved = CGEvent(source: nil)?.location
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(30_000)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(40_000)
        }
        if let saved {
            usleep(60_000)
            CGWarpMouseCursorPosition(saved)
        }
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "return": 36, "tab": 48, "space": 49,
        "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    func sendKeys(_ combo: String) throws {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: key = Self.keyCodes[part]
            }
        }
        guard let key else { throw DriverError("Unknown key in “\(combo)”.") }
        activateLogos()
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    func typeText(_ text: String) {
        for character in text.utf16 {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                var unit = character
                event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
                event?.post(tap: .cghidEventTap)
            }
            usleep(8_000)
        }
    }

    // MARK: Steps

    private var lastPressed: CGRect?
    private var openedTab: String?   // the ribbon tab this action opened, if any

    /// Runs an action's steps. With `collapseRibbon`, a ribbon button row the action had to open
    /// is closed again afterwards; one that was already open is left alone.
    func run(_ action: Action, collapseRibbon: Bool) throws {
        // Only steps that read the ribbon need Screen Recording; shortcuts and the Go box don't.
        let readsScreen = action.steps.contains { $0.press != nil || $0.tab != nil || $0.menuItem != nil }
        try readsScreen ? prepare() : prepareAccessibility()
        activateLogos()
        let startedCollapsed = readsScreen ? try activePanel().buttonRow == nil : false
        openedTab = nil
        for step in action.steps {
            if let seconds = step.wait { Thread.sleep(forTimeInterval: seconds) }
            if let label = step.press { try pressOnRibbon(label, tab: step.tab) }
            else if let tab = step.tab { try openTab(tab) }
            if let item = step.menuItem { try chooseMenuItem(item) }
            if let keys = step.keys { try sendKeys(keys) }
            if let text = step.go { try runInGoBox(text) }
        }
        if collapseRibbon, startedCollapsed, let tab = openedTab {
            Thread.sleep(forTimeInterval: 0.2)
            // Clicking the tab that's showing closes its button row, as it does for a person.
            if try activePanel().buttonRow != nil { try openTab(tab) }
        }
    }

    func pressOnRibbon(_ label: String, tab: String?) throws {
        if let row = try activePanel().buttonRow, let hit = try locate(label, in: row) {
            return press(hit)
        }
        guard let tab else { throw DriverError("Couldn't see “\(label)” on the ribbon.") }
        try openTab(tab)
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.12)
            if let row = try activePanel().buttonRow, let hit = try locate(label, in: row) { return press(hit) }
        }
        let seen = (try? activePanel().buttonRow).flatMap { $0 }.map(visibleText) ?? "nothing"
        throw DriverError("Opened “\(tab)” but couldn't see “\(label)”. Ribbon shows: \(seen)")
    }

    func openTab(_ tab: String) throws {
        let panel = try activePanel()
        guard let hit = try locate(tab, in: panel.tabRow) else {
            throw DriverError("Couldn't see the “\(tab)” tab. Tab row shows: \(visibleText(in: panel.tabRow))")
        }
        openedTab = tab
        press(hit)
    }

    func press(_ rect: CGRect) {
        lastPressed = rect
        click(at: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// Picks an item from the dropdown the previous step opened, reading the area below it.
    func chooseMenuItem(_ label: String) throws {
        guard let anchor = lastPressed else { throw DriverError("No dropdown was opened before “\(label)”.") }
        let area = CGRect(x: anchor.minX - 60, y: anchor.maxY, width: 520, height: 900)
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.15)
            if let hit = try locate(label, in: area) { return press(hit) }
        }
        let seen = visibleText(in: area)
        try sendKeys("escape")
        throw DriverError("The dropdown had no “\(label)”. It shows: \(seen.prefix(300))")
    }

    func runInGoBox(_ text: String) throws {
        guard let goButton = findButton("Enter passage or topic", in: try mainWindow()) else {
            throw DriverError("Couldn't find the Go box.")
        }
        AXUIElementPerformAction(goButton, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.4)
        activateLogos()
        typeText(text)
        Thread.sleep(forTimeInterval: 1.0)   // let Logos fill in its suggestions
        try sendKeys("return")
    }

    // MARK: Diagnostics

    func describeActivePanel() throws -> String {
        try prepare()
        let all = try panels()
        let active = try activePanel()
        var lines = ["panels: " + all.map { "\($0.area)" }.joined(separator: ", "), "active ribbon: \(active.ribbon)"]
        lines.append("tab row: " + visibleText(in: active.tabRow))
        if let row = active.buttonRow { lines.append("button row: " + visibleText(in: row)) }
        return lines.joined(separator: "\n")
    }
}

/// Runs async work from the driver's background queue and waits for it.
func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
    var result: Result<T, Error>?
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try result!.get()
}
