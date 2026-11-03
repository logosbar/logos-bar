// Drives Logos on the user's behalf.
//
// Logos draws each panel's ribbon itself, so its buttons aren't visible to Accessibility —
// only the ribbon's outline is. The driver uses Accessibility to find the active panel's
// ribbon, reads the words on it with Vision text recognition, and clicks the matching word.

import Cocoa
import ApplicationServices
import ScreenCaptureKit
import SQLite3
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
    var quoteDestination = QuoteDestination.clipboard

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
        findButtons(text, in: root).first
    }

    func findButtons(_ text: String, in root: AXUIElement) -> [AXUIElement] {
        var queue = [root], index = 0, found: [AXUIElement] = []
        while index < queue.count {
            let element = queue[index]; index += 1
            if role(element) == "AXButton", label(element).caseInsensitiveCompare(text) == .orderedSame { found.append(element) }
            queue.append(contentsOf: children(element))
        }
        return found
    }

    // MARK: Panels

    /// Each panel shows up as a tab strip (scroll area), then the ribbon (a group directly under
    /// it, same width), then the panel's content. When a panel's tabs overflow, the strip's scroll
    /// arrows (buttons and their images) sit between the strip and the ribbon.
    func panels() throws -> [Panel] {
        var found: [Panel] = []
        func walk(_ element: AXUIElement) {
            let kids = children(element)
            for (i, kid) in kids.enumerated() where role(kid) == "AXScrollArea" {
                guard let r = kids[(i + 1)...].firstIndex(where: { !["AXButton", "AXImage"].contains(role($0)) }) else { continue }
                let next = kids[r]
                guard role(next) == "AXGroup", let strip = frame(kid), let ribbon = frame(next),
                      abs(strip.minX - ribbon.minX) < 2, abs(strip.width - ribbon.width) < 2,
                      abs(strip.maxY - ribbon.minY) < 2 else { continue }
                var area = strip.union(ribbon)
                if r + 1 < kids.count, let content = frame(kids[r + 1]), abs(content.minX - ribbon.minX) < 2 {
                    area = area.union(content)
                }
                found.append(Panel(ribbon: ribbon, area: area))
            }
            kids.forEach(walk)
        }
        walk(try mainWindow())
        return found
    }

    /// Every panel's tab strip, including panels without a ribbon (such as guides): the short
    /// scroll areas that hold a panel's tabs.
    func tabStrips() throws -> [CGRect] {
        var found: [CGRect] = []
        func walk(_ element: AXUIElement) {
            for kid in children(element) {
                if role(kid) == "AXScrollArea", let rect = frame(kid), (20...60).contains(rect.height), rect.width > 100 {
                    found.append(rect)
                }
                walk(kid)
            }
        }
        walk(try mainWindow())
        return found
    }

    /// The panel Logos treats as active: the one whose tab carries the orange strip, else the one
    /// holding keyboard focus, else the one last clicked. Focus and clicks can point at another
    /// panel (focus can sit outside every panel), so the strip goes first.
    func activePanel() throws -> Panel {
        let all = try panels()
        guard !all.isEmpty else { throw DriverError("Couldn't find any Logos panels.") }
        var points: [CGPoint] = []
        if let strip = try? activeTabStrip() { points.append(CGPoint(x: strip.orange.midX, y: strip.orange.maxY)) }
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

    /// Captures `rect` of the screen; `hidingLogosBar` leaves LogosBar's own windows out.
    func capture(_ rect: CGRect, hidingLogosBar: Bool = false) throws -> CGImage {
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
            let own = hidingLogosBar ? content.windows.filter { $0.owningApplication?.processID == getpid() } : []
            let filter = SCContentFilter(display: display, excludingWindows: own)
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
        var best: (rect: CGRect, whole: Bool)?
        for hit in try locateAll(text, in: rect) where best == nil || (hit.whole && !best!.whole) { best = hit }
        return best?.rect
    }

    /// Every place `text` appears as whole words inside `rect`, and whether it's the whole line.
    func locateAll(_ text: String, in rect: CGRect) throws -> [(rect: CGRect, whole: Bool)] {
        var hits: [(rect: CGRect, whole: Bool)] = []
        for line in try readText(in: rect) {
            guard let range = line.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            // Require word boundaries so "View" doesn't match "Paged view".
            let before = range.lowerBound == line.text.startIndex ? " " : line.text[line.text.index(before: range.lowerBound)]
            let after = range.upperBound == line.text.endIndex ? " " : line.text[range.upperBound]
            let isWordStart = !before.isLetter, isWordEnd = !after.isLetter
            guard isWordStart && isWordEnd else { continue }
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard let box = try? line.observation.boundingBox(for: range)?.boundingBox else { continue }
            hits.append((screenRect(box, in: line.area), trimmed.caseInsensitiveCompare(text) == .orderedSame))
        }
        return hits
    }

    func visibleText(in rect: CGRect) -> String {
        ((try? readText(in: rect)) ?? []).map(\.text).joined(separator: " · ")
    }

    // MARK: The active tab

    /// The orange strip Logos draws along the top of the active panel's selected tab, and the
    /// tab row it sits in.
    func activeTabStrip() throws -> (orange: CGRect, tabRow: CGRect) {
        try prepare()
        for strip in try tabStrips() {
            // The orange sits at the very top of the tab row, above the tab icons.
            let top = CGRect(x: strip.minX, y: strip.minY, width: strip.width, height: 6)
            let image = try capture(top, hidingLogosBar: true)
            let scale = CGFloat(image.width) / top.width
            if let run = orangeRun(in: image, minLength: Int(20 * scale)) {
                let orange = CGRect(x: top.minX + CGFloat(run.start) / scale, y: top.minY + CGFloat(run.row) / scale,
                                    width: CGFloat(run.length) / scale, height: 3)
                return (orange, strip)
            }
        }
        throw DriverError("Couldn't see the orange strip on the active panel's tab.")
    }

    /// What sits between the tabs `strip` of a panel and its content: where the content begins (below
    /// a guide's input box or a resource's ribbon), and the panel's input box with the free space to
    /// its right, up to the next control on its row (such as a guide's Add button). The content is
    /// the first tall sibling after the strip that spans the panel's width.
    func header(below strip: CGRect) throws -> (contentTop: CGFloat, input: CGRect?, roomRight: CGFloat)? {
        var result: (contentTop: CGFloat, input: CGRect?, roomRight: CGFloat)?
        func walk(_ element: AXUIElement) {
            let kids = children(element)
            if let i = kids.firstIndex(where: { role($0) == "AXScrollArea" && frame($0) == strip }) {
                let after = kids[(i + 1)...].compactMap { kid in frame(kid).map { (kid, $0) } }
                guard let content = after.first(where: {
                    abs($0.1.minX - strip.minX) < 2 && abs($0.1.width - strip.width) < 2 && $0.1.height > 100
                })?.1 else { return }
                let between = after.map(\.1).filter {
                    $0.minY >= strip.maxY - 1 && $0.maxY <= content.minY + 1 && $0.width > 0 && $0.height > 0
                        && $0.minX >= strip.minX - 1 && $0.maxX <= strip.maxX + 1
                }
                let input = after.first { role($0.0) == "AXTextField" && between.contains($0.1) }?.1
                let roomRight = input.map { input in
                    between.filter { $0.minX >= input.maxX && $0.minY < input.maxY && $0.maxY > input.minY }
                        .map(\.minX).min() ?? strip.maxX
                } ?? strip.maxX
                result = (content.minY, input, roomRight)
                return
            }
            for kid in kids where result == nil { walk(kid) }
        }
        walk(try mainWindow())
        return result
    }

    /// The topmost long horizontal run of orange pixels in `image`.
    func orangeRun(in image: CGImage, minLength: Int) -> (row: Int, start: Int, length: Int)? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for row in 0..<height {
            var best: (start: Int, length: Int)?
            var start = 0
            for x in 0...width {
                let i = (row * width + x) * 4
                let orange = x < width && pixels[i] > 190 && (70...175).contains(pixels[i + 1]) && pixels[i + 2] < 110
                if !orange {
                    if x - start >= minLength, x - start > best?.length ?? 0 { best = (start, x - start) }
                    start = x + 1
                }
            }
            if let best { return (row, best.start, best.length) }
        }
        return nil
    }

    // MARK: Input

    func activateLogos() {
        guard let logos, !logos.isActive else { return }
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<20 where !logos.isActive { usleep(25_000) }
        usleep(100_000)
    }

    /// Clicks at a screen point. `hover` keeps the pointer there first, for controls that only
    /// take a click once they've drawn their hover state.
    func click(at point: CGPoint, hover: useconds_t = 30_000) {
        activateLogos()
        let saved = CGEvent(source: nil)?.location
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(hover)
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

    /// Sends a keystroke to Logos, or with `toLogos` false, to whichever app is in front.
    func sendKeys(_ combo: String, toLogos: Bool = true) throws {
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
        if toLogos { activateLogos() }
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
        let readsScreen = action.steps.contains {
            $0.press != nil || $0.tab != nil || $0.menuItem != nil || $0.layout != nil || $0.saveLayout != nil
        }
        try readsScreen ? prepare() : prepareAccessibility()
        activateLogos()
        // Only ribbon steps need the active panel; layouts work through the sidebar.
        let usesRibbon = action.steps.contains { $0.press != nil || $0.tab != nil || $0.menuItem != nil }
        let startedCollapsed = usesRibbon ? try activePanel().buttonRow == nil : false
        openedTab = nil
        for step in action.steps {
            if let seconds = step.wait { Thread.sleep(forTimeInterval: seconds) }
            if let label = step.press { try pressOnRibbon(label, tab: step.tab) }
            else if let tab = step.tab { try openTab(tab) }
            if let item = step.menuItem { try chooseMenuItem(item) }
            if let keys = step.keys { try sendKeys(keys) }
            if let text = step.go { try runInGoBox(text) }
            if let name = step.layout { try openLayout(name) }
            if let name = step.saveLayout { try saveLayout(name) }
            if step.copyQuote == true { try copyQuote() }
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

    /// Copies the selection with ⌘C and replaces it on the clipboard with a short Markdown quote,
    /// then, if Settings asks for it, pastes it into the note open in Obsidian.
    func copyQuote() throws {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        try sendKeys("cmd+c")
        for _ in 0..<60 where pasteboard.changeCount == before { usleep(50_000) }
        guard pasteboard.changeCount != before else { throw DriverError("Logos copied nothing. Select some text first.") }
        usleep(150_000)   // let Logos finish writing every format
        guard let copied = copiedRichText(on: pasteboard), let quote = shortQuote(from: copied) else {
            log("copyQuote: clipboard has \((pasteboard.types ?? []).map(\.rawValue)): \(pasteboard.string(forType: .string)?.prefix(400) ?? "")")
            throw DriverError("The copied text had no Logos citation, so the clipboard was left as Logos copied it.")
        }
        pasteboard.clearContents()
        pasteboard.setString(quote, forType: .string)
        if quoteDestination == .obsidian { try pasteInObsidian() }
    }

    /// Pastes the clipboard at the cursor in Obsidian's open note, then brings Logos back.
    func pasteInObsidian() throws {
        guard let obsidian = NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian").first else {
            throw DriverError("Obsidian isn't open. The quote is on the clipboard.")
        }
        obsidian.activate()
        for _ in 0..<40 where !obsidian.isActive { usleep(25_000) }
        guard obsidian.isActive else { throw DriverError("Obsidian didn't come to the front. The quote is on the clipboard.") }
        usleep(150_000)
        try sendKeys("cmd+v", toLogos: false)
        usleep(200_000)
        activateLogos()
    }

    /// The name of the layout Logos is using, from its window title (“Logos Max - Hebrews Study”).
    func activeLayoutName() throws -> String? {
        try prepareAccessibility()
        guard let title: String = attr(try mainWindow(), "AXTitle"), let dash = title.range(of: " - ") else { return nil }
        return String(title[dash.upperBound...])
    }

    /// Opens Logos's Layouts menu and returns the area it covers. The menu opens beside the
    /// sidebar's Layouts icon: saved layouts on the left, and on the right a search box (focused)
    /// over the layout history — the current panels first, then saved layouts, newest first.
    func openLayoutsMenu() throws -> (area: CGRect, button: AXUIElement) {
        // The sidebar's Layouts icon sits near the bottom; a shortcut-bar folder higher up shares its name.
        let buttons = findButtons("Layouts", in: try mainWindow()).compactMap { button in frame(button).map { (button, $0) } }
        guard let (button, icon) = buttons.max(by: { $0.1.minY < $1.1.minY }) else {
            throw DriverError("Couldn't find Logos's Layouts button.")
        }
        activateLogos()
        let menu = CGRect(x: icon.maxX, y: icon.maxY - 700, width: 800, height: 760)
        // The button toggles the menu. If it's already showing, close it first so it reopens with
        // the search box focused.
        if try layoutsMenuIsOpen(menu) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.4)
        }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        // Make sure it's open before typing, so nothing typed can land in a panel.
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.2)
            if try layoutsMenuIsOpen(menu) { return (menu, button) }
        }
        throw DriverError("Logos's Layouts menu didn't open.")
    }

    func layoutsMenuIsOpen(_ menu: CGRect) throws -> Bool {
        try locate("Close active layout", in: menu) != nil
    }

    /// Saves the current panels as a named layout. Reusing the active layout's name updates it.
    func saveLayout(_ name: String) throws {
        // Updating the active layout has a shortcut (Update active, ⌃⌥⌘L); a new name needs the menu.
        if let active = try activeLayoutName(), active.caseInsensitiveCompare(name) == .orderedSame {
            let before = saveMarker(for: active)
            try sendKeys("ctrl+opt+cmd+l")
            for _ in 0..<8 {
                Thread.sleep(forTimeInterval: 0.25)
                if saveMarker(for: active) != before { return }
            }
            log("Update active (⌃⌥⌘L) saved nothing; saving through the Layouts menu")
        }
        let (menu, button) = try openLayoutsMenu()
        guard let save = try locate("Save as named layout", in: menu) else {
            try sendKeys("escape")
            throw DriverError("Couldn't see “Save as named layout” in the Layouts menu.")
        }
        press(save)   // turns into a name box
        Thread.sleep(forTimeInterval: 0.3)
        typeText(name)
        Thread.sleep(forTimeInterval: 0.2)
        try sendKeys("return")
        // After saving, Escape no longer closes the menu; its button toggles it shut.
        Thread.sleep(forTimeInterval: 0.6)
        if try layoutsMenuIsOpen(menu) { AXUIElementPerformAction(button, kAXPressAction as CFString) }
    }

    /// Names of saved layouts, most recently saved first, read from Logos's own layouts database.
    /// Leaves out the unnamed history snapshots and Logos's automatic "Application Closed" saves.
    func savedLayoutNames(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return queryLayouts("""
            SELECT Title, MAX(CreatedDate) AS Saved FROM Layouts
            WHERE IsDeleted = 0 AND Title <> '' AND Title <> 'Application Closed'
            GROUP BY Title ORDER BY Saved DESC LIMIT ?
            """, "\(limit)")
    }

    /// Changes whenever Logos saves a layout under `name`, whether it adds a row or rewrites one.
    func saveMarker(for name: String) -> String? {
        queryLayouts("""
            SELECT COUNT(*) || ' ' || IFNULL(MAX(LayoutId), '') || ' ' || IFNULL(MAX(CreatedDate), '') || ' ' || IFNULL(MAX(SyncDate), '')
                || ' ' || IFNULL(SUM(SyncState), '') || ' ' || IFNULL(SUM(LENGTH(Xml)), '')
            FROM Layouts WHERE IsDeleted = 0 AND Title = ?
            """, name).first
    }

    /// Runs a read-only query on Logos's layouts database and returns the first column of each row.
    private func queryLayouts(_ sql: String, _ parameters: String...) -> [String] {
        let documents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Logos4/Documents")
        // One folder per signed-in account; use the one Logos wrote to last.
        let databases = ((try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("LayoutManager/layouts.db") }
            .compactMap { url -> (URL, Date)? in
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (url, modified)
            }
        guard let path = databases.max(by: { $0.1 < $1.1 })?.0.path else { return [] }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            log("Couldn't open Logos's layouts: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            log("Couldn't read Logos's layouts: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        // SQLITE_TRANSIENT: SQLite copies the text, since Swift's string buffer doesn't outlive the call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { rows.append(String(cString: text)) }
        }
        return rows
    }

    /// Opens a saved layout: searches for it in Logos's Layouts menu and clicks the newest match.
    func openLayout(_ name: String) throws {
        let menu = try openLayoutsMenu().area
        typeText(name)

        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.25)
            // The topmost match is what was typed into the search box.
            guard let search = try locateAll(name, in: menu).min(by: { $0.rect.minY < $1.rect.minY })?.rect else { continue }
            // Each save is its own result, newest first, and Logos can leave the list scrolled with
            // the top row cut off, so go by the topmost result whose name is showing.
            let results = CGRect(x: search.minX, y: search.maxY + 10, width: 560, height: max(menu.maxY - search.maxY - 10, 0))
            let hits = try locateAll(name, in: results)
            guard let row = (hits.filter(\.whole).isEmpty ? hits : hits.filter(\.whole))
                .min(by: { $0.rect.minY < $1.rect.minY })?.rect else { continue }
            // Clicking the name offers Rename and Delete; clicking the thumbnail beside it opens the layout.
            // Logos can miss a click that comes before the row's hover highlight, so rest on it first,
            // and click again while the menu is still open.
            let thumbnail = CGPoint(x: search.minX + 80, y: row.midY)
            for _ in 0..<3 {
                click(at: thumbnail, hover: 200_000)
                // Logos shows the open layout's name in its window title.
                for _ in 0..<8 {
                    Thread.sleep(forTimeInterval: 0.25)
                    if let active = try activeLayoutName(), active.caseInsensitiveCompare(name) == .orderedSame { return }
                }
                guard try layoutsMenuIsOpen(menu) else { break }
                log("Opening “\(name)”: Logos didn't take the click; clicking again")
            }
            if try layoutsMenuIsOpen(menu) { try sendKeys("escape") }
            throw DriverError("Clicked “\(name)” in the Layouts menu, but Logos didn't switch to it.")
        }
        let seen = visibleText(in: menu)
        try sendKeys("escape")
        throw DriverError("No saved layout called “\(name)”. The Layouts menu shows: \(seen.prefix(300))")
    }

    // MARK: Diagnostics

    func describeActivePanel() throws -> String {
        try prepare()
        let all = try panels()
        let active = try activePanel()
        var lines = ["tab strips: " + ((try? tabStrips()) ?? []).map { "\($0)" }.joined(separator: ", "), "panels: " + all.map { "\($0.area)" }.joined(separator: ", "), "active ribbon: \(active.ribbon)"]
        lines.append("tab row: " + visibleText(in: active.tabRow))
        if let row = active.buttonRow { lines.append("button row: " + visibleText(in: row)) }
        lines.append("active tab strip: " + ((try? activeTabStrip()).map { "\($0.orange)" } ?? "not found"))
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
