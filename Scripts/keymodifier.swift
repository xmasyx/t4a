//  keymodifier.swift — press or release one modifier through WindowServer.
//
//  Usage: keymodifier cmd down|up
//
//  A mouse event carrying `.maskCommand` is not a Command-key transition and
//  therefore emits no `flagsChanged`. This helper gives benches the same
//  stationary-pointer transition that a finger on the modifier key produces.

import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 3, arguments[1] == "cmd",
      arguments[2] == "down" || arguments[2] == "up" else {
    FileHandle.standardError.write(Data("usage: keymodifier cmd down|up\n".utf8))
    exit(2)
}

let isDown = arguments[2] == "down"
guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: isDown) else {
    FileHandle.standardError.write(Data("could not make the modifier event\n".utf8))
    exit(1)
}
event.flags = isDown ? [.maskCommand] : []
event.post(tap: .cghidEventTap)
usleep(150_000)
