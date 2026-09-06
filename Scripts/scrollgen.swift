//  scrollgen.swift — a trackpad, synthesised: N precise scroll events of P
//  pixels each, one every I milliseconds, posted by the window server to the
//  front app. `Scripts/.build-scrollgen <events> <pixels> <intervalMs> [app=<bundle id>]`
//  Precise deltas (hasPreciseScrollingDeltas) are what a trackpad sends, and
//  what the terminal accumulates into rows — the thing the bench measures.
import AppKit
import CoreGraphics

let a = CommandLine.arguments
guard a.count >= 4, let count = Int(a[1]), let pixels = Int32(a[2]), let interval = Double(a[3]) else {
    FileHandle.standardError.write(Data("usage: scrollgen <events> <pixels> <intervalMs> [app=<bundle id>]\n".utf8))
    exit(2)
}
// `pid=` beats `app=`: with two instances of the same bundle running (his and
// the bench's) the bundle id activates whichever comes first, and the events
// then land in the wrong terminal (30/08, scrolled his window by mistake).
if let request = a.first(where: { $0.hasPrefix("pid=") }), let pid = Int32(request.dropFirst(4)) {
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        FileHandle.standardError.write(Data("no running app with pid \(pid)\n".utf8)); exit(1)
    }
    app.activate(options: [.activateAllWindows])
    usleep(300_000)
} else if let request = a.first(where: { $0.hasPrefix("app=") }) {
    let id = String(request.dropFirst(4))
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
        FileHandle.standardError.write(Data("no running app \(id)\n".utf8)); exit(1)
    }
    app.activate(options: [.activateAllWindows])
    usleep(300_000)
}
// `loc=x,y` (CG points, origin top-left): the event carries its own location,
// so the window server routes it to the window under THAT point. Warping the
// cursor first was not enough with the screen on (30/08): 120 events landed
// nowhere while the app's own dump said it was active and under the pointer.
var location: CGPoint? = nil
if let request = a.first(where: { $0.hasPrefix("loc=") }) {
    let parts = request.dropFirst(4).split(separator: ",").compactMap { Double($0) }
    if parts.count == 2 {
        location = CGPoint(x: parts[0], y: parts[1])
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: location!, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
            usleep(100_000)
        }
    }
}
let start = Date()
for i in 0..<count {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                          wheel1: pixels, wheel2: 0, wheel3: 0) else { exit(1) }
    // Mark the stream as a continuous (trackpad) gesture, so the receiver sees
    // precise deltas rather than notches.
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    if let location { e.location = location }
    e.post(tap: .cghidEventTap)
    let target = start.addingTimeInterval(Double(i + 1) * interval / 1000)
    let wait = target.timeIntervalSinceNow
    if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
}
print("posted \(count) events of \(pixels) px every \(interval) ms in \(String(format: "%.0f", Date().timeIntervalSince(start) * 1000)) ms")
