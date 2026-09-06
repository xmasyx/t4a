// Reads the same twenty-four points out of two screenshots and prints the
// colour each one found.
//
//   samplecolours <a.png> <b.png> <y> <first x> <step>
//
// A percentage of differing pixels cannot tell "the palette is wrong" from
// "the block edges land a third of a pixel apart", because both show up as a
// count. Sampling the MIDDLE of each colour block can: the interiors are flat,
// so whatever comes back is the colour the renderer resolved, and the two
// numbers can simply be read side by side.
import AppKit
import Foundation

func load(_ path: String) -> (px: [UInt8], w: Int, h: Int)? {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    guard let ctx = px.withUnsafeMutableBytes({ raw in
        CGContext(data: raw.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                  bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    return (px, cg.width, cg.height)
}
let a = load(CommandLine.arguments[1])!
let b = load(CommandLine.arguments[2])!
let y = Int(CommandLine.arguments[3])!
let x0 = Int(CommandLine.arguments[4])!
let step = Int(CommandLine.arguments[5])!
for k in 0..<24 {
    let x = x0 + k * step
    let i = (y * a.w + x) * 4
    let ca = (a.px[i], a.px[i+1], a.px[i+2])
    let cb = (b.px[i], b.px[i+1], b.px[i+2])
    let d = max(abs(Int(ca.0) - Int(cb.0)), abs(Int(ca.1) - Int(cb.1)), abs(Int(ca.2) - Int(cb.2)))
    print("block \(k) idx \(16 + k * 7) x=\(x)  gpu \(ca)  cpu \(cb)  diff \(d)")
}
