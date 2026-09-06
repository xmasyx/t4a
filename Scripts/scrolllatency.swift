//  scrolllatency.swift — pixels in, ScreenCaptureKit frames out, for any app.
//
//  Build:
//    swiftc -parse-as-library -O -o Scripts/.build-scrolllatency \
//      Scripts/scrolllatency.swift Sources/AgentAdapters/ScrollMeterSummary.swift
//  Run:
//    Scripts/.build-scrolllatency app=<bundle id> x=<px> y=<px>
//      [pid=<pid>] [frame=x,y,w,h] [events=120] [pixels=3]
//      [intervalMs=8.33] [captureHz=240] [json]

import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

struct Arguments {
    let bundleID: String
    let point: CGPoint
    let windowFrame: CGRect?
    let events: Int
    let pixels: Int32
    let intervalMs: Double
    let captureHz: Double
    let json: Bool

    static func parse() -> Arguments? {
        var values: [String: String] = [:]
        var json = false
        for argument in CommandLine.arguments.dropFirst() {
            if argument == "json" { json = true; continue }
            let parts = argument.split(separator: "=", maxSplits: 1,
                                       omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            values[String(parts[0])] = String(parts[1])
        }
        guard let bundleID = values["app"], !bundleID.isEmpty,
              let x = values["x"].flatMap(Double.init), x.isFinite,
              let y = values["y"].flatMap(Double.init), y.isFinite,
              let events = Int(values["events"] ?? "120"), events > 0,
              let pixelsValue = Int(values["pixels"] ?? "3"), pixelsValue != 0,
              pixelsValue >= Int(Int32.min), pixelsValue <= Int(Int32.max),
              let intervalMs = Double(values["intervalMs"] ?? "8.33"),
              intervalMs.isFinite, intervalMs > 0,
              let captureHz = Double(values["captureHz"] ?? "240"),
              captureHz.isFinite, captureHz > 0 else { return nil }

        var windowFrame: CGRect?
        if let raw = values["frame"] {
            let fields = raw.split(separator: ",", omittingEmptySubsequences: false)
                .compactMap { Double($0) }
            guard fields.count == 4, fields.allSatisfy(\.isFinite),
                  fields[2] > 1, fields[3] > 1 else { return nil }
            windowFrame = CGRect(x: fields[0], y: fields[1],
                                 width: fields[2], height: fields[3])
        }
        let known = Set(["app", "pid", "x", "y", "frame", "events", "pixels",
                         "intervalMs", "captureHz"])
        guard values.keys.allSatisfy(known.contains) else { return nil }
        return Arguments(bundleID: bundleID, point: CGPoint(x: x, y: y),
                         windowFrame: windowFrame, events: events,
                         pixels: Int32(pixelsValue), intervalMs: intervalMs,
                         captureHz: captureHz, json: json)
    }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func notRun(_ reason: String) -> Never {
    print("NOT RUN: \(reason)")
    exit(3)
}

struct Monotonic {
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    static func now() -> UInt64 { mach_absolute_time() }

    static func ticks(seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    static func wait(until deadline: UInt64) {
        if deadline > now() { mach_wait_until(deadline) }
    }
}

func hostMilliseconds() -> Double {
    CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1_000
}

struct WindowTarget {
    let id: CGWindowID
    let bounds: CGRect
}

func frontWindow(for pid: pid_t) -> WindowTarget? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    for item in list {
        guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let number = item[kCGWindowNumber as String] as? NSNumber,
              let dictionary = item[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary),
              bounds.width > 1, bounds.height > 1 else { continue }
        return WindowTarget(id: CGWindowID(number.uint32Value), bounds: bounds)
    }
    return nil
}

func accessibilityWindow(for pid: pid_t) -> AXUIElement? {
    let application = AXUIElementCreateApplication(pid)
    var focused: CFTypeRef?
    if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString,
                                     &focused) == .success,
       let focused {
        return (focused as! AXUIElement)
    }
    var windowsValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString,
                                        &windowsValue) == .success,
          let windows = windowsValue as? [AXUIElement] else { return nil }
    return windows.first
}

func resizeFrontWindow(of pid: pid_t, to frame: CGRect) -> Bool {
    guard AXIsProcessTrusted(), let window = accessibilityWindow(for: pid) else { return false }
    var size = frame.size
    var position = frame.origin
    guard let sizeValue = AXValueCreate(.cgSize, &size),
          let positionValue = AXValueCreate(.cgPoint, &position),
          AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString,
                                       sizeValue) == .success,
          AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString,
                                       positionValue) == .success else { return false }
    usleep(250_000)

    var readPositionValue: CFTypeRef?
    var readSizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString,
                                        &readPositionValue) == .success,
          AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString,
                                        &readSizeValue) == .success,
          let readPositionValue, let readSizeValue,
          CFGetTypeID(readPositionValue) == AXValueGetTypeID(),
          CFGetTypeID(readSizeValue) == AXValueGetTypeID() else { return false }
    var actualPosition = CGPoint.zero
    var actualSize = CGSize.zero
    guard AXValueGetValue(readPositionValue as! AXValue, .cgPoint, &actualPosition),
          AXValueGetValue(readSizeValue as! AXValue, .cgSize, &actualSize) else { return false }
    let tolerance: CGFloat = 2
    return abs(actualPosition.x - frame.origin.x) <= tolerance
        && abs(actualPosition.y - frame.origin.y) <= tolerance
        && abs(actualSize.width - frame.width) <= tolerance
        && abs(actualSize.height - frame.height) <= tolerance
}

func isBlack(_ pixelBuffer: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return true }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for row in 0..<height {
        let bytes = base.advanced(by: row * bytesPerRow)
            .assumingMemoryBound(to: UInt8.self)
        for column in 0..<width {
            let pixel = column * 4
            if bytes[pixel] != 0 || bytes[pixel + 1] != 0 || bytes[pixel + 2] != 0 {
                return false
            }
        }
    }
    return true
}

/// FNV-1a over every 4th row and every 4th pixel of the BGRA buffer: about
/// 50k pixels per frame at 1200x700, cheap enough for 120 Hz, and any scroll
/// of a text window moves glyph edges through that lattice.
func stripHash(_ pixelBuffer: CVPixelBuffer) -> UInt64 {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    var hash: UInt64 = 0xcbf29ce484222325
    var row = 0
    while row < height {
        let bytes = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt32.self)
        var column = 0
        while column < width {
            hash = (hash ^ UInt64(bytes[column])) &* 0x100000001b3
            column += 4
        }
        row += 4
    }
    return hash
}

struct SampleSnapshot {
    let timestamps: [Double]
    let dirtyTimestamps: [Double]
    let firstFrameWasBlack: Bool?
    let contentRect: CGRect?
    let stoppedWithError: Bool
}

final class StreamSampler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let firstFrame = DispatchSemaphore(value: 0)
    private var signalledFirstFrame = false
    private var timestamps: [Double] = []
    private var dirtyTimestamps: [Double] = []
    private var firstFrameWasBlack: Bool?
    private var contentRect: CGRect?
    private var stoppedWithError = false
    private var lastHash: UInt64?

    private static func rect(_ value: Any?) -> CGRect? {
        if let rect = value as? CGRect { return rect }
        if let dictionary = value as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: dictionary) { return rect }
        return nil
    }

    private static func rects(_ value: Any?) -> [CGRect] {
        if let rects = value as? [CGRect] { return rects }
        if let list = value as? [Any] { return list.compactMap { rect($0) } }
        return []
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachment = attachments.first,
              let statusRaw = attachment[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete else { return }
        let presentation = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            * 1_000
        guard presentation.isFinite else { return }
        // ScreenCaptureKit attaches rects as CFDictionary representations,
        // not as CGRect values: `as? CGRect` was always nil and `as? [CGRect]`
        // always empty (measured 30/08: control frame with contentRect=nil on
        // a live window, and no frame would ever have counted as dirty).
        let dirtyRects = Self.rects(attachment[.dirtyRects])
        let frameContentRect = Self.rect(attachment[.contentRect])

        var black: Bool?
        lock.lock()
        let needsBlackControl = firstFrameWasBlack == nil
        lock.unlock()
        var hash: UInt64?
        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            if needsBlackControl { black = isBlack(buffer) }
            hash = stripHash(buffer)
        }

        lock.lock()
        timestamps.append(presentation)
        // A distinct frame is one whose PIXELS differ from the previous one.
        // `dirtyRects` is not that: measured 30/08, a window that did not
        // scroll at all (HEAD, 0 rows moved, renderer 0 frames) still came
        // with 111 "dirty" frames a second, one per delivered sample. The
        // attachment says the compositor delivered, not that anything changed.
        _ = dirtyRects
        if let hash, hash != lastHash {
            if lastHash != nil { dirtyTimestamps.append(presentation) }
            lastHash = hash
        }
        if let frameContentRect { contentRect = frameContentRect }
        if firstFrameWasBlack == nil { firstFrameWasBlack = black }
        if !signalledFirstFrame {
            signalledFirstFrame = true
            firstFrame.signal()
        }
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        stoppedWithError = true
        if !signalledFirstFrame {
            signalledFirstFrame = true
            firstFrame.signal()
        }
        lock.unlock()
    }

    func waitForFirstFrame(seconds: Double) -> Bool {
        firstFrame.wait(timeout: .now() + seconds) == .success
    }

    var snapshot: SampleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return SampleSnapshot(timestamps: timestamps,
                              dirtyTimestamps: dirtyTimestamps,
                              firstFrameWasBlack: firstFrameWasBlack,
                              contentRect: contentRect,
                              stoppedWithError: stoppedWithError)
    }
}

final class EventResult: @unchecked Sendable {
    private let lock = NSLock()
    private var firstValue: Double?
    private var lastValue: Double?
    private var failedValue = false

    func note(time: Double) {
        lock.lock()
        if firstValue == nil { firstValue = time }
        lastValue = time
        lock.unlock()
    }

    func fail() {
        lock.lock(); failedValue = true; lock.unlock()
    }

    var snapshot: (first: Double?, last: Double?, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (firstValue, lastValue, failedValue)
    }
}

func number(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "null" }
    return String(format: "%.3f", value)
}

func jsonString(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

@main
struct ScrollLatency {
    static func main() async {
        guard let arguments = Arguments.parse() else {
            fail("usage: scrolllatency app=<bundle id> x=<px> y=<px> [pid=<pid>] "
                 + "[frame=x,y,w,h] [events=120] [pixels=3] [intervalMs=8.33] "
                 + "[captureHz=240] [json]", code: 2)
        }
        guard #available(macOS 12.3, *) else { notRun("screen recording — macOS too old") }

        // `pid=` beats the bundle id: two copies with the same bundle id make
        // a bundle lookup choose a window that was never part of the bench.
        let pidArgument = CommandLine.arguments.first(where: { $0.hasPrefix("pid=") })
            .flatMap { Int32($0.dropFirst(4)) }
        let app: NSRunningApplication
        if let pidArgument {
            guard let byPID = NSRunningApplication(processIdentifier: pidArgument) else {
                fail("no running app with pid \(pidArgument)")
            }
            app = byPID
        } else {
            let matches = NSRunningApplication.runningApplications(
                withBundleIdentifier: arguments.bundleID)
            guard let byBundle = matches.first(where: \.isActive) ?? matches.first else {
                fail("no running app \(arguments.bundleID)")
            }
            app = byBundle
        }
        app.activate(options: [.activateAllWindows])
        usleep(200_000)

        if let requestedFrame = arguments.windowFrame,
           !resizeFrontWindow(of: app.processIdentifier, to: requestedFrame) {
            notRun("accessibility")
        }
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: arguments.point, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        usleep(100_000)

        guard let target = frontWindow(for: app.processIdentifier) else {
            fail("no on-screen layer-0 window for \(arguments.bundleID)")
        }
        guard CGPreflightScreenCaptureAccess() else { notRun("screen recording — CGPreflightScreenCaptureAccess false") }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            notRun("screen recording — SCShareableContent threw: \(error)")
        }
        guard let window = content.windows.first(where: { $0.windowID == target.id }) else {
            notRun("screen recording — window not in shareable content")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        // The whole equal-sized window is captured at its native scale. No
        // app-specific strip or downscale can make one side cheaper.
        let scale = max(1, CGFloat(filter.pointPixelScale))
        configuration.width = max(1, Int((target.bounds.width * scale).rounded()))
        configuration.height = max(1, Int((target.bounds.height * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let sampler = StreamSampler()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sampler)
        let sampleQueue = DispatchQueue(label: "t4a.scroll-meter.samples",
                                        qos: .userInteractive)
        do {
            try stream.addStreamOutput(sampler, type: .screen,
                                       sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            notRun("screen recording — startCapture threw: \(error)")
        }
        guard sampler.waitForFirstFrame(seconds: 2) else {
            try? await stream.stopCapture()
            notRun("screen recording — no first frame within 2 s")
        }
        let control = sampler.snapshot
        guard !control.stoppedWithError, control.contentRect != nil else {
            try? await stream.stopCapture()
            notRun("screen recording — control frame: stoppedWithError=\(control.stoppedWithError) contentRect=\(String(describing: control.contentRect))")
        }
        guard control.firstFrameWasBlack != true else {
            try? await stream.stopCapture()
            print("NOT RUN: display off")
            exit(3)
        }

        let intervalTicks = Monotonic.ticks(seconds: arguments.intervalMs / 1_000)
        let start = Monotonic.now() + Monotonic.ticks(seconds: 0.050)
        let plannedEnd = start + UInt64(arguments.events - 1) * intervalTicks
        let captureEnd = plannedEnd + Monotonic.ticks(seconds: 0.300)
        let eventResult = EventResult()
        let eventsDone = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInteractive).async {
            for index in 0..<arguments.events {
                Monotonic.wait(until: start + UInt64(index) * intervalTicks)
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 1, wheel1: arguments.pixels,
                                          wheel2: 0, wheel3: 0) else {
                    eventResult.fail()
                    break
                }
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.location = arguments.point
                eventResult.note(time: hostMilliseconds())
                event.post(tap: .cghidEventTap)
            }
            if let ended = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                   wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) {
                ended.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                ended.location = arguments.point
                ended.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
                ended.post(tap: .cghidEventTap)
            }
            eventsDone.signal()
        }

        Monotonic.wait(until: captureEnd)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                eventsDone.wait()
                continuation.resume()
            }
        }
        try? await stream.stopCapture()
        let samples = sampler.snapshot
        guard !samples.stoppedWithError else { notRun("screen recording — stream stopped with error during the gesture") }

        let posted = eventResult.snapshot
        guard !posted.failed, let firstEvent = posted.first, let lastEvent = posted.last else {
            fail("could not create the requested scroll event stream")
        }
        let expectedLastEvent = firstEvent + Double(arguments.events - 1) * arguments.intervalMs
        let gestureEnd = max(lastEvent, expectedLastEvent)
        let dirtyDuringGesture = samples.dirtyTimestamps.filter {
            $0 >= firstEvent && $0 <= gestureEnd
        }
        let summary = ScrollMeterSummary.reduce(timestamps: dirtyDuringGesture,
                                                firstEventAt: firstEvent)
        let frameTimestamps = dirtyDuringGesture.sorted().prefix(400).map { $0 - firstEvent }

        let orderedSamples = Array(Set(samples.timestamps.filter(\.isFinite))).sorted()
        let sampleSpan = orderedSamples.count > 1
            ? (orderedSamples.last! - orderedSamples.first!) / 1_000 : 0
        let sampleHzReal = sampleSpan > 0
            ? Double(orderedSamples.count - 1) / sampleSpan : 0

        if arguments.json {
            let timestampsJSON = frameTimestamps.map { number($0) }.joined(separator: ",")
            print("{\"app\":\"\(jsonString(arguments.bundleID))\","
                  + "\"events\":\(arguments.events),\"pixels\":\(arguments.pixels),"
                  + "\"intervalMs\":\(number(arguments.intervalMs)),"
                  + "\"captureHzRequested\":\(number(arguments.captureHz)),"
                  + "\"distinctFrames\":\(summary.distinct),"
                  + "\"firstChangeMs\":\(number(summary.firstChange)),"
                  + "\"maxGapMs\":\(number(summary.maxGap)),"
                  + "\"captures\":\(orderedSamples.count),"
                  + "\"captureHzReal\":\(number(sampleHzReal)),"
                  + "\"sampleHzReal\":\(number(sampleHzReal)),"
                  + "\"frameTimestamps\":[\(timestampsJSON)]}")
        } else {
            print("app: \(arguments.bundleID)")
            print("window: \(target.id) frame=\(Int(target.bounds.minX)),"
                  + "\(Int(target.bounds.minY)),\(Int(target.bounds.width)),"
                  + "\(Int(target.bounds.height))")
            print("distinctFrames: \(summary.distinct)")
            print("firstChangeMs: \(number(summary.firstChange))")
            print("maxGapMs: \(number(summary.maxGap))")
            print("captures: \(orderedSamples.count)")
            print("captureHzReal: \(number(sampleHzReal))")
            print("sampleHzReal: \(number(sampleHzReal))")
            print("frameTimestamps: [\(frameTimestamps.map { number($0) }.joined(separator: ","))]")
        }
    }
}
