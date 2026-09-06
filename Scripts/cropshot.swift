//  cropshot.swift — cuts a rectangle out of a screenshot, in PIXELS.
//
//  Usage: cropshot <in.png> <out.png> <x> <y> <w> <h>   (y from the TOP)
//
//  A parity comparison is made on a piece of the page, not on a whole screen
//  scaled down to nothing: the bar, the band, the panel seam. This is the
//  knife, and it exists because there is no image library on this machine.

import AppKit

let a = CommandLine.arguments
guard a.count >= 7, let image = NSImage(contentsOfFile: a[1]),
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let x = Int(a[3]), let y = Int(a[4]), let w = Int(a[5]), let h = Int(a[6])
else {
    FileHandle.standardError.write(Data("usage: cropshot <in> <out> <x> <y> <w> <h>\n".utf8))
    exit(2)
}
let rect = CGRect(x: x, y: y, width: min(w, source.width - x), height: min(h, source.height - y))
guard let cut = source.cropping(to: rect) else { exit(3) }
let out = NSBitmapImageRep(cgImage: cut)
guard let data = out.representation(using: .png, properties: [:]) else { exit(4) }
try data.write(to: URL(fileURLWithPath: a[2]))
print("\(a[2]) \(cut.width)x\(cut.height) from \(source.width)x\(source.height)")
