import Cocoa
import ApplicationServices

// ScreenSwitch: when you click a window that belongs to a non-focused app,
// macOS spends the first click on focusing. We let that click through, then
// replay the same click once the app is active, so it behaves like Windows.

let replayMarker: Int64 = 0x53535731  // "SSW1": tags our synthetic clicks

enum Settings {
    static let delayKey = "replayDelayMs"
    static let defaultDelayMs = 120.0
    static let delayRangeMs = 0.0...500.0

    static var delayMs: Double {
        get { UserDefaults.standard.object(forKey: delayKey) as? Double ?? defaultDelayMs }
        set { UserDefaults.standard.set(newValue, forKey: delayKey) }
    }

    /// Apps that already handle the first click themselves; replaying would double-click.
    static let excludedKey = "excludedBundleIDs"
    static let defaultExcluded = ["com.apple.systempreferences"]

    static var excludedApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: excludedKey) ?? defaultExcluded }
        set { UserDefaults.standard.set(newValue, forKey: excludedKey) }
    }

    static func displayName(forBundleID id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

let dragTolerance: CGFloat = 4

final class ClickReplayer {
    var enabled = true
    var tap: CFMachPort?
    private var pendingDown: (point: CGPoint, frontBefore: pid_t)?

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard enabled, event.getIntegerValueField(.eventSourceUserData) != replayMarker else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            if let front = frontmostPidIfClickIsOnBackgroundApp(at: event.location) {
                pendingDown = (event.location, front)
            } else {
                pendingDown = nil
            }
        case .leftMouseUp:
            if let down = pendingDown {
                pendingDown = nil
                let up = event.location
                // Skip drags (e.g. moving a window by its title bar).
                if hypot(up.x - down.point.x, up.y - down.point.y) <= dragTolerance {
                    let frontBefore = down.frontBefore
                    DispatchQueue.main.asyncAfter(deadline: .now() + Settings.delayMs / 1000) {
                        // Only replay if the click really changed the focused app.
                        // Otherwise the app was already active (some apps own their
                        // windows via a helper process) and we would double-click.
                        let frontNow = NSWorkspace.shared.frontmostApplication?.processIdentifier
                        guard frontNow != frontBefore else { return }
                        Self.postClick(at: up)
                    }
                }
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// If the topmost normal window under the point belongs to an app other than
    /// the frontmost one, returns the pid of the frontmost app.
    private func frontmostPidIfClickIsOnBackgroundApp(at point: CGPoint) -> pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        for w in list {  // ordered front to back
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point),
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            guard pid != front, pid != getpid() else { return nil }
            if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               Settings.excludedApps.contains(id) { return nil }
            return front
        }
        return nil
    }

    private static func postClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { continue }
            e.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: .cghidEventTap)
        }
    }
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource {
    private let slider = NSSlider(value: Settings.delayMs, minValue: Settings.delayRangeMs.lowerBound,
                                  maxValue: Settings.delayRangeMs.upperBound, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 10),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ScreenSwitch Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildContent() {
        let heading = NSTextField(labelWithString: "Delay before the second click")
        heading.font = .boldSystemFont(ofSize: 13)

        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let sliderRow = NSStackView(views: [slider, valueLabel])
        sliderRow.spacing = 10

        let hint = NSTextField(wrappingLabelWithString:
            "How long ScreenSwitch waits after the focusing click before it clicks again. "
            + "Raise it if clicks on slow apps get lost; lower it for a snappier feel.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let reset = NSButton(title: "Reset to Default", target: self, action: #selector(resetToDefault))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, reset])

        let excludedHeading = NSTextField(labelWithString: "Apps that already accept the first click")
        excludedHeading.font = .boldSystemFont(ofSize: 13)
        let excludedHint = NSTextField(wrappingLabelWithString:
            "ScreenSwitch will not click again in these apps. Add an app if clicking a switch or "
            + "checkbox in it as the first click toggles it twice.")
        excludedHint.font = .systemFont(ofSize: 11)
        excludedHint.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.isEditable = false
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 100).isActive = true

        let add = NSButton(title: "Add App…", target: self, action: #selector(addExcludedApp))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeExcludedApp))
        let listButtons = NSStackView(views: [add, remove, NSView()])

        let stack = NSStackView(views: [heading, sliderRow, hint, buttonRow,
                                        excludedHeading, excludedHint, scroll, listButtons])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = window!.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 400),
        ])
        refresh()
    }

    private func refresh() {
        table.reloadData()
        slider.doubleValue = Settings.delayMs
        valueLabel.stringValue = "\(Int(Settings.delayMs)) ms"
    }

    @objc private func sliderChanged() {
        Settings.delayMs = (slider.doubleValue / 10).rounded() * 10  // stappen van 10 ms
        refresh()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { Settings.excludedApps.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        Settings.displayName(forBundleID: Settings.excludedApps[row])
    }

    @objc private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier,
              !Settings.excludedApps.contains(id) else { return }
        Settings.excludedApps.append(id)
        table.reloadData()
    }

    @objc private func removeExcludedApp() {
        let row = table.selectedRow
        guard row >= 0 else { return }
        Settings.excludedApps.remove(at: row)
        table.reloadData()
    }

    @objc private func resetToDefault() {
        Settings.delayMs = Settings.defaultDelayMs
        refresh()
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let replayer = ClickReplayer()
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!
    var excludeItem: NSMenuItem!
    lazy var settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "ScreenSwitch")

        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "Enabled", action: #selector(toggle), keyEquivalent: "")
        toggleItem.state = .on
        menu.addItem(toggleItem)
        excludeItem = NSMenuItem(title: "", action: #selector(toggleExcludeFrontmost), keyEquivalent: "")
        menu.addItem(excludeItem)
        menu.delegate = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ScreenSwitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        requestAccessAndStart()
    }

    /// The menu bar icon doesn't steal focus, so "frontmost" is the app you were just using.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            excludeItem.title = "Don't replay clicks in \(app.localizedName ?? id)"
            excludeItem.state = Settings.excludedApps.contains(id) ? .on : .off
            excludeItem.isEnabled = true
        } else {
            excludeItem.title = "Don't replay clicks in this app"
            excludeItem.state = .off
            excludeItem.isEnabled = false
        }
    }

    @objc func toggleExcludeFrontmost() {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        var list = Settings.excludedApps
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
        Settings.excludedApps = list
    }

    @objc func showSettings() { settingsWindow.show() }

    @objc func toggle() {
        replayer.enabled.toggle()
        toggleItem.state = replayer.enabled ? .on : .off
        statusItem.button?.appearsDisabled = !replayer.enabled
    }

    /// The event tap needs Accessibility (and Input Monitoring) permission;
    /// poll until it's granted so the user doesn't have to relaunch.
    func requestAccessAndStart() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts), startTap() { return }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted(), self?.startTap() == true { timer.invalidate() }
        }
    }

    func startTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let replayer = Unmanaged<ClickReplayer>.fromOpaque(refcon!).takeUnretainedValue()
            return replayer.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(replayer).toOpaque())
        else { return false }
        replayer.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
