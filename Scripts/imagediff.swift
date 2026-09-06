// Compares two screenshots pixel by pixel and says how far apart they are.
//
//   imagediff <a.png> <b.png> [--out diff.png] [--tolerance 12] [--crop x,y,w,h]
//
// Written for one question: does the GPU renderer draw the same terminal as
// the CPU one? Two rasterisers of the same text are never bit-identical —
// antialiasing along a stroke edge differs by a few levels — so the report
// separates the two things that matter and refuses to average them together:
//
//   * exact       pixels that match to the bit. Backgrounds, colour blocks,
//                 selection and the cursor are flat colour, so a difference
//                 here is a REAL difference, not a smoothing artefact.
//   * within N    pixels whose worst channel differs by no more than N. Glyph
//                 edges live here.
//   * far         everything else, with a bounding box of where it is, so a
//                 shifted line or a missing glyph shows up as a place on the
//                 screen instead of a percentage.
import AppKit
import Foundation

func load(_ path: String) -> (pixels: [UInt8], width: Int, height: Int)? {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    let width = cg.width, height = cg.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = pixels.withUnsafeMutableBytes({ raw in
        CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space, bitmapInfo: info)
    }) else { return nil }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (pixels, width, height)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: imagediff <a.png> <b.png> [--out d.png] [--tolerance N] [--crop x,y,w,h]\n".utf8))
    exit(2)
}
var tolerance = 12
if let index = arguments.firstIndex(of: "--tolerance"), index + 1 < arguments.count {
    tolerance = Int(arguments[index + 1]) ?? 12
}
var out: String?
if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count {
    out = arguments[index + 1]
}
var crop: (x: Int, y: Int, w: Int, h: Int)?
if let index = arguments.firstIndex(of: "--crop"), index + 1 < arguments.count {
    let parts = arguments[index + 1].split(separator: ",").compactMap { Int($0) }
    if parts.count == 4 { crop = (parts[0], parts[1], parts[2], parts[3]) }
}

guard let a = load(arguments[1]), let b = load(arguments[2]) else {
    FileHandle.standardError.write(Data("could not read one of the images\n".utf8))
    exit(2)
}
guard a.width == b.width, a.height == b.height else {
    print("size mismatch: \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
    exit(1)
}

let region = crop ?? (0, 0, a.width, a.height)
var exact = 0, within = 0, far = 0, total = 0
var sum = 0.0
var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
var diffPixels = [UInt8](repeating: 0, count: a.width * a.height * 4)

for y in region.y..<min(a.height, region.y + region.h) {
    for x in region.x..<min(a.width, region.x + region.w) {
        let index = (y * a.width + x) * 4
        var worst = 0
        for channel in 0..<3 {
            worst = max(worst, abs(Int(a.pixels[index + channel]) - Int(b.pixels[index + channel])))
        }
        total += 1
        sum += Double(worst)
        if worst == 0 {
            exact += 1
            let grey = UInt8(Int(a.pixels[index]) / 4)
            diffPixels[index] = grey; diffPixels[index + 1] = grey
            diffPixels[index + 2] = grey; diffPixels[index + 3] = 255
        } else if worst <= tolerance {
            within += 1
            diffPixels[index] = 0; diffPixels[index + 1] = 120
            diffPixels[index + 2] = 0; diffPixels[index + 3] = 255
        } else {
            far += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            diffPixels[index] = 255; diffPixels[index + 1] = 0
            diffPixels[index + 2] = 0; diffPixels[index + 3] = 255
        }
    }
}

// Which of the two carries more ink in the compared region. A renderer whose
// glyphs are systematically lighter than the other's is a different fault
// from one whose glyphs are in the wrong place, and the two are
// indistinguishable in a count of differing pixels.
var inkA = 0.0, inkB = 0.0
for y in region.y..<min(a.height, region.y + region.h) {
    for x in region.x..<min(a.width, region.x + region.w) {
        let index = (y * a.width + x) * 4
        for channel in 0..<3 {
            inkA += Double(a.pixels[index + channel])
            inkB += Double(b.pixels[index + channel])
        }
    }
}

func percent(_ value: Int) -> String {
    String(format: "%.3f%%", Double(value) * 100 / Double(max(1, total)))
}
print("pixels     \(total) in \(region.w)x\(region.h) at \(region.x),\(region.y)")
print("exact      \(exact)  \(percent(exact))")
print("within \(tolerance)   \(within)  \(percent(within))")
print("far        \(far)  \(percent(far))")
print(String(format: "mean diff  %.4f levels", sum / Double(max(1, total))))
let samples = Double(max(1, total)) * 3
print(String(format: "mean level %.3f (a) vs %.3f (b) — a is %+.2f%% brighter",
             inkA / samples, inkB / samples,
             inkB > 0 ? (inkA - inkB) * 100 / inkB : 0))
if far > 0 {
    print("far region \(minX),\(minY) to \(maxX),\(maxY)")
}

if let out, let provider = CGDataProvider(data: Data(diffPixels) as CFData),
   let image = CGImage(width: a.width, height: a.height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: a.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent) {
    let rep = NSBitmapImageRep(cgImage: image)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: out))
        print("diff image \(out)   (grey = identical, green = within tolerance, red = far)")
    }
}
exit(far > 0 ? 1 : 0)
