// TrackSteer -- two-finger drag becomes a held middle mouse button, in one app.
//
// Why this exists: a mouse-turner in World of Warcraft holds a button and moves
// the mouse to run and steer. A Mac trackpad has no middle button and cannot
// hold right-click while dragging, so that whole style of play is unavailable
// on a laptop. This supplies the missing button.
//
// How it works, and why it is this small:
//
//   * macOS already reports two-finger movement as a scroll event carrying
//     pixel-precise deltas. That IS the gesture, already smoothed and
//     accelerated by the system. So instead of reading raw touch coordinates
//     from the private multitouch API, we intercept the scroll and re-emit it
//     as middle-button drag. The private API is used only to count fingers.
//
//   * Everything is scoped to one application. Two-finger scrolling is far too
//     important to break system-wide, so outside the target app every event is
//     passed through untouched and the process does nothing at all.
//
// Requires Accessibility permission, because posting and intercepting input
// events is exactly what that permission governs.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Configuration

enum Config {
    /// Only act while one of these is frontmost. Two-finger scroll stays normal
    /// everywhere else.
    static var targetBundleIDs: Set<String> = ["com.blizzard.worldofwarcraft"]

    /// Fingers that must be down for the drag.
    static var fingerCount = 2

    /// Master switch, so the gesture can be paused without quitting.
    static var enabled = true

    // Two fingers do two different things depending on pressure:
    //
    //   resting  -> middle button drag = Move and Steer, run while turning
    //   pressed  -> right button drag  = mouselook, turn on the spot
    //
    // Resting is the common case -- you run far more than you pivot -- so it
    // gets the lighter gesture and the better-tested path. If press detection
    // ever misfires you simply move instead of turning, which is a far kinder
    // failure than the reverse.

    /// Scales trackpad movement while running. 1.0 tracks the system's own
    /// trackpad acceleration, which macOS has already applied to the scroll
    /// deltas we read, so the default inherits Apple's tuning.
    static var sensitivity: Double = 1.0

    // MARK: Persistence
    //
    // Read from UserDefaults so the feel can be adjusted without a rebuild:
    //
    //   defaults write com.jthorney.tracksteer sensitivity -float 1.5
    //
    // Re-read periodically rather than only at launch, so a change takes effect
    // while the app keeps running. Polling a handful of values every couple of
    // seconds is far simpler than watching for external defaults changes, which
    // is unreliable across processes.

    // .standard is already this app's own domain, which is exactly where
    // `defaults write com.jthorney.tracksteer ...` lands. Passing the bundle id
    // as a suite name would be a no-op that macOS warns about.
    private static let defaults = UserDefaults.standard

    static func load() {
        if let value = defaults.object(forKey: "sensitivity") as? Double,
            value > 0, value <= 10 {
            sensitivity = value
        }

        if let value = defaults.object(forKey: "fingerCount") as? Int,
            value >= 2, value <= 4 {
            fingerCount = value
        }

        if let value = defaults.array(forKey: "targetBundleIDs") as? [String],
            !value.isEmpty {
            targetBundleIDs = Set(value)
        }

        if let value = defaults.object(forKey: "enabled") as? Bool {
            enabled = value
        }

    }

    static func save() {
        defaults.set(sensitivity, forKey: "sensitivity")
        defaults.set(enabled, forKey: "enabled")

    }

    static var onExternalChange: (() -> Void)?

    static func watch() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            let before = (sensitivity, fingerCount, targetBundleIDs)
            load()
            var changed = before != (sensitivity, fingerCount, targetBundleIDs)
            if changed {
                log("settings changed: sensitivity=\(sensitivity) fingers=\(fingerCount)")
            }

            if changed { onExternalChange?() }
        }
    }
}

// MARK: - MultitouchSupport (private API)
//
// Declarations only -- these describe Apple's private framework so we can count
// fingers. We deliberately never read the touch payload, so the notoriously
// version-dependent MTTouch struct layout is not a concern here.

typealias MTDeviceRef = UnsafeMutableRawPointer

typealias MTContactCallback = @convention(c) (
    MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32

@_silgen_name("MTDeviceCreateList")
func MTDeviceCreateList() -> CFArray?

@_silgen_name("MTRegisterContactFrameCallback")
func MTRegisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTContactCallback)

@_silgen_name("MTDeviceStart")
func MTDeviceStart(_ device: MTDeviceRef, _ mode: Int32)

@_silgen_name("MTDeviceStop")
func MTDeviceStop(_ device: MTDeviceRef)

// MARK: - Shared state
//
// Written from the multitouch thread, read from the event tap. Both are plain
// word-sized values; a stale read costs at most one frame of latency, which is
// not perceptible and not worth a lock in a hot path.

final class State: @unchecked Sendable {
    static let shared = State()

    var fingersDown: Int = 0
    /// Which button we are currently holding down, if any.
    var heldButton: CGMouseButton?
    var targetAppActive = false

    /// The trackpad is physically clicked down.
    var physicalPress = false

    /// Where the drag started. Every synthetic event is reported at this exact
    /// point and it never moves, so the pointer is still where the player left
    /// it when they lift their fingers.
    var anchor: CGPoint = .zero
}

// MARK: - Event generation

enum Mouse {
    static let source = CGEventSource(stateID: .hidSystemState)

    static func press(_ button: CGMouseButton) {
        let state = State.shared
        if state.heldButton == button { return }

        // Switching buttons mid-gesture: let go of the old one first, or WoW
        // sees both held and does something neither was meant to do.
        release()

        state.anchor = currentCursor()
        post(down(button), button: button, delta: .zero)
        state.heldButton = button
    }

    static func release() {
        let state = State.shared
        guard let button = state.heldButton else { return }

        post(up(button), button: button, delta: .zero)
        state.heldButton = nil
        CGWarpMouseCursorPosition(state.anchor)
    }

    static func drag(dx: Double, dy: Double) {
        guard let button = State.shared.heldButton else { return }
        post(dragged(button), button: button, delta: CGPoint(x: dx, y: dy))
    }

    private static func down(_ b: CGMouseButton) -> CGEventType {
        b == .right ? .rightMouseDown : .otherMouseDown
    }
    private static func up(_ b: CGMouseButton) -> CGEventType {
        b == .right ? .rightMouseUp : .otherMouseUp
    }
    private static func dragged(_ b: CGMouseButton) -> CGEventType {
        b == .right ? .rightMouseDragged : .otherMouseDragged
    }

    private static func currentCursor() -> CGPoint {
        guard let event = CGEvent(source: nil) else { return .zero }
        return event.location
    }

    private static func post(_ type: CGEventType, button: CGMouseButton, delta: CGPoint) {
        let state = State.shared

        // Deliberately NOT accumulating a position. A game steers from the delta
        // fields below; reporting a moving location as well would drag the real
        // pointer across the screen while it is hidden, so it would be somewhere
        // else entirely when the player lifts their fingers.
        guard
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: state.anchor,
                mouseButton: button
            )
        else { return }

        if delta != .zero {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        }

        event.post(tap: .cghidEventTap)
    }
}

// MARK: - Finger counting

final class TouchMonitor {
    private var devices: [MTDeviceRef] = []

    /// Called by the system on every touch frame. Records the count and passes
    /// the frame through untouched -- returning non-zero here would swallow
    /// touches system-wide, which we never want.
    private static let callback: MTContactCallback = { _, _, numTouches, _, _ in
        if State.shared.fingersDown != Int(numTouches) {
            debug("fingers -> \(numTouches)")
        }
        State.shared.fingersDown = Int(numTouches)

        // Fingers lifted while dragging: end the drag immediately rather than
        // waiting for another event that may never arrive.
        // Exactly the configured count means drag; anything else ends it. This
        // must cover MORE fingers as well as fewer: landing three fingers passes
        // through two on the way down, which would otherwise press the button
        // and leave it stuck, turning later movement into a drag and stopping
        // three-finger scrolling from working at all.
        if Int(numTouches) != Config.fingerCount && State.shared.heldButton != nil {
            DispatchQueue.main.async { Mouse.release() }
        }
        return 0
    }

    func start() {
        // Read the CFArray through the CoreFoundation API rather than casting
        // it to a Swift array. The bridge cast compiles but always fails at
        // runtime for an array of raw pointers, leaving zero devices and no
        // finger data at all.
        guard let list = MTDeviceCreateList() else {
            log("no multitouch device list returned")
            return
        }

        let count = CFArrayGetCount(list)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            devices.append(device)
            MTRegisterContactFrameCallback(device, TouchMonitor.callback)
            MTDeviceStart(device, 0)
        }

        if devices.isEmpty {
            log("no multitouch devices found")
        } else {
            log("watching \(devices.count) multitouch device(s)")
        }
    }

    func stop() {
        for device in devices {
            MTDeviceStop(device)
        }
        devices.removeAll()
    }
}

// MARK: - Event tap

/// Held globally because the event tap callback is a C function pointer and
/// cannot capture context. Without a handle here we could not re-enable the tap
/// after macOS disables it.
nonisolated(unsafe) var activeTap: CFMachPort?

final class ScrollInterceptor {

    func start() -> Bool {
        // Right-button events are needed for press mode: a two-finger click on
        // a Mac trackpad is a secondary click.
        let mask =
            (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, _ in
                    ScrollInterceptor.handle(type: type, event: event)
                },
                userInfo: nil
            )
        else { return false }

        activeTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private static func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        let state = State.shared

        // macOS disables a tap if a callback ever runs slow, and it stays dead
        // until explicitly re-enabled. Without this the app silently stops
        // working partway through a session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = activeTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                debug("event tap was disabled by the system; re-enabled")
            }
            return passThrough
        }

        // A two-finger click on a Mac trackpad is a secondary click. We watch it
        // to know whether the fingers are pressed or merely resting, which is
        // what selects between turning and moving.
        // Right-button events are watched, never taken. A two-finger press and
        // drag already produces a real right-button drag, which is exactly
        // WoW's own mouselook -- so turning on the spot needs no synthesis at
        // all, and right-click targeting keeps working because we never
        // interfere with it.
        //
        // The earlier version swallowed the button-down to detect pressure,
        // which meant the game never saw the button held and the drags that
        // followed were meaningless to it.
        if type == .rightMouseDown || type == .rightMouseUp || type == .rightMouseDragged {
            if type == .rightMouseDown {
                state.physicalPress = true

                // If we are mid-run, the middle button has to be released
                // BEFORE the game sees the press, or it ends up holding both
                // and Move and Steer wins -- which is why turning worked from a
                // standstill but not while walking.
                //
                // Letting the original through cannot guarantee that order, as
                // our release is injected while this event is still in flight.
                // So swallow it, release, and re-post the press ourselves. The
                // real button-up still passes through and balances it.
                if state.heldButton != nil {
                    Mouse.release()
                    CGEvent(
                        mouseEventSource: Mouse.source, mouseType: .rightMouseDown,
                        mouseCursorPosition: event.location, mouseButton: .right
                    )?.post(tap: .cghidEventTap)
                    return nil
                }
            }
            if type == .rightMouseUp {
                state.physicalPress = false
                Mouse.release()
            }
            return passThrough
        }

        guard type == .scrollWheel else { return passThrough }

        // Outside the target app, or without the right fingers down, this is an
        // ordinary scroll and none of our business.
        debug("scroll: fingers=\(state.fingersDown) target=\(state.targetAppActive) held=\(String(describing: state.heldButton))")

        guard Config.enabled, state.targetAppActive,
            state.fingersDown == Config.fingerCount
        else {
            if state.heldButton != nil { Mouse.release() }
            return passThrough
        }

        // Pixel deltas rather than line deltas: trackpads report continuous
        // movement here, which is what makes this feel like a mouse rather than
        // a series of clicks.
        let dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        let dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))

        // While the trackpad is physically held the game is already turning
        // natively, so stay out of the way.
        guard !state.physicalPress else { return nil }

        Mouse.press(.center)

        // Scroll deltas are inverted relative to pointer movement: scrolling
        // "down" moves content up, but dragging down should move the pointer
        // down.
        Mouse.drag(dx: -dx * Config.sensitivity, dy: -dy * Config.sensitivity)

        // Swallow it, so the game does not also receive a scroll.
        return nil
    }
}

// MARK: - App scoping

final class AppScope {
    private var observer: NSObjectProtocol?

    /// Lets the menu refresh when focus changes, so its status stays true.
    var onChange: (() -> Void)?

    func start() {
        update()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.update()
        }
    }

    private func update() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let active = Config.targetBundleIDs.contains(bundleID)
        State.shared.targetAppActive = active
        onChange?()

        // Never leave the button stuck down when switching away mid-drag.
        if !active && State.shared.heldButton != nil {
            Mouse.release()
        }
    }
}

// MARK: - Menu bar
//
// The only reason this app has any UI: turn speed has to be adjustable by
// someone who will never open Terminal. Presets rather than a slider, because
// four named choices are easier to reason about than a number, and the useful
// range here is narrow.

final class MenuBar: NSObject {
    private var statusItem: NSStatusItem?

    private static let speeds: [(String, Double)] = [
        ("Slow", 0.6),
        ("Normal", 1.0),
        ("Fast", 1.5),
        ("Faster", 2.0),
    ]

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Always give the button a title. If the symbol name is ever wrong the
        // image is nil, and a status item with neither image nor title has zero
        // width -- it is running and completely invisible, which is the worst
        // possible failure for a menu bar app.
        // A text label rather than a symbol. The icon version was reported as
        // invisible even though the system said it was there with real
        // geometry, and a menu bar item nobody can find is worth nothing --
        // legibility beats elegance here.
        item.button?.title = "TS"

        statusItem = item
        rebuild()
        log("menu bar item created")
    }

    /// Rebuilt on every change so the ticks always match reality, rather than
    /// tracking menu item state separately and letting the two drift.
    func rebuild() {
        let menu = NSMenu()

        let trusted = AXIsProcessTrusted()

        // Report the actual reason it is idle. Silently doing nothing while
        // claiming to be "on" is what made this look broken twice: once for a
        // revoked permission, once because another app had focus.
        let statusText: String
        if !trusted {
            statusText = "Needs Accessibility permission"
        } else if !Config.enabled {
            statusText = "TrackSteer is paused"
        } else if !State.shared.targetAppActive {
            statusText = "Waiting — World of Warcraft isn't frontmost"
        } else {
            statusText = "TrackSteer is active"
        }

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if !trusted {
            let fix = NSMenuItem(
                title: "Open Accessibility settings…",
                action: #selector(openAccessibility), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }

        let toggle = NSMenuItem(
            title: Config.enabled ? "Pause" : "Resume",
            action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        menu.addItem(.separator())

        let header = NSMenuItem(title: "Turn speed", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for (index, speed) in MenuBar.speeds.enumerated() {
            let entry = NSMenuItem(
                title: "  \(speed.0)", action: #selector(setSpeed(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = abs(Config.sensitivity - speed.1) < 0.01 ? .on : .off
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Two fingers move · press down to turn on the spot",
            action: nil, keyEquivalent: ""))
        menu.items.last?.isEnabled = false

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit TrackSteer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @objc private func toggleEnabled() {
        Config.enabled.toggle()
        if !Config.enabled { Mouse.release() }
        Config.save()
        rebuild()
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        guard MenuBar.speeds.indices.contains(sender.tag) else { return }
        Config.sensitivity = MenuBar.speeds[sender.tag].1
        Config.save()
        rebuild()
    }

    @objc private func openAccessibility() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        Mouse.release()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry point

let debugEnabled = ProcessInfo.processInfo.environment["TRACKSTEER_DEBUG"] != nil

func debug(_ message: String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write("TrackSteer[debug]: \(message)\n".data(using: .utf8)!)
}

func log(_ message: String) {
    FileHandle.standardError.write("TrackSteer: \(message)\n".data(using: .utf8)!)
}

let touches = TouchMonitor()
let scroll = ScrollInterceptor()
let scope = AppScope()

// Ask for Accessibility, prompting if it is missing, and keep running either
// way. Exiting here was a mistake: an ad-hoc signature changes on every build,
// so macOS revokes the grant after each update and the app would simply vanish
// on launch with nothing on screen to explain why.
let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)

if !trusted {
    log("Accessibility not granted yet -- the menu bar icon will say so.")
    log("System Settings > Privacy & Security > Accessibility, then add TrackSteer.")
}

if trusted {
    if !scroll.start() {
        log("could not create the event tap despite being trusted")
    }
    touches.start()
}

// Permission is usually granted a few seconds after the prompt, so pick it up
// without making the user relaunch.
if !trusted {
    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
        guard AXIsProcessTrusted() else { return }
        timer.invalidate()
        _ = scroll.start()
        touches.start()
        menuBar.rebuild()
        log("Accessibility granted -- now active.")
    }
}

Config.load()
Config.watch()

// Instantiate the app before touching NSStatusBar: the status bar belongs to a
// running application, and creating an item before that exists silently does
// nothing.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // background only, no Dock icon

let menuBar = MenuBar()
menuBar.start()
scope.onChange = { menuBar.rebuild() }
Config.onExternalChange = { menuBar.rebuild() }
scope.start()

log("running. \(Config.fingerCount)-finger drag = middle button, sensitivity \(Config.sensitivity), in \(Config.targetBundleIDs.joined(separator: ", "))")

// Release the button if we are killed mid-drag, so nothing is left stuck.
signal(SIGINT) { _ in Mouse.release(); exit(0) }
signal(SIGTERM) { _ in Mouse.release(); exit(0) }

app.run()
