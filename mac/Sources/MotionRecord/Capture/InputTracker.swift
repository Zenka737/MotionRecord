import Foundation
import AppKit
import CoreGraphics

/// Records the global cursor position at ~240 Hz and mouse clicks, all stamped with the host clock.
/// start() must be called on the main thread (NSEvent monitors).
final class InputTracker: @unchecked Sendable {
    static let sampleRate: Double = 240

    private let lock = NSLock()
    private var cursor: [RawCursorSample] = []
    private var clicks: [RawClick] = []
    private var keys: [(host: Double, kind: Int)] = []
    private var keyGlobal: Any?
    private var keyLocal: Any?
    /// Record key press TIMES (never characters). Set before start().
    var recordKeys = false
    private var timer: DispatchSourceTimer?
    private var shapeTimer: DispatchSourceTimer?
    private var shapeKeys: [Int: String] = [:]                 // tiff hash -> shape id
    private var shapeDefs: [(def: CursorShapeDef, png: Data)] = []
    private var shapeEvents: [(host: Double, id: String)] = []
    private var lastShapeID = ""
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let queue = DispatchQueue(label: "motionrecord.input.cursor", qos: .userInteractive)

    private static let mouseMask: NSEvent.EventTypeMask = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
    ]

    func start() {
        precondition(Thread.isMainThread, "InputTracker.start() must run on the main thread")
        lock.lock()
        cursor.removeAll(keepingCapacity: true)
        cursor.reserveCapacity(Int(Self.sampleRate) * 60 * 10)
        clicks.removeAll()
        keys.removeAll()
        shapeKeys.removeAll(); shapeDefs.removeAll(); shapeEvents.removeAll(); lastShapeID = ""
        lock.unlock()
        if recordKeys {
            // Listen-only event tap: works with the "Input Monitoring" permission (NSEvent global key monitors need
            // Accessibility instead). Falls back to NSEvent monitors if the tap can't be created.
            if !startKeyTap() {
                keyGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handleKey(e) }
                keyLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handleKey(e); return e }
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mouseMask) { [weak self] event in
            self?.handle(event)
        }
        // Global monitors don't deliver events targeted at our own windows.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mouseMask) { [weak self] event in
            self?.handle(event)
            return event
        }

        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / Self.sampleRate)), leeway: .microseconds(100))
        t.setEventHandler { [weak self] in self?.sampleCursor() }
        timer = t
        t.resume()

        // Real system cursor shape (arrow / hand / I-beam / closed hand while dragging ...), polled on the main thread.
        let st = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        st.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        st.setEventHandler { [weak self] in self?.sampleShape() }
        shapeTimer = st
        st.resume()
    }

    private func sampleShape() {
        guard let cur = NSCursor.currentSystem else { return }
        let img = cur.image
        guard img.size.width >= 1, img.size.height >= 1, let tiff = img.tiffRepresentation else { return }
        let hot = cur.hotSpot
        var hasher = Hasher()
        hasher.combine(tiff); hasher.combine(Int(hot.x * 10)); hasher.combine(Int(hot.y * 10))
        let key = hasher.finalize()
        let host = HostClock.now()
        lock.lock()
        var id = shapeKeys[key]
        if id == nil {
            // Largest representation -> PNG.
            let reps = img.representations.compactMap { $0 as? NSBitmapImageRep }
            if let rep = reps.max(by: { $0.pixelsWide < $1.pixelsWide }) ?? NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let new = "c\(shapeDefs.count)"
                shapeKeys[key] = new
                shapeDefs.append((CursorShapeDef(id: new, w: Double(img.size.width), h: Double(img.size.height),
                                                 hotX: Double(hot.x), hotY: Double(hot.y)), png))
                id = new
            }
        }
        if let id, id != lastShapeID { lastShapeID = id; shapeEvents.append((host, id)) }
        lock.unlock()
    }

    /// Cursor shapes seen + change events (host clock). Call after stop().
    func takeShapes() -> (defs: [(def: CursorShapeDef, png: Data)], events: [(host: Double, id: String)]) {
        lock.lock(); defer { lock.unlock() }
        return (shapeDefs, shapeEvents)
    }

    /// Stops tracking and returns the raw data (host-clock timestamps).
    func stop() -> (cursor: [RawCursorSample], clicks: [RawClick]) {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        stopKeyTap()
        if let m = keyGlobal { NSEvent.removeMonitor(m); keyGlobal = nil }
        if let m = keyLocal { NSEvent.removeMonitor(m); keyLocal = nil }
        if let st = shapeTimer { st.setEventHandler {}; st.cancel(); shapeTimer = nil }
        if let t = timer {
            t.setEventHandler {}
            t.cancel()
            timer = nil
        }
        // Take a final sample, then drain whatever the timer queue still had in flight.
        queue.sync { sampleCursor() }
        lock.lock(); defer { lock.unlock() }
        return (cursor, clicks)
    }

    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?

    private func startKeyTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<InputTracker>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.keyTap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown { me.handleKeyCG(event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: cb,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        keyTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        keyTapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopKeyTap() {
        if let t = keyTap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = keyTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        keyTap = nil; keyTapSource = nil
    }

    private func handleKeyCG(_ e: CGEvent) {
        if e.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
        let flags = e.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return }
        let host = HostClock.now()
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        let kind: Int
        switch code { case 49: kind = 1; case 36, 76: kind = 2; case 51, 117: kind = 3; default: kind = 0 }
        lock.lock(); keys.append((host, kind)); lock.unlock()
    }

    /// Key presses collected so far (host clock). Call after stop().
    func takeKeys() -> [(host: Double, kind: Int)] {
        lock.lock(); defer { lock.unlock() }
        return keys
    }

    private func handleKey(_ event: NSEvent) {
        if event.isARepeat { return }
        let now = HostClock.now()
        var host = event.timestamp
        if !(host > 0) || abs(host - now) > 0.5 { host = now }
        // Only the KIND of key is kept (never the character): 1 space, 2 return, 3 delete, 0 anything else.
        let kind: Int
        switch event.keyCode { case 49: kind = 1; case 36, 76: kind = 2; case 51, 117: kind = 3; default: kind = 0 }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) { return }  // shortcuts aren't typing
        lock.lock(); keys.append((host, kind)); lock.unlock()
    }

    private func sampleCursor() {
        let host = HostClock.now()
        guard let p = CGEvent(source: nil)?.location else { return }
        lock.lock()
        cursor.append(RawCursorSample(host: host, x: Double(p.x), y: Double(p.y)))
        lock.unlock()
    }

    private func handle(_ event: NSEvent) {
        let now = HostClock.now()
        // event.timestamp is on the mach-absolute (uptime) clock; use it when plausible, else callback time.
        var host = event.timestamp
        if !(host > 0) || abs(host - now) > 0.5 { host = now }

        let button: Int
        let isDown: Bool
        switch event.type {
        case .leftMouseDown: button = 0; isDown = true
        case .leftMouseUp: button = 0; isDown = false
        case .rightMouseDown: button = 1; isDown = true
        case .rightMouseUp: button = 1; isDown = false
        case .otherMouseDown: button = max(2, event.buttonNumber); isDown = true
        case .otherMouseUp: button = max(2, event.buttonNumber); isDown = false
        default: return
        }
        // CGEvent location: global, top-left origin, points.
        let loc = event.cgEvent?.location ?? CGEvent(source: nil)?.location ?? .zero
        lock.lock()
        clicks.append(RawClick(host: host, x: Double(loc.x), y: Double(loc.y), button: button, isDown: isDown))
        lock.unlock()
    }
}
