//  movepoint.swift — put the real pointer somewhere, with a real move event.
//
//  Usage: movepoint <x> <y> [cmd]
//
//  Coordinates are Cocoa's (origin bottom-left of the main screen), like every
//  other probe here, because that is the space the app reports its own views
//  in. The flip to the window server's top-left space happens here, once.
//
//  Warping the cursor is not enough on its own: a tracking area learns that
//  the pointer arrived from a MOVE event, and a warp with no event behind it
//  can leave a view believing the pointer is still where it was. So the warp
//  is followed by a `mouseMoved` posted to the session — which is what a hand
//  on the mouse produces, and the only thing a claim about hovering may be
//  measured with.

import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: movepoint <x> <y>\n".utf8))
    exit(2)
}
let height = NSScreen.screens.first?.frame.height ?? 0
let point = CGPoint(x: x, y: height - y)
let commandDown = arguments.dropFirst(3).contains("cmd")

// Two moves, a beat apart: the first can land while the window server is
// still settling a window that has just been placed, and a tracking area that
// missed it would leave nothing hovered.
// A hand arrives, it does not teleport. A warp plus one posted move left
// the WindowServer with no window under the pointer on roughly half the
// runs (6/09: `event.window == nil` on every failed hover, geometry exact),
// so the pointer now walks the last stretch in real steps, each one a
// posted move, and the destination is posted twice as before.
// The approach starts OUTSIDE every window, in the menu bar: the window
// server ties a pointer to a window when it crosses the edge, and a walk
// that begins inside never crosses one.
let approach = CGPoint(x: point.x, y: 8)
var path: [CGPoint] = []
for step in 0...6 {
    let t = CGFloat(step) / 6
    path.append(CGPoint(x: approach.x + (point.x - approach.x) * t,
                        y: approach.y + (point.y - approach.y) * t))
}
path.append(point)
for (index, stop) in path.enumerated() {
    if index == 0 { CGWarpMouseCursorPosition(stop) }
    if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                          mouseCursorPosition: stop, mouseButton: .left) {
        if commandDown { move.flags = [.maskCommand] }
        move.post(tap: .cghidEventTap)
    }
    usleep(index == path.count - 1 ? 120_000 : 25_000)
}
