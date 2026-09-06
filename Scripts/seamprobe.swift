//  seamprobe.swift — does a seam read as a vertical monochrome rule? (ISC-124)
//
//  Usage:
//    seamprobe <shot.png> <winX,winY,winW,winH> <label,x,y,w,h> [<label,x,y,w,h> …]
//
//  The window frame and each seam rectangle are given in SCREEN POINTS, x/y at
//  the rectangle's CENTRE, exactly as the app's own dump reports them — so the
//  probe never re-derives a layout the app already knows, which is how a probe
//  ends up measuring itself.
//
//  TWO NOTES PAID FOR ON 22/08, and between them they are the reason this file
//  measures a SHARE and not a difference. Both were green lights on a broken
//  measurement, which is worse than a red one.
//
//  1. `screencapture` dithers. A rectangle the app filled with one colour can
//     come back with twenty-five distinct values in a single column, each
//     within a level of the others, because the picture is colour-managed on
//     its way out of the window server. So "are these pixels identical" — the
//     first thing this probe asked — answered NO on the very bar the principal
//     was pointing at.
//  2. Asking instead whether the WORST pixel strays from the mean answered no
//     as well, for a better reason and with the same uselessness: the HEAD
//     seam column measured `#242424` in 1485 rows of 1486 and `#1A1A1A` in
//     the single last one, where the seam meets the dashboard. One boundary
//     pixel, and a max-deviation test called a solid three-point bar "not
//     flat".
//
//  What survives both is the DOMINANT COLOUR'S SHARE: a column is flat when
//  at least `share` of its pixels sit within `dither` levels of its most
//  common value. The bar of HEAD scores 0.999. A falloff cannot, because its
//  pixels are spread over the tones it fades through — and it is the share
//  that gets printed, so the verdict is a number a person can check.
//
//  Two questions are then asked of every seam, and they are not the same:
//
//    flat     Is there a column, inside the seam's own rectangle, that is one
//             colour from the top of the seam to the bottom? That is the
//             literal falsifier ISC-124 names — reported, and NOT the gate.
//             See the note in the ISA's Decisions of 22/08: a seam drawn as
//             the principal's first option, invisible, is flat by definition
//             because it is the page, so that test alone would forbid the
//             thing it was written to allow.
//
//    rule     Widening the look a few points either side, is there a THIN run
//             of such columns — twelve pixels or less — whose colour steps
//             away from what lies immediately outside it on BOTH sides? That
//             is what "a vertical monochrome line" means to an eye. A panel
//             body is flat too and is not a line, because it is wide; a tonal
//             step between two grounds is a step, not a rule, because it is
//             flat on both sides of the boundary and neither run is thin.

import AppKit

struct Seam { let label: String; let rect: CGRect }
typealias Colour = (r: Double, g: Double, b: Double)

let arguments = CommandLine.arguments
guard arguments.count >= 4, let image = NSImage(contentsOfFile: arguments[1]),
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("usage: seamprobe <png> <win> <seam…>\n".utf8))
    exit(2)
}

func numbers(_ text: String) -> [Double] {
    text.split(separator: ",").compactMap { Double($0) }
}
let windowNumbers = numbers(arguments[2])
guard windowNumbers.count == 4 else {
    FileHandle.standardError.write(Data("the window frame wants x,y,w,h\n".utf8)); exit(2)
}
let window = CGRect(x: windowNumbers[0], y: windowNumbers[1],
                    width: windowNumbers[2], height: windowNumbers[3])

var seams: [Seam] = []
for argument in arguments.dropFirst(3) {
    let parts = argument.split(separator: ",", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    let n = numbers(parts[1])
    guard n.count == 4 else { continue }
    // x,y are the CENTRE, the way the app reports a view's rectangle.
    seams.append(Seam(label: parts[0],
                      rect: CGRect(x: n[0] - n[2] / 2, y: n[1] - n[3] / 2,
                                   width: n[2], height: n[3])))
}
guard !seams.isEmpty else {
    FileHandle.standardError.write(Data("no seam to look at\n".utf8)); exit(2)
}

// The picture is of the window alone, so its scale is its own width against
// the window's. Read rather than assumed: a 1x display and a 2x one both come
// through here and only the picture knows which.
let scale = Double(source.width) / window.width
guard let data = source.dataProvider?.data,
      let bytes = CFDataGetBytePtr(data) else { exit(3) }
let rowBytes = source.bytesPerRow
let pixelBytes = source.bitsPerPixel / 8

func pixel(_ x: Int, _ y: Int) -> Colour {
    let offset = y * rowBytes + x * pixelBytes
    switch source.alphaInfo {
    case .first, .premultipliedFirst, .noneSkipFirst:
        return (Double(bytes[offset + 1]), Double(bytes[offset + 2]), Double(bytes[offset + 3]))
    default:
        return (Double(bytes[offset]), Double(bytes[offset + 1]), Double(bytes[offset + 2]))
    }
}
func distance(_ a: Colour, _ b: Colour) -> Double {
    max(abs(a.r - b.r), max(abs(a.g - b.g), abs(a.b - b.b)))
}
func hex(_ c: Colour) -> String {
    String(format: "#%02X%02X%02X", Int(c.r.rounded()), Int(c.g.rounded()), Int(c.b.rounded()))
}

func pixelBox(of rect: CGRect) -> (x0: Int, x1: Int, y0: Int, y1: Int) {
    let x0 = Int(((rect.minX - window.minX) * scale).rounded())
    let x1 = Int(((rect.maxX - window.minX) * scale).rounded())
    let y0 = Int(((window.maxY - rect.maxY) * scale).rounded())
    let y1 = Int(((window.maxY - rect.minY) * scale).rounded())
    return (max(0, x0), min(source.width, x1), max(0, y0), min(source.height, y1))
}

let dither = 2.0        // levels of noise the capture pipeline adds to a flat fill
let flatShare = 0.95    // of a column, held by one colour, before it is a bar
let step = 6.0          // a tonal step an eye can see, in 0…255
let thinnest = 12       // pixels: wider than this is a surface, not a line
let widen = 4.0         // points looked at either side of the seam itself
var failures = 0

print("picture \(source.width)x\(source.height)  window \(Int(window.width))x\(Int(window.height)) pt"
    + "  scale \(String(format: "%.2f", scale))x  dither ±\(Int(dither))  flat at \(flatShare)")

for seam in seams {
    let own = pixelBox(of: seam.rect)
    guard own.x1 > own.x0, own.y1 > own.y0 else {
        print("\(seam.label): the seam is not inside the picture"); failures += 1; continue
    }
    let band = pixelBox(of: seam.rect.insetBy(dx: -widen, dy: 0))

    // For each column over the SEAM'S OWN height: its most common colour, and
    // the share of the column that colour holds (within the dither).
    var mode: [Int: Colour] = [:]
    var share: [Int: Double] = [:]
    for x in band.x0..<band.x1 {
        var tally: [Int: (colour: Colour, count: Int)] = [:]
        for y in own.y0..<own.y1 {
            let p = pixel(x, y)
            let key = (Int(p.r) << 16) | (Int(p.g) << 8) | Int(p.b)
            tally[key] = (p, (tally[key]?.count ?? 0) + 1)
        }
        guard let top = tally.values.max(by: { $0.count < $1.count }) else { continue }
        var held = 0
        for y in own.y0..<own.y1 where distance(pixel(x, y), top.colour) <= dither { held += 1 }
        mode[x] = top.colour
        share[x] = Double(held) / Double(own.y1 - own.y0)
    }
    func flat(_ x: Int) -> Bool { (share[x] ?? 0) >= flatShare }

    let flatInside = (own.x0..<own.x1).filter(flat)

    // Runs of adjacent flat columns that are THE SAME colour — each column
    // compared with the one beside it, within the dither and nothing wider.
    //
    // A third thing measured and then fixed on 22/08: comparing each column
    // with the run's FIRST one instead, at the `step` tolerance, swallowed a
    // ramp whole. The warm-paper seam fades #D5D2CD → #D7D4CF → #D8D6D1 → …,
    // fifteen levels over six columns, and every one of them sits within six
    // of the first — so a falloff came out as "6px of #D5D2CD", which is the
    // one thing it is not. Monochrome means the columns match each other, not
    // that they are in the same neighbourhood as the one that started the run.
    var runs: [(from: Int, to: Int, colour: Colour)] = []
    var x = band.x0
    while x < band.x1 {
        guard flat(x), let colour = mode[x] else { x += 1; continue }
        var end = x
        while end + 1 < band.x1, flat(end + 1), let next = mode[end + 1],
              let here = mode[end], distance(next, here) <= dither { end += 1 }
        runs.append((x, end, colour))
        x = end + 1
    }
    var rules: [String] = []
    for run in runs where (run.to - run.from + 1) <= thinnest {
        guard run.from - 1 >= band.x0 - 1, run.to + 1 < source.width else { continue }
        let middle = (own.y0 + own.y1) / 2
        // Outside the run, sampled as a short average so the dither does not
        // decide whether a step is a step.
        func outside(_ at: Int) -> Colour {
            var sum: Colour = (0, 0, 0); var n = 0.0
            for y in (middle - 20)...(middle + 20) where y >= own.y0 && y < own.y1 {
                let p = pixel(at, y); sum = (sum.r + p.r, sum.g + p.g, sum.b + p.b); n += 1
            }
            return (sum.r / n, sum.g / n, sum.b / n)
        }
        let left = outside(max(0, run.from - 1)), right = outside(run.to + 1)
        let smallest = min(distance(run.colour, left), distance(run.colour, right))
        if smallest > step {
            rules.append(String(format: "%dpx of %@ between %@ and %@, step %.0f",
                                run.to - run.from + 1, hex(run.colour), hex(left), hex(right),
                                smallest))
        }
    }
    // The GATE is the rule, not the flatness: see the header.
    let verdict = rules.isEmpty ? "ok" : "FOUND A RULE"
    print("\(seam.label): seam x \(own.x0)…\(own.x1)px, rows \(own.y0)…\(own.y1)px")
    // The colours actually found, printed beside the count: a number without
    // the thing it counted cannot be checked by a person.
    let sampled = (band.x0..<band.x1).map {
        String(format: "%@%@·%.2f", flat($0) ? "" : "~", hex(mode[$0]!), share[$0]!)
    }
    print("   columns (top colour · its share, ~ = not flat): \(sampled.joined(separator: " "))")
    print("   flat columns inside the seam: \(flatInside.count) of \(own.x1 - own.x0)"
        + " — reported, not gated")
    print("   monochrome rules in the band: \(rules.count)")
    for rule in rules { print("     · \(rule)") }
    print("   \(verdict)")
    if verdict != "ok" { failures += 1 }
}
exit(failures == 0 ? 0 : 1)
