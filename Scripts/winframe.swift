// Prints the T4A window's frame — `x y width height`, in Cocoa coordinates.
//
// It asks the window server, not the app, so the same probe works on a build
// that has no test channel and on one that does: a bench that can only read
// the frame out of the app under test cannot be pointed at the version of the
// app it is supposed to be compared against.
import AppKit
import CoreGraphics

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
let screenHeight = NSScreen.screens.first?.frame.height ?? 0

// An app owns more windows than the one you can see — a title bar strip, a
// sheet, a shadow helper. Taking the first match found a 1512×32 sliver
// during a full-screen transition and called it the window; the biggest one
// is the one a person would point at.
var best: CGRect?
for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    guard owner == "T4A", layer == 0,
          let raw = window[kCGWindowBounds as String] as? [String: CGFloat],
          let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
    else { continue }
    if best == nil || bounds.width * bounds.height > best!.width * best!.height {
        best = bounds
    }
}
guard let bounds = best else { exit(1) }
// The window server measures down from the top of the main display.
let y = screenHeight - bounds.maxY
print("\(Int(bounds.origin.x)) \(Int(y)) \(Int(bounds.width)) \(Int(bounds.height))")
