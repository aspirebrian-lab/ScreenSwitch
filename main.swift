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
            return (pid != front && pid != getpid()) ? front : nil
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

final class SettingsWindowController: NSWindowController {
    private let slider = NSSlider(value: Settings.delayMs, minValue: Settings.delayRangeMs.lowerBound,
                                  maxValue: Settings.delayRangeMs.upperBound, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "")

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

        let stack = NSStackView(views: [heading, sliderRow, hint, buttonRow])
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
        slider.doubleValue = Settings.delayMs
        valueLabel.stringValue = "\(Int(Settings.delayMs)) ms"
    }

    @objc private func sliderChanged() {
        Settings.delayMs = (slider.doubleValue / 10).rounded() * 10  // stappen van 10 ms
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let replayer = ClickReplayer()
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!
    lazy var settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "ScreenSwitch")

        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "Enabled", action: #selector(toggle), keyEquivalent: "")
        toggleItem.state = .on
        menu.addItem(toggleItem)
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ScreenSwitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        requestAccessAndStart()
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
