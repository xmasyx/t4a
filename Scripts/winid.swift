// Prints the window number of the on-screen T4A window, so a screenshot can
// photograph the app and not whatever happens to be in front of it.
//
//   winid [pid]
//
// WITH A PID it photographs THAT instance, and this is not a convenience.
// The list comes back in z-order, so with a second T4A on the screen — the
// principal's own, running from the same bundle — the first match is whichever
// is in front, which on 2026-08-26 was his: `bench-preview` filed a photograph
// of HIS window as evidence for a claim about the bench's. Two failures in one:
// the claim was never photographed, and his screen was about to be committed.
import CoreGraphics
import Foundation

let wanted = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) : nil
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    guard owner == "T4A", layer == 0 else { continue }
    if let wanted {
        let pid = window[kCGWindowOwnerPID as String] as? Int ?? -1
        guard pid == wanted else { continue }
    }
    if let number = window[kCGWindowNumber as String] as? Int {
        print(number)
        exit(0)
    }
}
exit(1)
