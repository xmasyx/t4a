//  RenderStats.swift — the numbers F3 is measured on, counted where they
//  happen.
//
//  Three rules this file exists to keep. A frame time is the GPU's own clock
//  (`gpuEndTime - gpuStartTime`), not a stopwatch around the encode, which
//  measures the queue. A dropped frame is a gap in the sequence of vsyncs
//  actually served, not an impression of stutter. And the median is kept, not
//  the mean: one 12 ms hitch while the atlas fills would drag an average up
//  and hide four thousand honest frames.

import Foundation
import QuartzCore

final class RenderStats: @unchecked Sendable {
    private let lock = NSLock()

    private(set) var frames = 0
    private(set) var vsyncs = 0
    private(set) var skippedIdle = 0
    private(set) var noDrawable = 0
    private(set) var wheelEvents = 0
    private(set) var immediateDraws = 0
    private var gpuSamples: [Double] = []
    private var cpuSamples: [Double] = []
    private var waitSamples: [Double] = []
    /// Time spent turning the grid into instances, apart from encoding it.
    private var buildSamples: [Double] = []
    private var wheelSamples: [Double] = []
    private var wheelScrollToSamples: [Double] = []
    private var wheelSettleSamples: [Double] = []
    private var drawSamples: [Double] = []
    private var vsyncTimes: [Double] = []
    private var presentedTimes: [Double] = []
    /// Time from making a previously hidden drawable pool full-sized again
    /// to the first frame from that pool reaching the display.
    private var resumeSamples: [Double] = []
    private(set) var instances = 0
    private var started = CACurrentMediaTime()

    private static let maxSamples = 200_000

    func reset() {
        lock.lock(); defer { lock.unlock() }
        frames = 0; vsyncs = 0; skippedIdle = 0; noDrawable = 0; instances = 0
        wheelEvents = 0; immediateDraws = 0
        gpuSamples.removeAll(keepingCapacity: true)
        cpuSamples.removeAll(keepingCapacity: true)
        waitSamples.removeAll(keepingCapacity: true)
        buildSamples.removeAll(keepingCapacity: true)
        wheelSamples.removeAll(keepingCapacity: true)
        wheelScrollToSamples.removeAll(keepingCapacity: true)
        wheelSettleSamples.removeAll(keepingCapacity: true)
        drawSamples.removeAll(keepingCapacity: true)
        vsyncTimes.removeAll(keepingCapacity: true)
        presentedTimes.removeAll(keepingCapacity: true)
        resumeSamples.removeAll(keepingCapacity: true)
        started = CACurrentMediaTime()
    }

    func noteVsync(at time: Double) {
        lock.lock(); defer { lock.unlock() }
        vsyncs += 1
        if vsyncTimes.count < Self.maxSamples { vsyncTimes.append(time) }
    }

    func noteIdleSkip() { lock.lock(); skippedIdle += 1; lock.unlock() }
    func noteNoDrawable() { lock.lock(); noDrawable += 1; lock.unlock() }
    func noteImmediateDraw() { lock.lock(); immediateDraws += 1; lock.unlock() }

    func noteWheel(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        wheelEvents += 1
        if wheelSamples.count < Self.maxSamples { wheelSamples.append(seconds) }
    }

    func noteWheelScrollTo(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        if wheelScrollToSamples.count < Self.maxSamples {
            wheelScrollToSamples.append(seconds)
        }
    }

    func noteWheelSettle(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        if wheelSettleSamples.count < Self.maxSamples { wheelSettleSamples.append(seconds) }
    }

    func noteDraw(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        if drawSamples.count < Self.maxSamples { drawSamples.append(seconds) }
    }

    /// `cpu` is work; `waited` is the block on the display handing over a
    /// drawable, which is pacing rather than cost. They are kept apart
    /// because adding them together produces a number that looks like a
    /// renderer being slow and is in fact a display being punctual.
    func noteBuild(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        if buildSamples.count < Self.maxSamples { buildSamples.append(seconds) }
    }

    func noteFrame(cpu: Double, waited: Double, instances count: Int) {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        instances = count
        if cpuSamples.count < Self.maxSamples { cpuSamples.append(cpu) }
        if waitSamples.count < Self.maxSamples { waitSamples.append(waited) }
    }

    func noteGPU(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        if gpuSamples.count < Self.maxSamples { gpuSamples.append(seconds) }
    }

    func notePresented(at time: Double) {
        lock.lock(); defer { lock.unlock() }
        if presentedTimes.count < Self.maxSamples { presentedTimes.append(time) }
    }

    func noteResumePresented(startedAt: Double, presentedAt: Double) {
        lock.lock(); defer { lock.unlock() }
        let seconds = presentedAt - startedAt
        guard seconds >= 0, resumeSamples.count < Self.maxSamples else { return }
        resumeSamples.append(seconds)
    }

    /// A gap is a step between two consecutive served times longer than one
    /// and a half display periods: the display refreshed and nothing new was
    /// there. The period is taken from the run's own median step, so the
    /// count is right on a 60 Hz display and on a 120 Hz one without being
    /// told which it is on.
    private static func gaps(_ times: [Double]) -> (count: Int, period: Double, when: [Double]) {
        guard times.count > 4 else { return (0, 0, []) }
        var steps: [Double] = []
        steps.reserveCapacity(times.count - 1)
        for index in 1..<times.count { steps.append(times[index] - times[index - 1]) }
        let period = median(steps)
        guard period > 0 else { return (0, 0, []) }
        // WHERE a gap fell matters as much as how many there were: three in
        // the first tenth of a second are a cold start, three spread through
        // half a minute are a renderer that cannot keep up.
        var when: [Double] = []
        for (index, step) in steps.enumerated() where step > period * 1.5 {
            if when.count < 20 { when.append(times[index + 1] - times[0]) }
        }
        return (steps.filter { $0 > period * 1.5 }.count, period, when)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }

    private func gapTimes(_ times: [Double], _ prefix: String) -> [String: Double] {
        var result: [String: Double] = [:]
        for (index, time) in times.enumerated() { result["\(prefix)\(index)"] = time }
        return result
    }

    func snapshot() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        let elapsed = CACurrentMediaTime() - started
        let vsyncGap = Self.gaps(vsyncTimes)
        let presentGap = Self.gaps(presentedTimes)
        return [
            "seconds": elapsed,
            "frames": Double(frames),
            "vsyncs": Double(vsyncs),
            "idleSkips": Double(skippedIdle),
            "noDrawable": Double(noDrawable),
            "wheelEvents": Double(wheelEvents),
            "wheelMedianMs": Self.median(wheelSamples) * 1000,
            "wheelMaxMs": (wheelSamples.max() ?? 0) * 1000,
            "wheelScrollToMedianMs": Self.median(wheelScrollToSamples) * 1000,
            "wheelScrollToMaxMs": (wheelScrollToSamples.max() ?? 0) * 1000,
            "wheelScrollToSamples": Double(wheelScrollToSamples.count),
            "wheelSettleMedianMs": Self.median(wheelSettleSamples) * 1000,
            "wheelSettleMaxMs": (wheelSettleSamples.max() ?? 0) * 1000,
            "wheelSettleSamples": Double(wheelSettleSamples.count),
            "drawMedianMs": Self.median(drawSamples) * 1000,
            "drawMaxMs": (drawSamples.max() ?? 0) * 1000,
            "drawSamples": Double(drawSamples.count),
            "immediateDraws": Double(immediateDraws),
            "instances": Double(instances),
            "gpuMedianMs": Self.median(gpuSamples) * 1000,
            "gpuP95Ms": Self.percentile(gpuSamples, 0.95) * 1000,
            "gpuMaxMs": (gpuSamples.max() ?? 0) * 1000,
            "gpuSamples": Double(gpuSamples.count),
            "cpuMedianMs": Self.median(cpuSamples) * 1000,
            "cpuP95Ms": Self.percentile(cpuSamples, 0.95) * 1000,
            "cpuMaxMs": (cpuSamples.max() ?? 0) * 1000,
            "buildMedianMs": Self.median(buildSamples) * 1000,
            "waitMedianMs": Self.median(waitSamples) * 1000,
            "waitP95Ms": Self.percentile(waitSamples, 0.95) * 1000,
            "vsyncGaps": Double(vsyncGap.count),
            "vsyncHz": vsyncGap.period > 0 ? 1 / vsyncGap.period : 0,
            "presentGaps": Double(presentGap.count),
            "presentedSamples": Double(presentedTimes.count),
            "resumeSamples": Double(resumeSamples.count),
            "resumeLastMs": (resumeSamples.last ?? 0) * 1000,
            "resumeMedianMs": Self.median(resumeSamples) * 1000,
            "resumeMaxMs": (resumeSamples.max() ?? 0) * 1000,
        ].merging(gapTimes(vsyncGap.when, "vsyncGapAt")) { a, _ in a }
         .merging(gapTimes(presentGap.when, "presentGapAt")) { a, _ in a }
    }
}
