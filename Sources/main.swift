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

    /// How the drag is triggered.
    ///   .rest  — two fingers touching is enough. Nothing is held, which is
    ///            more comfortable but unlike any mouse.
    ///   .press — the trackpad must be physically clicked, matching the
    ///            both-buttons-held gesture this replaces.
    enum Trigger: String { case rest, press }
    static var trigger: Trigger = .rest

    /// Scales trackpad movement into mouse movement. 1.0 tracks the system's own
    /// trackpad acceleration, which macOS has already applied to the scroll
    /// deltas we read -- so the default inherits Apple's tuning rather than
    /// inventing a curve.
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

        if let raw = defaults.string(forKey: "trigger"),
            let value = Trigger(rawValue: raw) {
            trigger = value
        }
    }

    static func save() {
        defaults.set(sensitivity, forKey: "sensitivity")
        defaults.set(enabled, forKey: "enabled")
        defaults.set(trigger.rawValue, forKey: "trigger")
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

            // Settings sent from the addon, arriving via SavedVariables.
            if AddonSettings.poll() { changed = true }

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
    var middleButtonHeld = false
    var targetAppActive = false

    /// Press mode only: the trackpad is physically held down.
    var physicalPress = false
    /// Whether the current press has actually moved, which decides if it was a
    /// drag or just a click that should be passed along.
    var pressMoved = false

    /// Where the drag started. Every synthetic event is reported at this exact
    /// point and it never moves, so the pointer is still where the player left
    /// it when they lift their fingers.
    var anchor: CGPoint = .zero
}

// MARK: - Event generation

enum Mouse {
    static let source = CGEventSource(stateID: .hidSystemState)

    static func press() {
        let state = State.shared
        guard !state.middleButtonHeld else { return }

        state.anchor = currentCursor()
        post(.otherMouseDown, delta: .zero)
        state.middleButtonHeld = true
    }

    static func release() {
        let state = State.shared
        guard state.middleButtonHeld else { return }

        post(.otherMouseUp, delta: .zero)
        state.middleButtonHeld = false

        // Belt and braces: if anything else nudged the pointer while the game
        // had it hidden, put it back where the drag began.
        CGWarpMouseCursorPosition(state.anchor)
    }

    static func drag(dx: Double, dy: Double) {
        guard State.shared.middleButtonHeld else { return }
        post(.otherMouseDragged, delta: CGPoint(x: dx, y: dy))
    }

    private static func currentCursor() -> CGPoint {
        guard let event = CGEvent(source: nil) else { return .zero }
        return event.location
    }

    private static func post(_ type: CGEventType, delta: CGPoint) {
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
                mouseButton: .center
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
        if Int(numTouches) != Config.fingerCount && State.shared.middleButtonHeld {
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

        // Press mode: a two-finger click starts the drag and holds it.
        if type == .rightMouseDown || type == .rightMouseUp {
            guard Config.enabled, Config.trigger == .press, state.targetAppActive,
                state.fingersDown == Config.fingerCount
            else { return passThrough }

            if type == .rightMouseDown {
                state.physicalPress = true
                state.pressMoved = false
                return nil  // swallow; replayed on release if it was only a click
            }

            state.physicalPress = false
            Mouse.release()

            if !state.pressMoved {
                // Never moved, so the player meant an ordinary right click.
                // Put it back rather than eating it.
                let location = event.location
                for phase in [CGEventType.rightMouseDown, .rightMouseUp] {
                    CGEvent(
                        mouseEventSource: Mouse.source, mouseType: phase,
                        mouseCursorPosition: location, mouseButton: .right
                    )?.post(tap: .cghidEventTap)
                }
            }
            return nil
        }

        guard type == .scrollWheel else { return passThrough }

        // Outside the target app, or without the right fingers down, this is an
        // ordinary scroll and none of our business.
        debug("scroll: fingers=\(state.fingersDown) target=\(state.targetAppActive) held=\(state.middleButtonHeld)")

        // In press mode the trackpad must also be held down.
        let triggered = Config.trigger == .rest || state.physicalPress

        guard Config.enabled, triggered, state.targetAppActive,
            state.fingersDown == Config.fingerCount
        else {
            if state.middleButtonHeld { Mouse.release() }
            return passThrough
        }

        // Pixel deltas rather than line deltas: trackpads report continuous
        // movement here, which is what makes this feel like a mouse rather than
        // a series of clicks.
        let dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        let dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))

        state.pressMoved = true
        Mouse.press()
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
        if !active && State.shared.middleButtonHeld {
            Mouse.release()
        }
    }
}

// MARK: - Settings from the addon
//
// BindSwap cannot talk to this app while the game runs -- WoW addons have no
// file or network access. The one channel is SavedVariables, which the client
// flushes on /reload or logout. So we watch that file instead.
//
// Parsed with a narrow regex rather than a Lua interpreter: we want exactly
// three known values out of a file the game owns, and anything we do not
// recognise is ignored rather than guessed at.

enum AddonSettings {
    static let searchRoots = [
        "/Applications/World of Warcraft/_retail_/WTF/Account"
    ]

    private static var lastSeen: Date?

    /// Locate BindSwap.lua under any account folder.
    static func savedVariablesPath() -> String? {
        let fm = FileManager.default
        for root in searchRoots {
            guard let accounts = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for account in accounts {
                let path = "\(root)/\(account)/SavedVariables/BindSwap.lua"
                if fm.fileExists(atPath: path) { return path }
            }
        }
        return nil
    }

    private static func value(_ key: String, in text: String) -> String? {
        // Matches  ["key"] = value  with or without quotes.
        let pattern = "\\[\"\(key)\"\\]\\s*=\\s*\"?([^\",\n]+)\"?"
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return text[range].trimmingCharacters(in: .whitespaces)
    }

    /// Returns true if anything actually changed.
    static func poll() -> Bool {
        guard let path = savedVariablesPath(),
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let modified = attrs[.modificationDate] as? Date
        else { return false }

        // Only re-read when the game has rewritten the file.
        if let seen = lastSeen, seen >= modified { return false }
        lastSeen = modified

        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
            let blockStart = text.range(of: "[\"trackSteer\"]")
        else { return false }

        let block = String(text[blockStart.lowerBound...].prefix(400))
        var changed = false

        if let raw = value("trigger", in: block),
            let mode = Config.Trigger(rawValue: raw), mode != Config.trigger {
            Config.trigger = mode
            changed = true
        }

        if let raw = value("sensitivity", in: block), let number = Double(raw),
            number > 0, number <= 10, abs(number - Config.sensitivity) > 0.01 {
            Config.sensitivity = number
            changed = true
        }

        if changed {
            Mouse.release()  // never carry a drag across a settings change
            Config.save()
            log("settings updated from the addon: \(Config.trigger.rawValue), \(Config.sensitivity)")
        }
        return changed
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

        let triggerHeader = NSMenuItem(title: "Gesture", action: nil, keyEquivalent: "")
        triggerHeader.isEnabled = false
        menu.addItem(triggerHeader)

        for (title, mode) in [
            ("  Two fingers resting", Config.Trigger.rest),
            ("  Two fingers pressed down", Config.Trigger.press),
        ] {
            let entry = NSMenuItem(
                title: title, action: #selector(setTrigger(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = Config.trigger == mode ? .on : .off
            menu.addItem(entry)
        }

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
            title: "Two-finger drag to run and steer, in World of Warcraft",
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

    @objc private func setTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let mode = Config.Trigger(rawValue: raw)
        else { return }

        Config.trigger = mode
        Mouse.release()  // never leave a drag hanging across a mode change
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
