//  dragresize.swift — drags a window's bottom-right corner, for real.
//
//  Usage: dragresize <x> <y> <width> <height> <dw> <dh> [steps]
//
//  The frame is the window's, in Cocoa coordinates (origin bottom-left of the
//  main screen), as the app itself reports it. Everything after is a genuine
//  mouse press, a genuine set of drags and a genuine release, posted to the
//  window server — so AppKit runs a real live resize, `inLiveResize` is really
//  true while it lasts, and `windowDidEndLiveResize` really fires at the end.
//
//  This exists because ISC-106 is a claim about what happens WHILE a person
//  drags a window edge, and a claim about a drag measured on a programmatic
//  `setFrame` answers a weaker question: it never enters live resize at all.

import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 7,
      let x = Double(arguments[1]), let y = Double(arguments[2]),
      let width = Double(arguments[3]), let height = Double(arguments[4]),
      let deltaWidth = Double(arguments[5]), let deltaHeight = Double(arguments[6])
else {
    FileHandle.standardError.write(
        Data("usage: dragresize <x> <y> <w> <h> <dw> <dh> [steps]\n".utf8))
    exit(2)
}
let steps = arguments.count > 7 ? (Int(arguments[7]) ?? 40) : 40

// The window server measures from the top-left of the main display; Cocoa
// measures from the bottom-left. One flip, in one place.
let screenHeight = NSScreen.screens.first?.frame.height ?? 0
func toDisplay(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x, y: screenHeight - point.y)
}

// Two pixels inside the corner: outside is the desktop, further inside is the
// terminal, and only the edge itself starts a resize.
let start = CGPoint(x: x + width - 2, y: y + 2)
let end = CGPoint(x: start.x + deltaWidth, y: start.y - deltaHeight)
let restore = NSEvent.mouseLocation

func post(_ type: CGEventType, _ point: CGPoint) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: toDisplay(point),
                              mouseButton: .left) else { return }
    event.post(tap: .cghidEventTap)
}

post(.mouseMoved, start)
usleep(150_000)
post(.leftMouseDown, start)
usleep(120_000)
for step in 1...steps {
    let fraction = Double(step) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * fraction,
                                    y: start.y + (end.y - start.y) * fraction))
    usleep(30_000)
}
usleep(120_000)
post(.leftMouseUp, end)
usleep(150_000)
// The pointer goes back where the person left it.
post(.mouseMoved, CGPoint(x: restore.x, y: restore.y))
print("dragged \(Int(width))x\(Int(height)) -> about \(Int(width + deltaWidth))x\(Int(height + deltaHeight)) in \(steps) steps")
