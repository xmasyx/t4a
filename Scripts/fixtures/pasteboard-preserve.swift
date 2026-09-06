// Preserve every eager pasteboard representation around a GUI bench.
// Text-only pbpaste is insufficient here: the claim itself exercises images
// and file URLs, and returning only a string would damage the user's clipboard.

import AppKit
import Foundation

struct Entry: Codable {
    let type: String
    let data: Data
}

typealias Snapshot = [[Entry]]

guard CommandLine.arguments.count == 3 else {
    fputs("usage: pasteboard-preserve save|restore SNAPSHOT\n", stderr)
    exit(2)
}

let action = CommandLine.arguments[1]
let url = URL(fileURLWithPath: CommandLine.arguments[2])
let board = NSPasteboard.general

switch action {
case "save":
    let snapshot: Snapshot = (board.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in
            item.data(forType: type).map { Entry(type: type.rawValue, data: $0) }
        }
    }
    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
case "restore":
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    let items: [NSPasteboardItem] = snapshot.map { entries in
        let item = NSPasteboardItem()
        for entry in entries {
            item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
        }
        return item
    }
    board.clearContents()
    if !items.isEmpty && !board.writeObjects(items) {
        fputs("pasteboard-preserve: restore failed\n", stderr)
        exit(1)
    }
default:
    fputs("pasteboard-preserve: action must be save or restore\n", stderr)
    exit(2)
}
