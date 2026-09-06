//  dragpoint.swift — one real mouse drag, posted to the window server.
//
//  Usage: dragpoint <fromX> <fromY> <toX> <toY> [steps]
//
//  Coordinates are Cocoa's (origin bottom-left of the main screen), because
//  that is what the app reports about its own views. The flip to the window
//  server's top-left space happens here, once.
//
//  It exists for the same reason `dragresize.swift` does: a claim about
//  dragging a handle, answered by calling the function the handle would have
//  called, is a claim about a function. This posts a press, a run of drags and
//  a release that AppKit cannot tell from a hand on the mouse.

import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 5,
      let fromX = Double(arguments[1]), let fromY = Double(arguments[2]),
      let toX = Double(arguments[3]), let toY = Double(arguments[4])
else {
    FileHandle.standardError.write(Data("usage: dragpoint <x1> <y1> <x2> <y2> [steps]\n".utf8))
    exit(2)
}
let steps = arguments.count > 5 ? (Int(arguments[5]) ?? 30) : 30

let screenHeight = NSScreen.screens.first?.frame.height ?? 0
func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: screenHeight - point.y) }

let from = flip(CGPoint(x: fromX, y: fromY))
let to = flip(CGPoint(x: toX, y: toY))

func post(_ type: CGEventType, _ at: CGPoint) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: at, mouseButton: .left) else { return }
    event.post(tap: .cghidEventTap)
}

post(.mouseMoved, from)
usleep(60_000)
post(.leftMouseDown, from)
usleep(60_000)
for step in 1...steps {
    let fraction = Double(step) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * fraction,
                                    y: from.y + (to.y - from.y) * fraction))
    usleep(12_000)
}
usleep(60_000)
post(.leftMouseUp, to)
usleep(120_000)
