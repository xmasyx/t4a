//  clickpoint.swift — one real click, with a chosen hold time.
//
//  Usage: clickpoint <x> <y> [holdMs] [cmd]
//
//  The hold matters: M6 compresses its stretch when the finger is quick, so a
//  probe that always holds for 80 ms never measures the tap — which is the
//  case the gesture exists for (ISC-104.6). Coordinates are Cocoa's.

import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: clickpoint <x> <y> [holdMs]\n".utf8))
    exit(2)
}
let hold = arguments.count > 3 ? (Double(arguments[3]) ?? 10) : 10
let height = NSScreen.screens.first?.frame.height ?? 0
let point = CGPoint(x: x, y: height - y)
let commandDown = arguments.dropFirst(3).contains("cmd")

func post(_ type: CGEventType) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: point, mouseButton: .left) else { return }
    if commandDown { event.flags = [.maskCommand] }
    event.post(tap: .cghidEventTap)
}

post(.mouseMoved)
usleep(60_000)
post(.leftMouseDown)
usleep(useconds_t(hold * 1000))
post(.leftMouseUp)
usleep(200_000)
