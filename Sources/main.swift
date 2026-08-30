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

    /// Scales trackpad movement into mouse movement.
    static var sensitivity: Double = 1.0
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

    /// Where synthetic drag events are reported. Kept in step with the real
    /// cursor so the pointer does not jump when a drag begins.
    var cursor: CGPoint = .zero
}

// MARK: - Event generation

enum Mouse {
    static let source = CGEventSource(stateID: .hidSystemState)

    static func press() {
        let state = State.shared
        guard !state.middleButtonHeld else { return }

        state.cursor = currentCursor()
        post(.otherMouseDown, delta: .zero)
        state.middleButtonHeld = true
    }

    static func release() {
        let state = State.shared
        guard state.middleButtonHeld else { return }

        post(.otherMouseUp, delta: .zero)
        state.middleButtonHeld = false
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

        // Games read relative motion, but the cursor position still has to be
        // sane for anything that reads it, so track both.
        state.cursor.x += delta.x
        state.cursor.y += delta.y

        guard
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: state.cursor,
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
        let mask = (1 << CGEventType.scrollWheel.rawValue)

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

        guard type == .scrollWheel else { return passThrough }

        // Outside the target app, or without the right fingers down, this is an
        // ordinary scroll and none of our business.
        debug("scroll: fingers=\(state.fingersDown) target=\(state.targetAppActive) held=\(state.middleButtonHeld)")

        guard state.targetAppActive, state.fingersDown == Config.fingerCount else {
            if state.middleButtonHeld { Mouse.release() }
            return passThrough
        }

        // Pixel deltas rather than line deltas: trackpads report continuous
        // movement here, which is what makes this feel like a mouse rather than
        // a series of clicks.
        let dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        let dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))

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

        // Never leave the button stuck down when switching away mid-drag.
        if !active && State.shared.middleButtonHeld {
            Mouse.release()
        }
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

guard AXIsProcessTrusted() else {
    log("Accessibility permission not granted.")
    log("System Settings > Privacy & Security > Accessibility, then add TrackSteer.")
    exit(1)
}

guard scroll.start() else {
    log("could not create the event tap -- is Accessibility actually enabled?")
    exit(1)
}

touches.start()
scope.start()

log("running. \(Config.fingerCount)-finger drag = middle button, in \(Config.targetBundleIDs.joined(separator: ", "))")

// Release the button if we are killed mid-drag, so nothing is left stuck.
signal(SIGINT) { _ in Mouse.release(); exit(0) }
signal(SIGTERM) { _ in Mouse.release(); exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // background only, no Dock icon
app.run()
