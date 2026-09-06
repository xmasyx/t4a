// OCR and luminance probe for a screenshot.
//
//   imageprobe image.png
//
// JSON is printed so a GUI bench can prove that a captured Metal frame is
// neither black nor a different tab. Vision reads the pixels written by
// screencapture; it does not ask the application what it intended to draw.

import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count == 2,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: imageprobe image.png\n".utf8))
    exit(2)
}

var proposed = NSRect(origin: .zero, size: image.size)
guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("imageprobe: cannot decode image\n".utf8))
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US"]
var ocrError = ""
do {
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
} catch {
    // OCR is supporting evidence. The luminance probe and the reference-frame
    // comparison used by bench-mem remain valid on a machine where Vision's
    // service is unavailable (for example inside a restricted CI sandbox).
    ocrError = String(describing: error)
}

let observations = (request.results ?? []).sorted { left, right in
    if abs(left.boundingBox.midY - right.boundingBox.midY) > 0.01 {
        return left.boundingBox.midY > right.boundingBox.midY
    }
    return left.boundingBox.minX < right.boundingBox.minX
}
let lines = observations.compactMap { $0.topCandidates(1).first?.string }

let width = cgImage.width
let height = cgImage.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let space = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(data: &pixels, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("imageprobe: cannot rasterise image\n".utf8))
    exit(1)
}
context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

var total = 0.0
var totalSquared = 0.0
var samples = 0
// Sampling every fourth pixel is over 100k samples on an ordinary Retina
// window and keeps this control much cheaper than the OCR above.
for y in stride(from: 0, to: height, by: 4) {
    for x in stride(from: 0, to: width, by: 4) {
        let offset = (y * width + x) * 4
        let luminance = (0.2126 * Double(pixels[offset])
            + 0.7152 * Double(pixels[offset + 1])
            + 0.0722 * Double(pixels[offset + 2])) / 255
        total += luminance
        totalSquared += luminance * luminance
        samples += 1
    }
}
let mean = samples > 0 ? total / Double(samples) : 0
let variance = samples > 0 ? max(0, totalSquared / Double(samples) - mean * mean) : 0
let result: [String: Any] = [
    "width": width,
    "height": height,
    "meanLuminance": mean,
    "luminanceStddev": variance.squareRoot(),
    "text": lines.joined(separator: "\n"),
    "ocrError": ocrError,
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
