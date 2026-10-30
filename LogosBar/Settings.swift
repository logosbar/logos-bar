// LogosBar's settings: the stored preferences and the Settings window that edits them.

import Cocoa
import SwiftUI

/// Where the toolbar lives: floating anywhere, docked in the menu bar just after Logos's Help menu,
/// or floating just above the orange strip on the active Logos panel's tab.
enum Placement: String {
    case floating, menuBar, abovePanel
}

/// The docked bar's look: a dark pill with white icons, or a light pill with dark icons.
enum DockedStyle: String {
    case dark, light
}

/// How big the floating toolbar is drawn. The docked bar always fits the menu bar.
enum ToolbarSize: String, CaseIterable {
    case standard, large, giant

    var scale: CGFloat {
        switch self {
        case .standard: 1
        case .large: 1.5
        case .giant: 2
        }
    }

    var title: String {
        switch self {
        case .standard: "Default"
        case .large: "Large"
        case .giant: "Giant"
        }
    }
}

/// Everything the Settings window can change. Each change is saved and then handed to `changed`
/// so the toolbar can redraw itself.
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard
    var changed: () -> Void = {}

    @Published var placement: Placement {
        didSet { defaults.set(placement.rawValue, forKey: "placement"); changed() }
    }
    @Published var dockedStyle: DockedStyle {
        didSet { defaults.set(dockedStyle.rawValue, forKey: "dockedStyle"); changed() }
    }
    @Published var vertical: Bool {
        didSet { defaults.set(vertical, forKey: "vertical"); changed() }
    }
    @Published var size: ToolbarSize {
        didSet { defaults.set(size.rawValue, forKey: "size"); changed() }
    }
    /// Close Logos's ribbon button row again after a LogosBar button had to open it.
    @Published var collapseRibbon: Bool {
        didSet { defaults.set(collapseRibbon, forKey: "collapseRibbon") }
    }
    /// How many recently saved layouts the Layouts button's menu lists (0–5).
    @Published var recentLayoutCount: Int {
        didSet { defaults.set(recentLayoutCount, forKey: "recentLayoutCount") }
    }
    @Published var onlyWithLogos: Bool {
        didSet { defaults.set(!onlyWithLogos, forKey: "alwaysVisible"); changed() }
    }
    /// The toolbar's buttons in display order; turned-off buttons stay in the list, hidden from the bar.
    @Published var actions: [Action] {
        didSet { saveActions(actions); changed() }
    }

    init() {
        placement = Placement(rawValue: defaults.string(forKey: "placement") ?? "") ?? .floating
        dockedStyle = DockedStyle(rawValue: defaults.string(forKey: "dockedStyle") ?? "") ?? .dark
        vertical = defaults.bool(forKey: "vertical")
        size = ToolbarSize(rawValue: defaults.string(forKey: "size") ?? "") ?? .standard
        collapseRibbon = defaults.object(forKey: "collapseRibbon") as? Bool ?? true
        onlyWithLogos = !defaults.bool(forKey: "alwaysVisible")
        recentLayoutCount = defaults.object(forKey: "recentLayoutCount") as? Int ?? 3
        actions = loadActions()
    }

    /// Re-reads actions.json after it was edited by hand, without writing it back.
    func reloadActions() {
        let saved = changed
        changed = {}
        actions = loadActions()
        changed = saved
        changed()
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Placement") {
                Picker("Toolbar", selection: $prefs.placement) {
                    Text("Floating toolbar").tag(Placement.floating)
                    Text("In the menu bar, after Help").tag(Placement.menuBar)
                    Text("Floating above the active Logos panel").tag(Placement.abovePanel)
                }
                .pickerStyle(.radioGroup)
            }

            Section("In the menu bar") {
                Picker("Style", selection: $prefs.dockedStyle) {
                    Text("Dark pill, white icons").tag(DockedStyle.dark)
                    Text("Light pill, dark icons").tag(DockedStyle.light)
                }
                .pickerStyle(.radioGroup)
            }
            .disabled(prefs.placement != .menuBar)

            Section("Floating toolbar") {
                Picker("Layout", selection: $prefs.vertical) {
                    Text("Horizontal").tag(false)
                    Text("Vertical").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("Size", selection: $prefs.size) {
                    ForEach(ToolbarSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show only when Logos is active", isOn: $prefs.onlyWithLogos)
            }
            .disabled(prefs.placement == .menuBar)

            Section {
                Toggle("Collapse Logos’s toolbar after using it", isOn: $prefs.collapseRibbon)
            } header: {
                Text("Logos toolbar")
            } footer: {
                Text("When a button has to open a row of Logos’s toolbar (for page numbers or visual filters), close it again afterwards. A row you opened yourself is left open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Recent layouts to list", selection: $prefs.recentLayoutCount) {
                    ForEach(0...5, id: \.self) { Text("\($0)").tag($0) }
                }
            } header: {
                Text("Layouts button")
            } footer: {
                Text("The layouts you saved most recently in Logos, listed in the Layouts button’s menu between Save Current Layout and Open Other Layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                List {
                    ForEach($prefs.actions) { $action in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $action.isEnabled).labelsHidden()
                            Image(systemName: action.symbol)
                                .symbolRenderingMode(.monochrome)
                                .frame(width: 22)
                            Text(action.label)
                                .foregroundStyle(action.isEnabled ? .primary : .secondary)
                            Spacer()
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .help("Drag to reorder")
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { prefs.actions.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(height: CGFloat(prefs.actions.count) * 30 + 12)
            } header: {
                Text("Buttons")
            } footer: {
                Text("Tick the buttons to show. Drag rows to change their order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Owns the single Settings window and brings it forward on request.
final class SettingsWindowController {
    private var window: NSWindow?
    private let prefs: Preferences

    init(prefs: Preferences) { self.prefs = prefs }

    var frame: NSRect? { window?.frame }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(prefs: prefs)))
            window.title = "LogosBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
