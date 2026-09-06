//  GlyphAtlas.swift — every character the terminal has drawn, once, on the GPU.
//
//  The whole point of the atlas is that rasterising a glyph is expensive and
//  drawing one is not. A terminal draws the same eighty characters over and
//  over, so the second time an `a` appears it costs a rectangle and two
//  triangles; CoreText is never asked again.
//
//  Colour is not a special case bolted on: emoji come out of CoreText already
//  coloured, so the atlas is BGRA and each entry records whether its pixels
//  ARE the colour (an emoji) or a mask to be tinted (ordinary text). That is
//  the whole of ISC-23 — a family emoji is one cluster, one entry, one cell.

import AppKit
import CoreText
import Metal

struct GlyphEntry {
    /// Position in the atlas, in normalised texture coordinates.
    var uv: SIMD4<Float>
    /// Where the bitmap goes relative to the glyph's origin on the baseline,
    /// in backing pixels: x to the right, y UP from the baseline to the top
    /// of the bitmap.
    var bearingX: Float
    var bearingTop: Float
    var width: Float
    var height: Float
    /// True when the pixels are the colour (emoji); false when they are a
    /// coverage mask to be painted in the cell's foreground colour.
    var isColoured: Bool
}

/// The four shapes one family comes in. Bold and italic are separate
/// rasterisations, not a synthetic slant.
struct GlyphKey: Hashable {
    var cluster: String
    var style: UInt8
}

@MainActor
final class GlyphAtlas {
    static let side = 2048

    private let device: MTLDevice
    private(set) var texture: MTLTexture
    private var entries: [GlyphKey: GlyphEntry] = [:]
    /// The fast lane. A terminal is mostly ASCII, and a dictionary lookup on a
    /// String key for every cell of every frame is most of the CPU budget of
    /// ISC-37: measured, the array lane is the difference between fitting in
    /// half a millisecond and not.
    private var ascii: [GlyphEntry?]
    private var asciiPresent: [Bool]

    private var fonts: [NSFont]
    private var scale: CGFloat

    // Shelf packing: glyphs go left to right on a shelf, and a new shelf
    // starts above the tallest thing on the last one.
    private var penX = 1
    private var penY = 1
    private var shelfHeight = 0

    private(set) var glyphCount = 0
    private(set) var colouredGlyphCount = 0
    private(set) var resetCount = 0

    init?(device: MTLDevice, font: NSFont, scale: CGFloat) {
        self.device = device
        self.scale = scale
        self.fonts = Self.variants(of: font)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.side, height: Self.side, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
        ascii = Array(repeating: nil, count: 128 * 4)
        asciiPresent = Array(repeating: false, count: 128 * 4)
        clear()
    }

    func setFont(_ font: NSFont, scale: CGFloat) {
        fonts = Self.variants(of: font)
        self.scale = scale
        clear()
    }

    /// Metrics every renderer needs, computed the way the engine computes
    /// them: ascent + descent + leading for the height, the advance of `W`
    /// for the width, both snapped to the pixel grid. A cell size derived a
    /// second, slightly different way puts the GPU's text a fraction of a
    /// pixel off the CPU's, which is precisely what the fidelity check looks
    /// for.
    static func cellSize(for font: NSFont, scale: CGFloat) -> CGSize {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let height = ceil(ascent + descent + leading)
        let glyph = font.glyph(withName: "W")
        let width = font.advancement(forGlyph: glyph).width
        return CGSize(width: max(1, (width * scale).rounded() / scale),
                      height: max(1, ceil(height * scale) / scale))
    }

    /// Distance from the bottom of a cell up to the text baseline.
    static func baselineOffset(for font: NSFont) -> CGFloat {
        ceil(CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    private static func variants(of font: NSFont) -> [NSFont] {
        let manager = NSFontManager.shared
        let bold = manager.convert(font, toHaveTrait: .boldFontMask)
        let italic = manager.convert(font, toHaveTrait: .italicFontMask)
        let boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)
        return [font, bold, italic, boldItalic]
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
        for index in ascii.indices { ascii[index] = nil; asciiPresent[index] = false }
        penX = 1
        penY = 1
        shelfHeight = 0
        glyphCount = 0
        colouredGlyphCount = 0
        // A cleared atlas has to BE clear: a stale pixel from the last font
        // shows up as a ghost stroke on the edge of a new glyph.
        let bytes = [UInt8](repeating: 0, count: Self.side * 4)
        for row in 0..<Self.side {
            texture.replace(region: MTLRegionMake2D(0, row, Self.side, 1), mipmapLevel: 0,
                            withBytes: bytes, bytesPerRow: Self.side * 4)
        }
    }

    /// The entry for one grapheme cluster in one style, rasterising it the
    /// first time it is ever asked for.
    func entry(for character: Character, style: UInt8) -> GlyphEntry? {
        if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
           scalar.value < 128 {
            let index = Int(scalar.value) + Int(style) * 128
            if asciiPresent[index] { return ascii[index] }
            let made = rasterise(String(character), style: style)
            asciiPresent[index] = true
            ascii[index] = made
            return made
        }
        let key = GlyphKey(cluster: String(character), style: style)
        if let found = entries[key] { return found }
        let made = rasterise(key.cluster, style: style)
        entries[key] = made ?? GlyphEntry(uv: .zero, bearingX: 0, bearingTop: 0,
                                          width: 0, height: 0, isColoured: false)
        return made
    }

    private func rasterise(_ cluster: String, style: UInt8) -> GlyphEntry? {
        if cluster == " " || cluster.isEmpty { return nil }
        let font = fonts[Int(style) & 3]
        // The glyph is rasterised at BACKING resolution: the renderer works
        // in device pixels throughout, so nothing is ever resampled and the
        // sampler can stay on nearest.
        let scaled = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
        let attributed = NSAttributedString(string: cluster, attributes: [.font: scaled])
        let line = CTLineCreateWithAttributedString(attributed)
        var bounds = CTLineGetImageBounds(line, nil)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        bounds = bounds.insetBy(dx: -1, dy: -1)

        let width = Int(ceil(bounds.width)) + 1
        let height = Int(ceil(bounds.height)) + 1
        guard width < Self.side, height < Self.side else { return nil }

        var coloured = false
        if let runs = CTLineGetGlyphRuns(line) as? [CTRun], let first = runs.first {
            let attributes = CTRunGetAttributes(first) as NSDictionary
            if let runFont = attributes[kCTFontAttributeName as String] {
                let traits = CTFontGetSymbolicTraits(runFont as! CTFont)
                coloured = traits.contains(.traitColorGlyphs)
            }
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colourSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = pixels.withUnsafeMutableBytes({ raw in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: colourSpace, bitmapInfo: info)
        }) else { return nil }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        // Grayscale antialiasing, like a layer-backed view: subpixel smoothing
        // would put colour fringes in a mask that is about to be tinted.
        context.setShouldSmoothFonts(false)
        if !coloured {
            context.setFillColor(NSColor.white.cgColor)
        }
        context.textPosition = CGPoint(x: -bounds.origin.x, y: -bounds.origin.y)
        CTLineDraw(line, context)

        guard let placement = allocate(width: width, height: height) else {
            // The atlas is full. Starting it over costs one frame of
            // re-rasterising and is bounded; growing it without limit is not.
            resetCount += 1
            clear()
            guard let retry = allocate(width: width, height: height) else { return nil }
            return store(pixels: pixels, at: retry, width: width, height: height,
                         bounds: bounds, coloured: coloured)
        }
        return store(pixels: pixels, at: placement, width: width, height: height,
                     bounds: bounds, coloured: coloured)
    }

    private func store(pixels: [UInt8], at placement: (x: Int, y: Int),
                       width: Int, height: Int, bounds: CGRect,
                       coloured: Bool) -> GlyphEntry {
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(placement.x, placement.y, width, height),
                            mipmapLevel: 0, withBytes: raw.baseAddress!,
                            bytesPerRow: width * 4)
        }
        glyphCount += 1
        if coloured { colouredGlyphCount += 1 }
        let side = Float(Self.side)
        return GlyphEntry(
            uv: SIMD4<Float>(Float(placement.x) / side, Float(placement.y) / side,
                             Float(placement.x + width) / side,
                             Float(placement.y + height) / side),
            bearingX: Float(bounds.origin.x),
            bearingTop: Float(bounds.origin.y) + Float(height),
            width: Float(width), height: Float(height), isColoured: coloured)
    }

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        if penX + width + 1 > Self.side {
            penX = 1
            penY += shelfHeight + 1
            shelfHeight = 0
        }
        guard penY + height + 1 <= Self.side else { return nil }
        let spot = (x: penX, y: penY)
        penX += width + 1
        shelfHeight = max(shelfHeight, height)
        return spot
    }
}
