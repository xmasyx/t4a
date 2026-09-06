//  axframe.swift — read or set the frame of a process's front window through
//  Accessibility, so a bench can park HIS terminal on one half of the screen
//  and its own on the other (his request, 2026-09-05: «mi rendi la mia pagina
//  del terminale metà dello schermo e quella che apri tu l'altra metà»).
//
//    axframe <pid>                 prints "x y w h" (screen points, origin top-left)
//    axframe <pid> <x> <y> <w> <h> sets it
//
//  The caller must be trusted for Accessibility; a refusal is printed, never
//  guessed around.
import ApplicationServices
import Foundation

let a = CommandLine.arguments
guard a.count == 2 || a.count == 6, let pid = Int32(a[1]) else {
    FileHandle.standardError.write(Data("usage: axframe <pid> [x y w h]\n".utf8)); exit(2)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("this process is not trusted for Accessibility\n".utf8)); exit(3)
}
let app = AXUIElementCreateApplication(pid)
var value: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement], let window = windows.first else {
    FileHandle.standardError.write(Data("pid \(pid) has no window\n".utf8)); exit(1)
}
func point(_ element: AXUIElement, _ attribute: String) -> CGPoint {
    var raw: CFTypeRef?; var p = CGPoint.zero
    if AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw {
        AXValueGetValue(raw as! AXValue, .cgPoint, &p)
    }
    return p
}
func size(_ element: AXUIElement, _ attribute: String) -> CGSize {
    var raw: CFTypeRef?; var s = CGSize.zero
    if AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw {
        AXValueGetValue(raw as! AXValue, .cgSize, &s)
    }
    return s
}
if a.count == 6, let x = Double(a[2]), let y = Double(a[3]), let w = Double(a[4]), let h = Double(a[5]) {
    var p = CGPoint(x: x, y: y); var s = CGSize(width: w, height: h)
    // Size first, then position: a window that would not fit where it is asked
    // to go is clamped by the server, and the order avoids the clamp.
    if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv) }
    if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pv) }
    if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv) }
}
let p = point(window, kAXPositionAttribute), s = size(window, kAXSizeAttribute)
print("\(Int(p.x)) \(Int(p.y)) \(Int(s.width)) \(Int(s.height))")
