import AppKit
import ApplicationServices

// Called by Hammerspoon: x y left|right distance [scroll|drag|anchor].
// Sends a trackpad-shaped horizontal gesture and never presses a mouse button,
// so it cannot pick up icons or tap anything. x and y are used only in anchor mode.
let args = CommandLine.arguments
guard args.count == 5 || args.count == 6, let distance = Double(args[4]), distance > 0,
      ["left", "right"].contains(args[3]) else {
    fputs("Usage: iphone-swipe x y left|right distance\n", stderr)
    exit(2)
}
guard AXIsProcessTrusted() else {
    fputs("Accessibility permission is not active for the launching application.\n", stderr)
    exit(3)
}
func frontmost() -> NSRunningApplication? { NSWorkspace.shared.frontmostApplication }
guard let app = frontmost(), app.bundleIdentifier == "com.apple.ScreenContinuity",
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
      let bounds = windows.compactMap({ item -> CGRect? in
          guard (item[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier),
                let raw = item[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: raw), rect.width > 150, rect.height > 200 else { return nil }
          return rect
      }).max(by: { $0.width*$0.height < $1.width*$1.height }) else { exit(4) }

let original = CGEvent(source: nil)!.location
// The window has a black margin around the phone. Over the phone the gesture runs under the cursor,
// so a carousel can be swiped by hovering it; anywhere else it runs at the centre.
let phone = bounds.insetBy(dx: bounds.width*0.144, dy: bounds.height*0.089)
let anchored = args.count == 6 && args[5] == "anchor"
let hovering = !anchored && phone.contains(original)
let target = anchored ? CGPoint(x: Double(args[1]) ?? bounds.midX, y: Double(args[2]) ?? bounds.midY)
    : hovering ? original : CGPoint(x: bounds.midX, y: bounds.midY)
// Left arrow goes to the page on the left, the opposite of a trackpad swipe.
let sign: Double = args[3] == "left" ? 1 : -1
func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }

// iPhone Mirroring tracks its pointer from movement deltas, so a plain warp would leave it behind.
func march(to point: CGPoint) {
    let start = CGEvent(source: nil)!.location
    var previous = start
    for i in 1...25 {
        let t = Double(i)/25
        let p = CGPoint(x: start.x+(point.x-start.x)*t, y: start.y+(point.y-start.y)*t)
        let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x-previous.x).rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y-previous.y).rounded()))
        e.post(tap: .cghidEventTap)
        previous = p
        usleep(6_000)
    }
    CGWarpMouseCursorPosition(point)
}
func scroll(_ dx: Int32, phase: Int64) {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
    e.location = target
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e.setIntegerValueField(field(137), value: 1)
    e.post(tap: .cghidEventTap)
}
// A real trackpad pairs every scroll event with a type-29 gesture event; these field numbers were recorded from one.
func gesture(phase: Int64, dx: Float) {
    let e = CGEvent(source: nil)!
    e.type = CGEventType(rawValue: 29)!
    e.location = target
    let bits = Int64(dx == 0 ? 0x8000_0000 : dx.bitPattern)
    e.setIntegerValueField(field(110), value: 6)
    e.setIntegerValueField(field(132), value: phase)
    e.setIntegerValueField(field(135), value: 1)
    e.setIntegerValueField(field(115), value: bits)
    e.setIntegerValueField(field(117), value: bits)
    e.setIntegerValueField(field(116), value: Int64(dx.rounded()))
    e.setIntegerValueField(field(123), value: 0x8000_0000)
    e.post(tap: .cghidEventTap)
}
func marker() {
    let e = CGEvent(source: nil)!
    e.type = CGEventType(rawValue: 29)!
    e.location = target
    e.post(tap: .cghidEventTap)
}
func frame(_ dx: Int32, first: Bool) {
    marker()
    scroll(dx, phase: first ? 1 : 2)
    gesture(phase: first ? 1 : 2, dx: Float(dx)*3)
    usleep(8_000)
}
func stroke(_ deltas: [Int32]) {
    gesture(phase: 128, dx: 0)
    scroll(0, phase: 128)
    usleep(40_000)
    for (i, dx) in deltas.enumerated() { frame(dx, first: i == 0) }
    marker()
    scroll(0, phase: 4)
    gesture(phase: 4, dx: 0)
    usleep(20_000)
}

// While the cursor is away from where the user left it, a real click (say, on an on-screen keyboard)
// would land on the iPhone and disturb the gesture. Hold clicks and replay them after the cursor returns.
var heldClicks: [CGEvent] = []
let heldLock = NSLock()
func holdClick(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
        heldLock.lock()
        if let copy = event.copy() { heldClicks.append(copy) }
        heldLock.unlock()
        return nil
    case .leftMouseDragged, .rightMouseDragged:
        return nil
    default:
        return Unmanaged.passUnretained(event)
    }
}
var clickTap: CFMachPort?
if !hovering {
    let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    clickTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                 eventsOfInterest: mask, callback: holdClick, userInfo: nil)
    if let clickTap {
        Thread.detachNewThread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, clickTap, 0), .commonModes)
            CGEvent.tapEnable(tap: clickTap, enable: true)
            CFRunLoopRun()
        }
        usleep(5_000)
    }
}
let count = max(10, Int(distance/8))
var placed: Int32 = 0
let deltas = (1...count).map { i -> Int32 in
    let v = Int32((sign*distance*Double(i)/Double(count)).rounded())
    defer { placed = v }
    return v-placed
}
// Scroll events follow the cursor, so it visits the target hidden, stays detached from the mouse during the gesture, then returns.
if !hovering {
    CGDisplayHideCursor(CGMainDisplayID())
    march(to: target)
    usleep(150_000)
}
CGAssociateMouseAndMouseCursorPosition(0)
stroke(deltas)
// iOS holds the finger down until another stroke begins, so a tiny second stroke releases the first.
usleep(120_000)
let nudge: Int32 = sign < 0 ? -1 : 1
stroke([nudge, nudge, nudge])
CGAssociateMouseAndMouseCursorPosition(1)
if !hovering {
    usleep(30_000)
    march(to: original)
    CGDisplayShowCursor(CGMainDisplayID())
    if let clickTap { CGEvent.tapEnable(tap: clickTap, enable: false) }
    heldLock.lock()
    let clicks = heldClicks
    heldLock.unlock()
    for click in clicks {
        click.location = original
        click.post(tap: .cghidEventTap)
        usleep(20_000)
    }
}
