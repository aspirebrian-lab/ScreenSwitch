import Cocoa
import ApplicationServices

// ScreenSwitch: when you click a window that belongs to a non-focused app,
// macOS spends the first click on focusing. We let that click through, then
// replay the same click once the app is active, so it behaves like Windows.

let replayMarker: Int64 = 0x53535731  // "SSW1": tags our synthetic clicks
let scrollMarker: Int64 = 0x53535732  // "SSW2": tags our synthetic scroll events

enum Settings {
    static let delayKey = "replayDelayMs"
    static let defaultDelayMs = 120.0
    static let delayRangeMs = 0.0...500.0

    static var delayMs: Double {
        get { UserDefaults.standard.object(forKey: delayKey) as? Double ?? defaultDelayMs }
        set { UserDefaults.standard.set(newValue, forKey: delayKey) }
    }

    static let smoothScrollingKey = "smoothScrolling"
    static var smoothScrolling: Bool {
        get { UserDefaults.standard.bool(forKey: smoothScrollingKey) }
        set { UserDefaults.standard.set(newValue, forKey: smoothScrollingKey) }
    }

    static let keepGlideKey = "keepGlideInWindow"
    static var keepGlideInWindow: Bool {
        get { UserDefaults.standard.bool(forKey: keepGlideKey) }
        set { UserDefaults.standard.set(newValue, forKey: keepGlideKey) }
    }

    static let smoothnessKey = "smoothnessMs"
    static let defaultSmoothnessMs = 150.0
    static let smoothnessRangeMs = 50.0...400.0
    static var smoothnessMs: Double {
        get { UserDefaults.standard.object(forKey: smoothnessKey) as? Double ?? defaultSmoothnessMs }
        set { UserDefaults.standard.set(newValue, forKey: smoothnessKey) }
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

/// Owner pid of the topmost normal window under a point (global, top-left based coordinates).
func topWindowOwnerPid(at point: CGPoint) -> pid_t? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    for w in list {  // ordered front to back
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.contains(point),
              let pid = w[kCGWindowOwnerPID as String] as? pid_t
        else { continue }
        return pid
    }
    return nil
}

/// Owner pid of whatever window is on top under a point, at any level (panels, popovers,
/// floating windows): the window that scroll events actually go to.
func scrollTargetPid(at point: CGPoint) -> pid_t? {
    guard let primary = NSScreen.screens.first else { return nil }
    let cocoaPoint = NSPoint(x: point.x, y: primary.frame.height - point.y)
    let number = NSWindow.windowNumber(at: cocoaPoint, belowWindowWithWindowNumber: 0)
    guard number > 0,
          let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]])?.first
    else { return nil }
    return info[kCGWindowOwnerPID as String] as? pid_t
}

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
              let pid = topWindowOwnerPid(at: point),
              pid != front, pid != getpid()
        else { return nil }
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           Settings.excludedApps.contains(id) { return nil }
        return front
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

/// Turns the stepped scrolling of a mouse wheel into smooth, eased pixel scrolling
/// (like a trackpad). Trackpad and other continuous scroll events pass through untouched.
final class SmoothScroller: NSObject {
    var tap: CFMachPort?
    private var remainingX = 0.0
    private var remainingY = 0.0
    private var flags: CGEventFlags = []
    // The app under the cursor when the wheel was turned; the glide only ever scrolls that app.
    private var targetPid: pid_t = 0
    private var location = CGPoint.zero
    private var displayLink: CADisplayLink?
    private var fallbackTimer: DispatchSourceTimer?
    private var lastTick = CFAbsoluteTimeGetCurrent()
    // Private source: our synthetic events don't mix with the real mouse's state.
    private let source = CGEventSource(stateID: .privateState)
    private let pixelsPerLine = 40.0

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard Settings.smoothScrolling,
              event.getIntegerValueField(.eventSourceUserData) != scrollMarker,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        else { return Unmanaged.passUnretained(event) }

        let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        guard dx != 0 || dy != 0 else { return Unmanaged.passUnretained(event) }

        let point = event.location
        let pid: pid_t
        if isRunning, point == location {
            pid = targetPid
        } else if let found = scrollTargetPid(at: point) {
            pid = found
        } else {
            return Unmanaged.passUnretained(event)
        }
        if isRunning, pid != targetPid {  // you started scrolling somewhere else: drop the old glide
            remainingX = 0
            remainingY = 0
            endGesture()
        }
        targetPid = pid
        location = point
        remainingY += dy * pixelsPerLine
        remainingX += dx * pixelsPerLine
        flags = event.flags
        startTimer()
        return nil  // swallow the stepped event; we emit smooth ones instead
    }

    private var isRunning: Bool { displayLink != nil || fallbackTimer != nil }

    /// Ticks in sync with the screen's refresh rate so the glide looks even.
    private func startTimer() {
        guard !isRunning else { return }
        lastTick = CFAbsoluteTimeGetCurrent()
        if #available(macOS 14.0, *) {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let link = screen?.displayLink(target: self, selector: #selector(displayTick)) {
                link.add(to: .main, forMode: .common)
                displayLink = link
                return
            }
        }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(8))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        fallbackTimer = t
    }

    private func stopTimer() {
        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    @objc private func displayTick() { tick() }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        // Exponential ease-out: the larger the smoothness, the longer the glide.
        let tau = Settings.smoothnessMs / 1000 / 3
        let k = 1 - exp(-dt / tau)

        let keepInWindow = Settings.keepGlideInWindow
        // Without a gesture, scroll events go to the window under the cursor. So if the cursor
        // has moved onto another app, end the glide instead of scrolling that app.
        if !keepInWindow, let cursor = CGEvent(source: nil)?.location, cursor != location {
            location = cursor
            if scrollTargetPid(at: cursor) != targetPid {
                remainingX = 0
                remainingY = 0
                stopTimer()
                return
            }
        }

        let y = Self.step(&remainingY, k)
        let x = Self.step(&remainingX, k)
        if x != 0 || y != 0 {
            if keepInWindow {
                postScroll(y: y, x: x, phase: inGesture ? .changed : .began)
                inGesture = true
            } else {
                postScroll(y: y, x: x, phase: nil)
            }
        }
        if remainingX == 0 && remainingY == 0 {
            endGesture()
            stopTimer()
        }
    }

    // With "keep gliding in window" on, each glide is sent as one scroll gesture like a
    // trackpad (began → changed → ended). macOS keeps a gesture latched to the window it
    // started in, so the glide keeps going there even when the cursor moves onto another app.
    // The catch: apps then also rubber-band past their edges, like with a trackpad.
    private var inGesture = false

    private func endGesture() {
        guard inGesture else { return }
        postScroll(y: 0, x: 0, phase: .ended)
        inGesture = false
    }

    private func postScroll(y: Int32, x: Int32, phase: CGScrollPhase?) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: y, wheel2: x, wheel3: 0) else { return }
        // No explicit location: that would move the cursor.
        e.flags = flags
        if let phase {
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        e.setIntegerValueField(.eventSourceUserData, value: scrollMarker)
        e.post(tap: .cghidEventTap)
    }

    /// Consumes a fraction of what's left and returns whole pixels to scroll now.
    private static func step(_ remaining: inout Double, _ k: Double) -> Int32 {
        guard abs(remaining) >= 0.5 else { remaining = 0; return 0 }
        var s = (remaining * k).rounded()
        if s == 0 { s = remaining > 0 ? 1 : -1 }
        if abs(s) > abs(remaining) { s = remaining.rounded() }
        remaining -= s
        return Int32(s)
    }
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource {
    private let slider = NSSlider(value: Settings.delayMs, minValue: Settings.delayRangeMs.lowerBound,
                                  maxValue: Settings.delayRangeMs.upperBound, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let smoothCheckbox = NSButton(checkboxWithTitle: "Smooth scrolling for mouse wheels", target: nil, action: nil)
    private let smoothSlider = NSSlider(value: Settings.smoothnessMs, minValue: Settings.smoothnessRangeMs.lowerBound,
                                        maxValue: Settings.smoothnessRangeMs.upperBound, target: nil, action: nil)
    private let smoothLabel = NSTextField(labelWithString: "")
    private let keepGlideCheckbox = NSButton(checkboxWithTitle: "Keep gliding in the original window when the cursor leaves it",
                                             target: nil, action: nil)

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

        let smoothHeading = NSTextField(labelWithString: "Scrolling")
        smoothHeading.font = .boldSystemFont(ofSize: 13)
        smoothCheckbox.target = self
        smoothCheckbox.action = #selector(smoothToggled)
        smoothSlider.target = self
        smoothSlider.action = #selector(smoothnessChanged)
        smoothLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        smoothLabel.alignment = .right
        smoothLabel.setContentHuggingPriority(.required, for: .horizontal)
        smoothLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let smoothRow = NSStackView(views: [NSTextField(labelWithString: "Smoothness"), smoothSlider, smoothLabel])
        smoothRow.spacing = 10
        keepGlideCheckbox.target = self
        keepGlideCheckbox.action = #selector(keepGlideToggled)
        let keepGlideHint = NSTextField(wrappingLabelWithString:
            "Scrolls like a trackpad, so pages can briefly stretch past their edges. "
            + "When off, the glide stops as soon as the cursor moves onto another app.")
        keepGlideHint.font = .systemFont(ofSize: 11)
        keepGlideHint.textColor = .secondaryLabelColor

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
                                        smoothHeading, smoothCheckbox, smoothRow, keepGlideCheckbox, keepGlideHint,
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
        smoothCheckbox.state = Settings.smoothScrolling ? .on : .off
        smoothSlider.doubleValue = Settings.smoothnessMs
        smoothSlider.isEnabled = Settings.smoothScrolling
        keepGlideCheckbox.state = Settings.keepGlideInWindow ? .on : .off
        keepGlideCheckbox.isEnabled = Settings.smoothScrolling
        smoothLabel.stringValue = "\(Int(Settings.smoothnessMs)) ms"
        slider.doubleValue = Settings.delayMs
        valueLabel.stringValue = "\(Int(Settings.delayMs)) ms"
    }

    @objc private func sliderChanged() {
        Settings.delayMs = (slider.doubleValue / 10).rounded() * 10  // steps of 10 ms
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

    @objc private func smoothToggled() {
        Settings.smoothScrolling = smoothCheckbox.state == .on
        refresh()
    }

    @objc private func keepGlideToggled() {
        Settings.keepGlideInWindow = keepGlideCheckbox.state == .on
        refresh()
    }

    @objc private func smoothnessChanged() {
        Settings.smoothnessMs = (smoothSlider.doubleValue / 10).rounded() * 10
        refresh()
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
    let scroller = SmoothScroller()
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!
    var excludeItem: NSMenuItem!
    var smoothItem: NSMenuItem!
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
        smoothItem = NSMenuItem(title: "Smooth Scrolling", action: #selector(toggleSmoothScrolling), keyEquivalent: "")
        menu.addItem(smoothItem)
        menu.delegate = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ScreenSwitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        requestAccessAndStart()
    }

    /// The menu bar icon doesn't steal focus, so "frontmost" is the app you were just using.
    func menuNeedsUpdate(_ menu: NSMenu) {
        smoothItem.state = Settings.smoothScrolling ? .on : .off
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

    @objc func toggleSmoothScrolling() { Settings.smoothScrolling.toggle() }

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
        let clickMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue)
        let clickCallback: CGEventTapCallBack = { _, type, event, refcon in
            let replayer = Unmanaged<ClickReplayer>.fromOpaque(refcon!).takeUnretainedValue()
            return replayer.handle(type: type, event: event)
        }
        guard let clickTap = Self.makeTap(mask: clickMask, options: .listenOnly, callback: clickCallback,
                                          owner: replayer) else { return false }
        replayer.tap = clickTap

        // Scrolling needs an active tap (it replaces events), but only sees scroll events.
        let scrollMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let scrollCallback: CGEventTapCallBack = { _, type, event, refcon in
            let scroller = Unmanaged<SmoothScroller>.fromOpaque(refcon!).takeUnretainedValue()
            return scroller.handle(type: type, event: event)
        }
        scroller.tap = Self.makeTap(mask: scrollMask, options: .defaultTap, callback: scrollCallback, owner: scroller)
        return true
    }

    private static func makeTap(mask: CGEventMask, options: CGEventTapOptions,
                                callback: @escaping CGEventTapCallBack, owner: AnyObject) -> CFMachPort? {
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: options, eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(owner).toOpaque())
        else { return nil }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return tap
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
