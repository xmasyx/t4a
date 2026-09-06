//  appfocus.swift — remember and restore the exact frontmost app in a bench.
//
//  Usage: appfocus current | appfocus activate <pid>
//
//  A bundle identifier is not enough while the user's T4A and a bench T4A
//  coexist. The PID is the boundary that lets a cursor pole borrow focus and
//  give it back without choosing an arbitrary instance of the same app.

import AppKit

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "current" {
    guard let application = NSWorkspace.shared.frontmostApplication else { exit(1) }
    print(application.processIdentifier)
    exit(0)
}

guard arguments.count == 3, arguments[1] == "activate",
      let pid = Int32(arguments[2]),
      let application = NSRunningApplication(processIdentifier: pid) else {
    FileHandle.standardError.write(
        Data("usage: appfocus current | appfocus activate <pid>\n".utf8))
    exit(2)
}

application.activate(options: [.activateAllWindows])
for _ in 0..<40 {
    if application.isActive { exit(0) }
    usleep(50_000)
}
FileHandle.standardError.write(Data("appfocus: pid \(pid) did not become active\n".utf8))
exit(1)
