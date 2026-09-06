//  keypress.swift — one real keystroke, through the window server.
//
//  Usage: keypress <keyCode> [cmd] [shift] [alt] [ctrl] [app=<bundle id>]
//
//  `app=` brings that application to the front first and waits for it to get
//  there. A real keystroke goes to whoever has the keyboard, so a probe that
//  does not make sure of that is measuring the app that ran the probe.
//
//  It exists because a synthesized `NSEvent` handed to `NSApp.sendEvent`
//  never becomes the application's current event, so a latency measured from
//  it is measured from whatever came through the queue last. This posts the
//  press the way a finger does: the window server stamps it, the run loop
//  dispatches it, and the number the app computes is the number a person
//  would feel (ISC-32).

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2, let code = UInt16(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: keypress <keyCode> [cmd] [shift] [alt] [ctrl]\n".utf8))
    exit(2)
}
var flags: CGEventFlags = []
for modifier in arguments.dropFirst(2) {
    switch modifier {
    case "cmd": flags.insert(.maskCommand)
    case "shift": flags.insert(.maskShift)
    case "alt", "opt": flags.insert(.maskAlternate)
    case "ctrl": flags.insert(.maskControl)
    default: break
    }
}
if let request = arguments.first(where: { $0.hasPrefix("app=") }) {
    let identifier = String(request.dropFirst(4))
    guard let app = NSRunningApplication
        .runningApplications(withBundleIdentifier: identifier).first else {
        FileHandle.standardError.write(Data("no running app \(identifier)\n".utf8))
        exit(1)
    }
    app.activate(options: [.activateAllWindows])
    // Activation is a request to the window server, not a function call: the
    // press has to wait for it, and a press sent to the wrong app is a
    // measurement of the wrong app.
    for _ in 0..<40 {
        if app.isActive { break }
        usleep(50_000)
    }
    guard app.isActive else {
        FileHandle.standardError.write(Data("\(identifier) never came to the front\n".utf8))
        exit(1)
    }
    usleep(300_000)
}

guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
    FileHandle.standardError.write(Data("could not make the event\n".utf8))
    exit(1)
}
down.flags = flags
up.flags = flags
down.post(tap: .cghidEventTap)
usleep(20_000)
up.post(tap: .cghidEventTap)
usleep(120_000)
