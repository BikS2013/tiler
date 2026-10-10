import AppKit
import Combine
import ServiceManagement
import SwiftUI
import TilerCore

/// Settings state. The config file stays the single source of truth: every
/// change is written to it (validated first) and applied at once, the way
/// macOS settings apply without a Save button.
final class SettingsModel: ObservableObject {
    let controller: Controller
    @Published private(set) var config: Config
    @Published private(set) var configError: String?
    @Published private(set) var saveError: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var accessibilityGranted = false
    @Published var recording: Action? {
        didSet { controller.hotkeysSuspended = recording != nil }
    }
    @Published var conflict: (action: Action, with: Action)?

    init(controller: Controller) {
        self.controller = controller
        config = controller.config ?? Config.defaults
        refresh()
    }

    /// Re-read everything Settings shows (after a reload, or when the window opens).
    func refresh() {
        if let c = controller.config, c != config { config = c }
        configError = controller.configError
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Editing is off while the file on disk has an error, so a change in
    /// Settings never silently overwrites what the user is fixing by hand.
    var editable: Bool { configError == nil && controller.config != nil }

    func update(_ change: (inout Draft) -> Void) {
        var d = Draft(config)
        change(&d)
        let next = d.config
        guard next != config else { return }
        do {
            try controller.save(next)
            saveError = nil
        } catch {
            saveError = (error as? ConfigError)?.description ?? error.localizedDescription
        }
        refresh()
    }

    func bind(_ action: Action, to combo: KeyCombo?) {
        if let combo, let other = config.conflicts(combo, for: action).first {
            conflict = (action, other)
            NSSound.beep()
            return
        }
        conflict = nil
        update { $0.hotkeys[action] = combo }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("launch at login: \(error.localizedDescription)")
            NSSound.beep()
        }
        refresh()
    }

    func restoreDefaults() {
        controller.restoreDefaultConfig()
        refresh()
    }

    func restoreDefaultShortcuts() { update { $0.hotkeys = Config.defaults.hotkeys } }

    /// A mutable copy of `Config`.
    struct Draft {
        var innerGap, outerGap, resizeStep: Double
        var floatingApps: Set<String>
        var hotkeys: [Action: KeyCombo]
        init(_ c: Config) {
            innerGap = c.innerGap; outerGap = c.outerGap; resizeStep = c.resizeStep
            floatingApps = c.floatingApps; hotkeys = c.hotkeys
        }
        var config: Config {
            Config(innerGap: innerGap, outerGap: outerGap, resizeStep: resizeStep, floatingApps: floatingApps, hotkeys: hotkeys)
        }
    }
}

/// The Settings window: a standard macOS preferences window with a toolbar
/// of panes, each one a grouped SwiftUI form.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel

    enum Pane: Int { case general, layout, shortcuts, apps }

    init(controller: Controller) {
        let model = SettingsModel(controller: controller)
        self.model = model
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func pane<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: view.environmentObject(model))
            host.sizingOptions = .preferredContentSize
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        pane("General", "gearshape", GeneralPane())
        pane("Layout", "rectangle.split.2x1", LayoutPane())
        pane("Shortcuts", "keyboard", ShortcutsPane())
        pane("Apps", "macwindow.on.rectangle", AppsPane())

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.collectionBehavior = [.moveToActiveSpace]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ pane: Pane? = nil) {
        model.refresh()
        if let pane, let tabs = window?.contentViewController as? NSTabViewController {
            tabs.selectedTabViewItemIndex = pane.rawValue
        }
        if window?.isVisible != true { window?.center() }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // macOS 14+ ignores activate() unless it follows a click in this app
        // (a second launch or `tiler-ctl.sh settings` is not one): bring the
        // window forward the way the focus shortcuts do.
        if let w = window, !NSApp.isActive { focusWindow(pid: getpid(), wid: CGWindowID(w.windowNumber)) }
    }

    func windowWillClose(_ notification: Notification) { model.recording = nil }
    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }
}

// MARK: Panes

/// Explanatory text under a settings group, aligned with the group's labels.
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConfigErrorBanner: View {
    @EnvironmentObject var model: SettingsModel
    var body: some View {
        if let error = model.configError {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The configuration file has an error").font(.headline)
                        Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Fix the file and choose Reload, or restore the defaults. Settings can’t be edited until then.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                HStack {
                    Button("Open in Editor") { NSWorkspace.shared.open(Controller.configURL) }
                    Button("Reload") { model.controller.reloadConfig(); model.refresh() }
                    Spacer()
                    Button("Restore Defaults") { model.restoreDefaults() }
                }
            }
        }
        if let error = model.saveError {
            Section { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
        }
    }
}

private struct GeneralPane: View {
    @EnvironmentObject var model: SettingsModel
    @State private var confirmRestore = false

    var body: some View {
        Form {
            ConfigErrorBanner()
            Section {
                Toggle("Launch Tiler at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            Section {
                LabeledContent("Accessibility") {
                    if model.accessibilityGranted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Privacy & Security…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Footnote("Tiler moves and resizes windows through the Accessibility API. It needs no other permission.")
            }
            Section("Tiled Desktops") {
                LabeledContent("Currently tiled", value: tiledText)
                Text("Turn tiling on or off from the menu bar, or with \(model.config.hotkeys[.toggleDesktop]?.symbols ?? "the Tile This Desktop shortcut") on the desktop you want. Each desktop on each display is separate.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Configuration File") {
                LabeledContent("Location") {
                    Text(Controller.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Controller.configURL]) }
                    Button("Reload") { model.controller.reloadConfig(); model.refresh() }
                    Spacer()
                    Button("Restore Defaults…") { confirmRestore = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Restore the default settings?", isPresented: $confirmRestore) {
            Button("Restore Defaults", role: .destructive) { model.restoreDefaults() }
        } message: {
            Text("Gaps, shortcuts and floating apps go back to their defaults. Tiled desktops stay tiled.")
        }
    }

    private var tiledText: String {
        let n = model.controller.desktops.count
        return n == 0 ? "None" : "\(n) desktop\(n == 1 ? "" : "s")"
    }
}

private struct LayoutPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Form {
            ConfigErrorBanner()
            Section {
                PointsSlider(title: "Between windows", value: model.config.innerGap, range: 0...48) { v in
                    model.update { $0.innerGap = v }
                }
                PointsSlider(title: "Around the screen edges", value: model.config.outerGap, range: 0...64) { v in
                    model.update { $0.outerGap = v }
                }
            } header: {
                Text("Gaps")
            } footer: {
                Footnote("Changes apply to every tiled desktop as soon as you let go of the slider.")
            }
            Section {
                PercentSlider(title: "Resize step", value: model.config.resizeStep, range: 0.01...0.25) { v in
                    model.update { $0.resizeStep = v }
                }
            } header: {
                Text("Keyboard Resizing")
            } footer: {
                Footnote("How far one press of a resize shortcut moves a divider, as a share of the split.")
            }
        }
        .formStyle(.grouped)
        .disabled(!model.editable)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A slider that shows its value while dragging and commits once on release.
private struct PointsSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var live: Double?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { live ?? value }, set: { live = $0.rounded() }),
                       in: range.lowerBound...max(range.upperBound, value)) { editing in
                    if !editing, let v = live { commit(v); live = nil }
                }
                .frame(width: 200)
                Stepper(value: Binding(get: { live ?? value }, set: { commit($0) }),
                        in: range.lowerBound...max(range.upperBound, value), step: 1) {
                    Text("\(Int(live ?? value)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
}

private struct PercentSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var live: Double?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { live ?? value }, set: { live = ($0 * 100).rounded() / 100 }),
                       in: range.lowerBound...max(range.upperBound, value)) { editing in
                    if !editing, let v = live { commit(v); live = nil }
                }
                .frame(width: 200)
                Text("\(Int(((live ?? value) * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        }
    }
}

private struct ShortcutsPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Form {
            ConfigErrorBanner()
            ForEach(Action.Group.allCases, id: \.self) { group in
                Section {
                    ForEach(Action.allCases.filter { $0.group == group }, id: \.self) { action in
                        LabeledContent(action.title) { ShortcutRecorder(action: action) }
                    }
                } header: {
                    Text(group.rawValue)
                } footer: {
                    if group == .general {
                        Footnote("These two work on every desktop. All other shortcuts work only while a tiled desktop has focus, so apps keep the same keys everywhere else.")
                    }
                }
            }
            Section {
                HStack {
                    Text("Click a shortcut, then press the new keys. Press Delete to clear it, Esc to cancel.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { model.restoreDefaultShortcuts() }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!model.editable)
        .frame(width: 560, height: 620)
    }
}

/// Click, then press a combination. Esc cancels, Delete clears. A combination
/// already bound to another action is refused with a note naming it.
private struct ShortcutRecorder: View {
    @EnvironmentObject var model: SettingsModel
    let action: Action
    @State private var monitor: Any?

    private var isRecording: Bool { model.recording == action }

    var body: some View {
        HStack(spacing: 6) {
            if let c = model.conflict, c.action == action {
                Text("Used by “\(c.with.title)”").font(.caption).foregroundStyle(.red)
            }
            Button(action: { isRecording ? stop() : start() }) {
                Group {
                    if isRecording {
                        Text("Type shortcut…").foregroundStyle(Color.accentColor)
                    } else {
                        KeyCaps(combo: model.config.hotkeys[action])
                    }
                }
                .frame(minWidth: 120, minHeight: 22)
            }
            .buttonStyle(.bordered)
            .help(isRecording ? "Press keys, Esc to cancel, Delete to clear" : "Click to change")
            if model.config.hotkeys[action] != nil && !isRecording {
                Button { model.bind(action, to: nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Clear shortcut")
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .onChange(of: model.recording) { _, now in if now != action { removeMonitor() } }
        .onDisappear { if isRecording { stop() } }
    }

    private func start() {
        model.conflict = nil
        model.recording = action
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard model.recording == action else { return event }
            let code = UInt32(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if code == 0x35 && flags.isEmpty { stop(); return nil }                       // Esc
            if (code == 0x33 || code == 0x75) && flags.isEmpty {                         // Delete
                stop(); model.bind(action, to: nil); return nil
            }
            var mods: UInt32 = 0
            if flags.contains(.control) { mods |= KeyCombo.controlKey }
            if flags.contains(.option) { mods |= KeyCombo.optionKey }
            if flags.contains(.shift) { mods |= KeyCombo.shiftKey }
            if flags.contains(.command) { mods |= KeyCombo.cmdKey }
            guard let combo = KeyCombo(keyCode: code, carbonModifiers: mods) else { NSSound.beep(); return nil }
            stop()
            model.bind(action, to: combo)
            return nil
        }
    }

    private func stop() {
        removeMonitor()
        if model.recording == action { model.recording = nil }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

private struct AppsPane: View {
    @EnvironmentObject var model: SettingsModel
    @State private var selection: String?

    var body: some View {
        Form {
            ConfigErrorBanner()
            Section {
                List(selection: $selection) {
                    ForEach(apps, id: \.self) { id in AppRow(bundleID: id).tag(id) }
                }
                .frame(minHeight: 220)
                .overlay {
                    if apps.isEmpty {
                        Text("No apps. Windows of every app are tiled.").foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 0) {
                    Menu {
                        Section("Running Apps") {
                            ForEach(runningApps, id: \.bundleIdentifier) { app in
                                Button {
                                    add(app.bundleIdentifier!)
                                } label: {
                                    Text(app.localizedName ?? app.bundleIdentifier!)
                                }
                            }
                        }
                        Divider()
                        Button("Choose Application…") { chooseApplication() }
                    } label: {
                        Image(systemName: "plus").frame(width: 20, height: 16)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add an app")
                    Divider().frame(height: 16).padding(.horizontal, 6)
                    Button {
                        if let s = selection { model.update { $0.floatingApps.remove(s) }; selection = nil }
                    } label: {
                        Image(systemName: "minus").frame(width: 20, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil)
                    .help("Remove the selected app")
                    Spacer()
                }
            } header: {
                Text("Always Float")
            } footer: {
                Footnote("Windows of these apps are never tiled: they keep their own size and position. To float a single window instead, use \(model.config.hotkeys[.toggleFloat]?.symbols ?? "the Float shortcut").")
            }
        }
        .formStyle(.grouped)
        .disabled(!model.editable)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var apps: [String] {
        model.config.floatingApps.sorted { AppRow.name(of: $0).localizedCaseInsensitiveCompare(AppRow.name(of: $1)) == .orderedAscending }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && !model.config.floatingApps.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func add(_ id: String) { model.update { $0.floatingApps.insert(id) } }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        model.update { $0.floatingApps.formUnion(ids) }
    }
}

private struct AppRow: View {
    let bundleID: String

    static func url(of id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    static func name(of id: String) -> String {
        url(of: id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }

    var body: some View {
        HStack(spacing: 8) {
            if let url = Self.url(of: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "questionmark.app.dashed").frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.name(of: bundleID))
                Text(bundleID).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
