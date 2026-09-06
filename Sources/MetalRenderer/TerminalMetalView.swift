//  TerminalMetalView.swift — the grid, drawn by the GPU.
//
//  What this is, in one paragraph. Every visible cell becomes one instance in
//  a buffer — a rectangle, a patch of the glyph atlas, a colour — and the
//  whole screen goes down as a single instanced draw. Backgrounds, underlines,
//  glyphs and the cursor are all the same instance shape in one buffer, in
//  drawing order, so there is one encode and one draw call per frame no matter
//  how much text is on screen.
//
//  Three properties are deliberate and each one is a claim:
//
//  * it reads `TerminalGrid` and nothing else, so it does not know which VT
//    engine filled the cells (the hedge of the Decision on libghostty);
//  * it draws only when something changed, and when nothing has changed for a
//    few frames it stops the display link entirely — the GPU earns its silence
//    (ISC-22);
//  * it can be switched off at any moment and the engine's own CPU renderer
//    takes the pane back (ISC-24).

import AppKit
import Metal
import QuartzCore
import TerminalCore

@MainActor
public final class TerminalMetalView: NSView, TerminalRenderer, MetalCaptureCapable {
    // MARK: - What it draws

    /// The grid to read. Weak: the session owns the grid, never the view.
    public weak var source: (any TerminalGrid)?

    public var palette: TerminalPalette {
        didSet { rebuildPalette(); invalidateRowCache(); markDirty() }
    }

    public var font: NSFont {
        didSet {
            atlas?.setFont(font, scale: scale)
            invalidateRowCache()
            cellSize = GlyphAtlas.cellSize(for: font, scale: scale)
            baselineOffset = GlyphAtlas.baselineOffset(for: font)
            markDirty()
        }
    }

    public var folds = RowFold() {
        didSet {
            guard folds != oldValue else { return }
            // The row cache is keyed by scroll-invariant row and holds the
            // instances at a y of zero, so folding does not invalidate a row's
            // CONTENT — but the strip rows are new geometry, so the cache is
            // dropped once rather than reasoned about.
            invalidateRowCache()
            markDirty()
        }
    }
    public var highlights: [GridSpan] = [] { didSet { markDirty() } }
    public var currentHighlight: Int? { didSet { markDirty() } }
    public var linkHighlight: GridSpan? { didSet { markDirty() } }
    public var cursorStyle: CursorStyle = .block { didSet { markDirty() } }
    public var cursorMotion: CursorMotion = .glide { didSet { markDirty() } }

    private var drawnScrollOffset: CGFloat = 0 {
        didSet { if drawnScrollOffset != oldValue { onScrollOffsetChanged?() } }
    }
    public var onScrollOffsetChanged: (() -> Void)?
    private var scrollSettle: (from: CGFloat, startedAt: Double)?

    /// Pixel (in points) by which rows are translated upwards. This is draw
    /// state only: the grid and all its row numbers remain integral.
    public var scrollOffset: CGFloat {
        get { drawnScrollOffset }
        set {
            scrollSettle = nil
            let height = max(cellSize.height, 0.001)
            drawnScrollOffset = min(max(0, newValue), height.nextDown)
            markDirty()
            // Not drawn here. Two experiments on 30/08, both measured with the
            // 120 Hz meter and both retired: drawing on every wheel event
            // (run 12) and drawing at most once per display period (run 13)
            // each blocked the main thread ~8 ms per frame inside the draw
            // and halved the distinct frames (74 against 105). The wheel path
            // stays tick-driven; only the frame that wakes a sleeping link is
            // drawn immediately (`markDirty`).
        }
    }

    /// Input hit testing asks the renderer for the same cell geometry it drew;
    /// deriving width from the view would include SwiftTerm's scroller reserve.
    public var cellWidth: CGFloat { cellSize.width }
    public var cellHeight: CGFloat { cellSize.height }

    /// Finishes a precise gesture on the grid. The system preference and the
    /// ISC-67 switch are read here, at the last possible moment, so either one
    /// makes the very next frame aligned.
    public func settleScrollOffset() {
        guard drawnScrollOffset > 0 else { return }
        guard motionAllowed else {
            scrollSettle = nil
            drawnScrollOffset = 0
            markDirty()
            return
        }
        scrollSettle = (drawnScrollOffset, CACurrentMediaTime())
        markDirty()
    }

    /// A click must hit the row that is visibly under it. Selection starts by
    /// discarding the sub-row remainder, so SwiftTerm's integral hit testing
    /// and the renderer agree without duplicating its private geometry.
    public func resetScrollOffset() {
        scrollSettle = nil
        guard drawnScrollOffset != 0 else { return }
        drawnScrollOffset = 0
        markDirty()
    }

    /// One switch that turns off every animation the renderer does, and it is
    /// forced on when the system asks for reduced motion (ISC-67).
    public var motionEnabled = true {
        didSet {
            if !motionEnabled, scrollSettle != nil {
                scrollSettle = nil
                drawnScrollOffset = 0
            }
            markDirty()
        }
    }
    private var motionAllowed: Bool { motionEnabled && !systemWantsReducedMotion }

    private var reduceMotionCache = false
    private var reduceMotionCheckedAt = 0.0

    /// Whether the system has asked for less movement.
    ///
    /// `NSWorkspace`'s property is the sanctioned answer, but it is cached
    /// for the life of the process and only refreshed when the system posts
    /// its change notification — which flipping the setting from a script
    /// does not do, so a run that turns Reduce Motion on and asks the running
    /// app about it gets a stale "no" (measured 2026-08-20). The preference
    /// itself is therefore re-read, at most once a second, and either source
    /// saying yes is a yes.
    private var systemWantsReducedMotion: Bool {
        let now = CACurrentMediaTime()
        if now - reduceMotionCheckedAt > 1 {
            reduceMotionCheckedAt = now
            CFPreferencesAppSynchronize("com.apple.universalaccess" as CFString)
            let stored = CFPreferencesCopyAppValue(
                "reduceMotion" as CFString,
                "com.apple.universalaccess" as CFString) as? Bool ?? false
            reduceMotionCache =
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || stored
        }
        return reduceMotionCache
    }

    public private(set) var isActive = false

    // MARK: - Metal

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var atlas: GlyphAtlas?
    /// Instances are written STRAIGHT into a Metal buffer, not into a Swift
    /// array that is then copied. Measured on the bench: building a frame
    /// through `Array.append` cost 0.54 ms for three and a half thousand
    /// rectangles — most of it uniqueness checks and capacity checks on an
    /// array that never changes size — against 0.2 ms writing through a
    /// pointer. Three slots, so the CPU is never writing the buffer the GPU
    /// is reading (two frames can be in the air, and the third is spare).
    private var ring: MTLBuffer?
    private var ringSlot = 0
    private var ringCapacity = 0
    private static let ringSlots = 3
    private var cursorPen: UnsafeMutablePointer<CellInstance>?
    private var emitted = 0
    private var overflowed = 0
    /// Raised by a frame that ran out of room, so the next one has it (ISC-133).
    private var capacityFloor = 0
    /// The most rectangles any one frame has wanted since the counters were
    /// reset. Without it "nothing was dropped" is unfalsifiable: a bound is
    /// only proved by a frame that came close to it.
    private var emittedPeak = 0
    /// Frames rebuilt because the atlas emptied itself mid-build (ISC-129),
    /// and the ones where rebuilding was not enough.
    private var atlasRestarts = 0
    private var atlasRestartsGivenUp = 0
    private var drawCalls = 0
    private let inFlight = DispatchSemaphore(value: 2)

    private var frameLink: CADisplayLink?
    private var dirty = true
    private var idleFrames = 0
    /// How many quiet frames before the link stops. Small enough that a still
    /// terminal is silent within a breath, large enough that a burst of output
    /// does not start and stop the link on every gap between packets.
    private static let idleFramesBeforeSleep = 6

    /// How much thinner than a raw coverage mask the text is drawn. Measured
    /// against the engine's own CoreText output on the fidelity bench, not
    /// picked by eye; the environment variable exists so the bench can sweep
    /// it without a rebuild.
    static let textGamma: Float = {
        if let raw = ProcessInfo.processInfo.environment["T4A_TEXT_GAMMA"],
           let value = Float(raw) { return value }
        // One, i.e. no correction. Measured on 2026-08-20 against the CPU
        // renderer: the GPU's text carries about 5% more ink, but a gamma
        // that removes the excess (1.15, 1.30 were both swept) makes the
        // per-pixel difference WORSE, not better — the two rasterisers put
        // their antialiasing in different places, and thinning the strokes
        // corrects an average while moving every edge. A correction that
        // improves one number and spoils the one that matters is a knob, not
        // a fix, so the knob is left at neutral and the fact is written down.
        return 1.0
    }()

    private let stats = RenderStats()
    private var scale: CGFloat = 2
    private var cellSize: CGSize = .zero
    private var baselineOffset: CGFloat = 0
    private var lastFrameTime = CACurrentMediaTime()
    /// A detached/hidden pane keeps its atlas and grid, but not a Retina-sized
    /// drawable pool. One pixel is deliberate: CAMetalLayer accepts it, frees
    /// the old IOSurfaces once their commands complete, and needs no layer
    /// replacement when the pane comes back.
    private var drawablesSuspended = true
    private static let suspendedDrawableSize = CGSize(width: 1, height: 1)
    private weak var observedWindow: NSWindow?
    /// Set while the first full-sized frame after a resume is in flight.
    private var resumeStartedAt: Double?

    // Colours, resolved once per palette change rather than per cell.
    private var defaultForeground = SIMD4<Float>(1, 1, 1, 1)
    private var defaultBackground = SIMD4<Float>(0, 0, 0, 1)
    private var cursorColour = SIMD4<Float>(1, 1, 1, 1)
    private var cursorTextColour = SIMD4<Float>(0, 0, 0, 1)
    private var selectionColour = SIMD4<Float>(0.3, 0.3, 0.4, 1)
    private var linkColour = SIMD4<Float>(0.8, 0.8, 0.8, 1)
    private var linkHighlightColour = SIMD4<Float>(0.3, 0.3, 0.4, 1)
    private var highlightColour = SIMD4<Float>(0.5, 0.45, 0.1, 1)
    private var currentHighlightColour = SIMD4<Float>(0.9, 0.7, 0.2, 1)
    private var ansi: [SIMD4<Float>] = []

    // Cursor, in cell coordinates, as it is now and where it is going.
    private var cursorNow = SIMD2<Double>(0, 0)
    private var cursorVelocity = SIMD2<Double>(0, 0)
    private var cursorPlaced = false
    public private(set) var cursorTrail: [SIMD3<Double>] = []
    private var trailStarted: Double?

    public init?(font: NSFont, palette: TerminalPalette) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.font = font
        self.palette = palette
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        cellSize = GlyphAtlas.cellSize(for: font, scale: scale)
        baselineOffset = GlyphAtlas.baselineOffset(for: font)
        rebuildPalette()
        guard buildPipeline() else { return nil }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }

    /// The renderer never takes a click: selection, focus and scrolling belong
    /// to the view underneath, which is the one that knows about input.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        // sRGB, explicitly. A Metal layer takes the display's colour space by
        // default, which on this machine is P3: the same numbers then come
        // out more saturated than the same numbers drawn by CoreGraphics, and
        // the difference is invisible on greys and obvious on a saturated
        // cyan. Measured on the fidelity bench — the red channel of ANSI cyan
        // was 0 on the GPU and 6 on the CPU until this line existed.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        layer.needsDisplayOnBoundsChange = true
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        return layer
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    private func buildPipeline() -> Bool {
        do {
            let library = try Shaders.library(for: device)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "cell_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "cell_fragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            // Premultiplied source: every fragment leaves the shader with its
            // colour already multiplied by its coverage.
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            let samplerDescriptor = MTLSamplerDescriptor()
            // Nearest: the atlas is rasterised at device resolution and drawn
            // at 1:1, so filtering could only blur it.
            samplerDescriptor.minFilter = .nearest
            samplerDescriptor.magFilter = .nearest
            samplerDescriptor.sAddressMode = .clampToEdge
            samplerDescriptor.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: samplerDescriptor)
            return pipeline != nil && sampler != nil
        } catch {
            NSLog("T4A: the GPU renderer could not build its pipeline: \(error)")
            return false
        }
    }

    // MARK: - Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeOcclusionStateNotification,
                object: observedWindow)
        }
        observedWindow = window
        guard let window else {
            suspendDrawables()
            return
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowOcclusionDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        let scaleChanged = window.backingScaleFactor != scale
        scale = window.backingScaleFactor
        cellSize = GlyphAtlas.cellSize(for: font, scale: scale)
        baselineOffset = GlyphAtlas.baselineOffset(for: font)
        // A tab switch detaches the pane and reattaches it (`installActiveTabView`),
        // so this runs on every switch. The atlas is only rebuilt when the
        // backing scale actually changed — and whenever it IS rebuilt the row
        // cache goes with it: every cached history row holds texture
        // coordinates into the texture that `setFont` has just wiped, and
        // serving them again is a screen of the wrong glyphs that persists
        // (ISC-243, his screenshot of 5/09 22:44). ISC-129 guards the reset
        // that happens mid-frame; this is the one that happened between frames.
        if atlas == nil {
            atlas = GlyphAtlas(device: device, font: font, scale: scale)
            invalidateRowCache()
        } else if scaleChanged {
            atlas?.setFont(font, scale: scale)
            invalidateRowCache()
        }
        updateDrawableAvailability()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        updateDrawableAvailability()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateDrawableAvailability()
    }

    @objc private func windowOcclusionDidChange(_ notification: Notification) {
        updateDrawableAvailability()
    }

    /// A tab is inactive when its container is removed from `terminalHost`,
    /// which makes `window` nil. `isHiddenOrHasHiddenAncestor` covers the CPU
    /// fallback and hidden ancestors; occlusion covers a window that still
    /// owns the view tree but is miniaturised, hidden, or on another Space.
    private func updateDrawableAvailability() {
        guard let window,
              !isHiddenOrHasHiddenAncestor,
              !window.isMiniaturized,
              window.occlusionState.contains(.visible) else {
            suspendDrawables()
            return
        }
        resumeDrawables()
    }

    private func suspendDrawables() {
        drawablesSuspended = true
        resumeStartedAt = nil
        stop()
        guard let metalLayer,
              metalLayer.drawableSize != Self.suspendedDrawableSize else { return }
        metalLayer.drawableSize = Self.suspendedDrawableSize
    }

    /// Called synchronously from AppKit's visibility lifecycle. The immediate
    /// draw is encoded before the run loop can commit the newly attached tab,
    /// so the first composited full-sized surface contains the current grid
    /// rather than an uninitialised or stale drawable.
    private func resumeDrawables() {
        let wasSuspended = drawablesSuspended
        drawablesSuspended = false
        updateDrawableSize()
        start()
        guard wasSuspended else { return }
        resumeStartedAt = CACurrentMediaTime()
        dirty = true
        idleFrames = 0
        drawNow()
    }

    private func start() {
        guard !drawablesSuspended else { return }
        guard frameLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        // Ask for the fastest the display can do; ProMotion will go to 120 and
        // a 60 Hz panel will simply do 60.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120,
                                                        preferred: 120)
        frameLink = link
        isActive = true
        dirty = true
    }

    public func stop() {
        frameLink?.invalidate()
        frameLink = nil
        isActive = false
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        // A resize reflows the buffer, so what row 4.000 contains afterwards
        // is not what it contained before.
        invalidateRowCache()
        markDirty()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let newScale = window?.backingScaleFactor ?? scale
        if newScale != scale {
            scale = newScale
            atlas?.setFont(font, scale: scale)
            cellSize = GlyphAtlas.cellSize(for: font, scale: scale)
            invalidateRowCache()
        }
        updateDrawableSize()
        markDirty()
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        metalLayer.contentsScale = scale
        if drawablesSuspended {
            if metalLayer.drawableSize != Self.suspendedDrawableSize {
                metalLayer.drawableSize = Self.suspendedDrawableSize
            }
            return
        }
        let size = CGSize(width: max(1, bounds.width * scale),
                          height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }

    public func markDirty() {
        dirty = true
        idleFrames = 0
        guard let frameLink, frameLink.isPaused else { return }
        frameLink.isPaused = false
        // The link was asleep: the first change would otherwise wait for its
        // next tick and then for the vsync after that. Measured 30/08 with a
        // 120 Hz meter: 22 ms from a wheel event to the first changed pixel,
        // against 7 ms for iTerm, which draws in the same run-loop pass. So
        // the frame that wakes the link is drawn NOW; the ticks take over
        // from the next one.
        drawNow()
    }

    /// One frame, in this run-loop pass, if a drawable is free. A wheel
    /// event that lands just after a tick would otherwise wait a full period
    /// for the next one, and when the event stream and the display beat
    /// against each other that wait shows up as a 16 ms hole about once a
    /// second (profiled 30/08: draw costs 0.19 ms, nothing else in the wheel
    /// path costs anything, and iTerm, which draws per event, has no hole).
    /// `drawingNow` keeps a didSet inside the draw (highlights, cursor style)
    /// from recursing into a second frame.
    private func drawNow() {
        guard let frameLink, !drawingNow else { return }
        stats.noteImmediateDraw()
        drawingNow = true
        dirty = false
        draw(link: frameLink)
        drawingNow = false
    }
    private var drawingNow = false
    /// When a frame was last actually drawn (skipped ticks do not count).
    private var lastDrawTime: Double = 0

    // MARK: - The frame

    public var beforeFrame: (() -> Void)?

    @objc private func step(_ link: CADisplayLink) {
        stats.noteVsync(at: link.timestamp)
        beforeFrame?()
        let now = CACurrentMediaTime()
        let delta = min(0.05, max(0, now - lastFrameTime))
        lastFrameTime = now

        let cursorMoving = advanceCursor(by: delta)
        let scrollMoving = advanceScrollOffset(at: now)
        if cursorMoving {
            // Only while it is travelling: a trail of a still cursor is a
            // thousand copies of the same number.
            if trailStarted == nil { trailStarted = now; cursorTrail.removeAll() }
            if cursorTrail.count < 600 {
                cursorTrail.append(SIMD3<Double>(now - (trailStarted ?? now),
                                                 cursorNow.x, cursorNow.y))
            }
        } else {
            trailStarted = nil
        }
        guard dirty || cursorMoving || scrollMoving else {
            idleFrames += 1
            stats.noteIdleSkip()
            // Nothing has changed for several frames: stop asking the display
            // for time. This is the whole of ISC-22 — not "few frames" when
            // idle, none.
            if idleFrames >= Self.idleFramesBeforeSleep { link.isPaused = true }
            return
        }
        idleFrames = 0
        dirty = false
        draw(link: link)
    }

    private func draw(link: CADisplayLink) {
        lastDrawTime = CACurrentMediaTime()
        let started = CACurrentMediaTime()
        defer { stats.noteDraw(CACurrentMediaTime() - started) }
        guard !drawablesSuspended,
              let metalLayer, let pipeline, let sampler, let atlas,
              bounds.width > 1, bounds.height > 1 else { return }
        guard inFlight.wait(timeout: .now()) == .success else {
            // The GPU has not finished the frames already in the air. Skipping
            // is correct: queueing a third would add latency, not smoothness.
            stats.noteNoDrawable()
            dirty = true
            return
        }
        let cpuStart = CACurrentMediaTime()
        guard prepareRing(for: neededCapacity()) else { inFlight.signal(); return }
        ringSlot = (ringSlot + 1) % Self.ringSlots
        let stride = MemoryLayout<CellInstance>.stride
        let slotOffset = ringSlot * ringCapacity * stride
        cursorPen = ring!.contents().advanced(by: slotOffset)
            .assumingMemoryBound(to: CellInstance.self)
        let overflowsBefore = overflowed
        buildInstances(atlas: atlas)
        emittedPeak = max(emittedPeak, emitted + overflowed - overflowsBefore)
        if overflowed > overflowsBefore {
            // It happened anyway. Doubling converges in a couple of frames and
            // the counter stays in the statistics, so a bench sees BOTH that
            // something was dropped and that the ring grew — silence here is
            // what made this worth a claim (ISC-133).
            capacityFloor = max(capacityFloor, ringCapacity * 2)
            dirty = true
        }
        stats.noteBuild(CACurrentMediaTime() - cpuStart)
        guard emitted > 0 else {
            inFlight.signal()
            return
        }

        // Getting a drawable BLOCKS until the display releases one. That wait
        // is the frame pacing doing its job, not work being done, and timing
        // it as CPU cost was wrong: the p95 came out at 8.3 ms on a 120 Hz
        // display, which is one refresh period exactly — the measurement was
        // reporting the wait for the screen as the cost of drawing (found
        // 2026-08-20, on the bench).
        let workedSoFar = CACurrentMediaTime() - cpuStart
        guard let drawable = metalLayer.nextDrawable() else {
            stats.noteNoDrawable()
            inFlight.signal()
            dirty = true
            return
        }
        let afterWait = CACurrentMediaTime()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(defaultBackground.x), green: Double(defaultBackground.y),
            blue: Double(defaultBackground.z), alpha: 1)

        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        var uniforms = SIMD4<Float>(Float(metalLayer.drawableSize.width),
                                    Float(metalLayer.drawableSize.height),
                                    Self.textGamma, 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(ring, offset: slotOffset, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: emitted)
        // One call, whatever is on screen. Counted rather than asserted: a
        // renderer that quietly grew a second pass would still say "instanced
        // draw" in its comments (ISC-19).
        drawCalls += 1
        encoder.endEncoding()

        let stats = self.stats
        let resumedAt = resumeStartedAt
        resumeStartedAt = nil
        drawable.addPresentedHandler { presented in
            stats.notePresented(at: presented.presentedTime)
            if let resumedAt {
                stats.noteResumePresented(startedAt: resumedAt,
                                          presentedAt: presented.presentedTime)
            }
        }
        commands.addCompletedHandler { [inFlight] buffer in
            // The GPU's own clock. A stopwatch around the encode would time
            // the queue, which is not what "GPU time" means.
            let gpu = buffer.gpuEndTime - buffer.gpuStartTime
            if gpu > 0 { stats.noteGPU(gpu) }
            inFlight.signal()
        }
        commands.present(drawable)
        commands.commit()
        stats.noteFrame(cpu: workedSoFar + (CACurrentMediaTime() - afterWait),
                        waited: afterWait - (cpuStart + workedSoFar),
                        instances: emitted)
    }

    // MARK: - Instances

    /// One row's instances, with y measured from the top of the row.
    ///
    /// A line that has scrolled off the live screen can never change again —
    /// that is what a scroll-invariant row number means — so the work of
    /// turning it into rectangles is worth keeping. Measured on the bench:
    /// building every visible row from the grid every frame cost 0.69 ms of
    /// the 0.78 ms a frame took, and scrolling touches exactly one new row
    /// per frame. The fingerprint covers the things that are NOT part of the
    /// row's content and can still change under it — the selection and the
    /// search highlights.
    private struct CachedRow {
        var fingerprint: UInt64
        var instances: [CellInstance]
    }
    private var rowCache: [Int: CachedRow] = [:]
    private var cacheHits = 0
    private var cacheMisses = 0

    /// Everything the cache assumed is gone: a different font, a different
    /// size (which reflows history), a different palette.
    public func invalidateRowCache() { rowCache.removeAll(keepingCapacity: true) }

    /// Writes one rectangle. Silently stops at the end of the slot rather
    /// than growing mid-frame: the buffer is resized before the NEXT frame,
    /// and a frame that is missing its last few cells is better than a
    /// reallocation in the middle of one.
    @inline(__always)
    private func emit(_ instance: CellInstance) {
        guard emitted < ringCapacity, let pen = cursorPen else { overflowed += 1; return }
        pen[emitted] = instance
        emitted += 1
    }

    /// Room for the WORST screen, not the usual one (ISC-133).
    ///
    /// Three rectangles a cell was the old figure and a cell can want five: a
    /// background, an underline, a strikethrough, and — for the box-drawing
    /// range, which is painted rather than typeset — up to two pieces where an
    /// ordinary character has one glyph. A screen of underlined struck-through
    /// box characters is odd, and `emit` dropped the overflow in silence,
    /// which means the failure mode was content quietly missing from the
    /// bottom of the frame for as long as the screen stayed that way.
    ///
    /// The floor below is the second half: if a frame ever does overflow, the
    /// next one is built with room for what the last one wanted. A bound that
    /// is wrong once is a bug; a bound that is wrong twice for the same reason
    /// is a decision.
    private func neededCapacity() -> Int {
        guard let grid = source else { return 4096 }
        // A fractional scroll exposes one more row at the bottom.
        let cells = max(1, grid.columns) * max(1, grid.rows + 1)
        return max(8192, max(cells * 5 + 64, capacityFloor))
    }

    /// Grows the ring when the grid does. Never inside a frame.
    private func prepareRing(for capacity: Int) -> Bool {
        if let ring, ringCapacity >= capacity { _ = ring; return true }
        let stride = MemoryLayout<CellInstance>.stride
        guard let buffer = device.makeBuffer(length: capacity * stride * Self.ringSlots,
                                             options: .storageModeShared) else { return false }
        ring = buffer
        ringCapacity = capacity
        ringSlot = 0
        return true
    }

    /// Builds the frame, and builds it AGAIN if the atlas emptied itself while
    /// it was being built (ISC-129).
    ///
    /// The atlas starts over when it runs out of room, which is bounded and
    /// correct on its own. What was not correct is what the rest of this frame
    /// was holding at that moment: every rectangle already emitted, and every
    /// cached history row, carries texture coordinates into a texture that has
    /// just been wiped and is being refilled from a different corner. The
    /// symptom is a screenful of the wrong glyphs, and it persists — the cache
    /// is keyed on selection and highlights, never on the state of the atlas,
    /// so a history row that has not changed is served from it for ever after.
    /// `resetCount` was already exported to the statistics; it just never
    /// invalidated anything.
    private func buildInstances(atlas: GlyphAtlas) {
        // Twice, not until it settles: a screen whose glyphs cannot all fit in
        // one atlas would loop for ever, and the honest answer there is a
        // counter somebody can read rather than a frame that never ships.
        for attempt in 0..<2 {
            let resetsBefore = atlas.resetCount
            buildInstancesOnce(atlas: atlas)
            guard atlas.resetCount != resetsBefore else { return }
            invalidateRowCache()
            atlasRestarts += 1
            if attempt == 1 { atlasRestartsGivenUp += 1 }
        }
    }

    private func buildInstancesOnce(atlas: GlyphAtlas) {
        emitted = 0
        guard let grid = source else { return }
        let columns = grid.columns
        let rows = grid.rows
        guard columns > 0, rows > 0 else { return }

        let cellWidth = cellSize.width * scale
        let cellHeight = cellSize.height * scale
        let baseline = cellHeight - baselineOffset * scale
        let top = grid.topVisibleRow
        let selection = grid.selection
        // Stroke weights for the drawn characters, as a fraction of the cell,
        // snapped so a line is a whole number of device pixels.
        let lineThickness = max(1, (cellHeight * 0.08).rounded()) / cellHeight
        let heavyThickness = max(2, (cellHeight * 0.16).rounded()) / cellHeight
        let visibleRows = min(rows, Int(ceil(bounds.height * scale / cellHeight)))
        let drawnRows = visibleRows + 1

        // Rows older than the live screen are history and cannot change; the
        // live screen itself is rewritten by the program at any moment.
        let liveTop = grid.liveScreenTopRow

        // With no folds this is `top + screenRow` and nothing else — and the
        // empty case allocates NOTHING, which is why it is written twice.
        // Building a row list every frame is a per-frame allocation in the
        // hot loop, and the bench felt it: one gap in 3627 presentations
        // appeared the day the walk went in, against zero before.
        let walk: [FoldedRow] = folds.isEmpty ? [] : folds.rows(from: top, count: drawnRows)
        for screenRow in 0..<drawnRows {
            let entry: FoldedRow = walk.isEmpty ? .line(top + screenRow) : walk[screenRow]
            let y = TerminalRowGeometry.y(screenRow: screenRow, cellHeight: cellHeight,
                                          scrollOffset: drawnScrollOffset, scale: scale)
            guard case .line(let row) = entry else {
                if case .fold(let range) = entry { emitFoldStrip(y: y, rows: range,
                                                                 width: bounds.width * scale,
                                                                 cellHeight: cellHeight) }
                continue
            }
            let selected = selection?.columns(on: row, width: columns)
            let linked = linkHighlight?.columns(on: row, width: columns)
            let cacheable = row < liveTop
            if cacheable, let cached = rowCache[row],
               cached.fingerprint == fingerprint(row: row, selected: selected) {
                cacheHits += 1
                // A memcpy and a pass over the y of each rectangle: no ARC,
                // no bounds checks, no growth.
                if let pen = cursorPen, emitted + cached.instances.count <= ringCapacity {
                    cached.instances.withUnsafeBufferPointer { source in
                        pen.advanced(by: emitted).update(from: source.baseAddress!,
                                                         count: source.count)
                    }
                    let offset = Float(y)
                    for index in emitted..<(emitted + cached.instances.count) {
                        pen[index].rect.y += offset
                    }
                    emitted += cached.instances.count
                } else {
                    // The other place rectangles were dropped without a word.
                    // `emit` counted its own; this path copied a whole row at
                    // once and skipped it in silence when the row would not fit.
                    overflowed += cached.instances.count
                }
                continue
            }
            cacheMisses += 1
            let rowStart = emitted
            guard let line = grid.line(at: row) else { continue }
            var highlighted: [Range<Int>] = []
            var currentRanges: [Range<Int>] = []
            for (index, span) in highlights.enumerated() {
                if let range = span.columns(on: row, width: columns) {
                    if index == currentHighlight { currentRanges.append(range) }
                    else { highlighted.append(range) }
                }
            }

            for (column, cell) in line.cells.enumerated() {
                // A wide character owns two columns; the second one carries no
                // glyph and must not paint over the first.
                if cell.width == 0 { continue }
                let x = CGFloat(column) * cellWidth
                let width = cellWidth * CGFloat(max(1, cell.width))
                let inverse = cell.attributes.contains(.inverse)
                var foreground = colour(cell.foreground, isBackground: false)
                var background = colour(cell.background, isBackground: true)
                if inverse { swap(&foreground, &background) }
                if cell.attributes.contains(.dim) {
                    foreground = SIMD4<Float>(foreground.x * 0.6, foreground.y * 0.6,
                                              foreground.z * 0.6, foreground.w)
                }

                var paint = background
                var paintIt = background != defaultBackground
                if highlighted.contains(where: { $0.contains(column) }) {
                    paint = highlightColour; paintIt = true
                }
                if let linked, linked.contains(column) {
                    paint = linkHighlightColour; paintIt = true
                }
                if currentRanges.contains(where: { $0.contains(column) }) {
                    paint = currentHighlightColour; paintIt = true
                }
                if let selected, selected.contains(column) {
                    paint = selectionColour; paintIt = true
                }
                if paintIt {
                    emit(.solid(x: Float(x), y: Float(y),
                                            width: Float(width), height: Float(cellHeight),
                                            colour: paint))
                }

                let isLink = linked?.contains(column) == true
                if cell.attributes.contains(.underline) || isLink {
                    let lineY = y + baseline + 1 * scale
                    emit(.solid(x: Float(x), y: Float(lineY),
                                            width: Float(width),
                                            height: Float(max(1, scale)),
                                            colour: isLink ? linkColour : foreground))
                }
                if cell.attributes.contains(.strikethrough) {
                    let lineY = y + cellHeight * 0.55
                    emit(.solid(x: Float(x), y: Float(lineY),
                                            width: Float(width),
                                            height: Float(max(1, scale)), colour: foreground))
                }

                guard !cell.attributes.contains(.invisible), cell.text != " " else { continue }
                // Box drawing and blocks are painted, not typeset: the font's
                // glyph leaves a gap at every cell boundary and a TUI frame
                // comes out perforated.
                if let pieces = BoxDrawing.pieces(for: cell.text,
                                                  thickness: lineThickness,
                                                  heavyThickness: heavyThickness) {
                    for piece in pieces {
                        var tint = foreground
                        tint.w *= Float(piece.alpha)
                        emit(.solid(
                            x: Float(x + CGFloat(piece.x) * width),
                            y: Float(y + CGFloat(piece.y) * cellHeight),
                            width: Float(max(1, CGFloat(piece.width) * width)),
                            height: Float(max(1, CGFloat(piece.height) * cellHeight)),
                            colour: tint))
                    }
                    continue
                }
                var style: UInt8 = 0
                if cell.attributes.contains(.bold) { style |= 1 }
                if cell.attributes.contains(.italic) { style |= 2 }
                guard let glyph = atlas.entry(for: cell.text, style: style) else { continue }
                emit(.glyph(glyph, penX: Float(x), baselineY: Float(y + baseline),
                                        colour: foreground))
            }

            if cacheable, let pen = cursorPen, emitted > rowStart {
                // Stored with y relative to the row, so the same rectangles
                // serve whatever line of the screen this row lands on next.
                var stored = Array(UnsafeBufferPointer(start: pen.advanced(by: rowStart),
                                                       count: emitted - rowStart))
                for index in stored.indices { stored[index].rect.y -= Float(y) }
                if rowCache.count > 600 { rowCache.removeAll(keepingCapacity: true) }
                rowCache[row] = CachedRow(fingerprint: fingerprint(row: row, selected: selected),
                                          instances: stored)
            }
        }

        appendCursor(atlas: atlas, grid: grid, cellWidth: cellWidth,
                     cellHeight: cellHeight, baseline: baseline, top: top)
    }

    /// What can change about a row without its text changing.
    /// A folded run, as one rule across the pane. The words that name it are
    /// drawn by the overlay, which has type; this is the surface it sits on,
    /// so that a fold reads as a seam in the text and not as a missing screen.
    private func emitFoldStrip(y: CGFloat, rows: ClosedRange<Int>,
                               width: CGFloat, cellHeight: CGFloat) {
        let colour = colour(.defaultForeground, isBackground: false)
        let faint = SIMD4<Float>(colour.x, colour.y, colour.z, 0.16)
        let thickness = max(1, (cellHeight * 0.06).rounded())
        emit(CellInstance.solid(x: 0,
                                y: Float(y + (cellHeight - thickness) / 2),
                                width: Float(width),
                                height: Float(thickness),
                                colour: faint))
        _ = rows
    }

    private func fingerprint(row: Int, selected: Range<Int>?) -> UInt64 {
        var value: UInt64 = 1469598103934665603
        func mix(_ number: Int) {
            value = (value ^ UInt64(bitPattern: Int64(number))) &* 1099511628211
        }
        if let selected { mix(selected.lowerBound); mix(selected.upperBound) } else { mix(-1) }
        if let range = linkHighlight?.columns(on: row, width: 1 << 20) {
            mix(range.lowerBound); mix(range.upperBound)
        } else {
            mix(-2)
        }
        for (index, span) in highlights.enumerated() {
            guard let range = span.columns(on: row, width: 1 << 20) else { continue }
            mix(range.lowerBound); mix(range.upperBound); mix(index == currentHighlight ? 1 : 0)
        }
        return value
    }

    private func appendCursor(atlas: GlyphAtlas, grid: any TerminalGrid,
                              cellWidth: CGFloat, cellHeight: CGFloat,
                              baseline: CGFloat, top: Int) {
        guard grid.isCursorVisible else { return }
        let screenRow = Double(grid.cursor.row - top)
        guard screenRow >= -1, screenRow <= Double(grid.rows) else { return }
        let x = CGFloat(cursorNow.x) * cellWidth
        let y = CGFloat(cursorNow.y) * cellHeight - drawnScrollOffset * scale
        switch cursorStyle {
        case .block:
            emit(.solid(x: Float(x), y: Float(y), width: Float(cellWidth),
                                    height: Float(cellHeight), colour: cursorColour))
            // The character underneath is redrawn in the cursor's text colour,
            // otherwise a block cursor hides the letter it is sitting on.
            let column = Int(cursorNow.x.rounded())
            let row = top + Int(cursorNow.y.rounded())
            if let line = grid.line(at: row), column >= 0, column < line.cells.count {
                let cell = line.cells[column]
                if cell.text != " ", cell.width > 0 {
                    var style: UInt8 = 0
                    if cell.attributes.contains(.bold) { style |= 1 }
                    if cell.attributes.contains(.italic) { style |= 2 }
                    if let glyph = atlas.entry(for: cell.text, style: style) {
                        emit(.glyph(glyph, penX: Float(x),
                                                baselineY: Float(y + baseline),
                                                colour: cursorTextColour))
                    }
                }
            }
        case .bar:
            emit(.solid(x: Float(x), y: Float(y),
                                    width: Float(max(1, 2 * scale)),
                                    height: Float(cellHeight), colour: cursorColour))
        case .underline:
            let thickness = max(1, 2 * scale)
            emit(.solid(x: Float(x), y: Float(y + cellHeight - thickness),
                                    width: Float(cellWidth), height: Float(thickness),
                                    colour: cursorColour))
        }
    }

    /// Moves the drawn cursor towards the real one and says whether it is
    /// still travelling — the frame after it arrives is the last one this
    /// costs.
    private func advanceCursor(by delta: Double) -> Bool {
        guard let grid = source else { return false }
        let target = SIMD2<Double>(Double(grid.cursor.column),
                                   Double(grid.cursor.row - grid.topVisibleRow))
        if !cursorPlaced {
            cursorNow = target
            cursorPlaced = true
            return false
        }
        guard motionAllowed, cursorMotion != .instant else {
            let moved = cursorNow != target
            cursorNow = target
            cursorVelocity = .zero
            return moved
        }
        // A cursor that has to cross the whole screen — a jump to another
        // line, a screen redraw — snaps instead of flying: the animation is
        // for the feel of typing, not for teleporting.
        let distance = length(target - cursorNow)
        if distance > 12 {
            cursorNow = target
            cursorVelocity = .zero
            return true
        }
        if distance < 0.01 {
            cursorNow = target
            cursorVelocity = .zero
            return false
        }
        switch cursorMotion {
        case .instant:
            cursorNow = target
        case .glide:
            // Exponential ease: the same fraction of the remaining distance
            // every frame, which is frame-rate independent when written this
            // way rather than as a fixed step.
            let rate = 1 - exp(-delta / 0.035)
            cursorNow += (target - cursorNow) * rate
        case .spring:
            let stiffness = 900.0
            let damping = 42.0
            let acceleration = (target - cursorNow) * stiffness - cursorVelocity * damping
            cursorVelocity += acceleration * delta
            cursorNow += cursorVelocity * delta
        }
        return true
    }

    /// A short ease-out is enough to remove the remainder without turning a
    /// wheel release into a second gesture. One hundred milliseconds stays
    /// below the 120 ms bound and is independent of the display refresh rate.
    private func advanceScrollOffset(at now: Double) -> Bool {
        guard let settle = scrollSettle else { return false }
        let progress = min(1, max(0, (now - settle.startedAt) / 0.100))
        let remaining = 1 - progress
        drawnScrollOffset = settle.from * CGFloat(remaining * remaining)
        if progress >= 1 {
            drawnScrollOffset = 0
            scrollSettle = nil
        }
        return true
    }

    private func length(_ vector: SIMD2<Double>) -> Double {
        (vector.x * vector.x + vector.y * vector.y).squareRoot()
    }

    // MARK: - Colour

    private func rebuildPalette() {
        defaultForeground = Self.components(palette.foreground)
        defaultBackground = Self.components(palette.background)
        cursorColour = Self.components(palette.cursor)
        cursorTextColour = Self.components(palette.cursorText)
        selectionColour = Self.components(palette.selection)
        linkColour = Self.components(palette.link)
        linkHighlightColour = Self.components(palette.linkHighlight)
        highlightColour = Self.components(palette.highlight)
        currentHighlightColour = Self.components(palette.currentHighlight)
        ansi = palette.ansi.map(Self.components)
    }

    private static func components(_ colour: NSColor) -> SIMD4<Float> {
        let converted = colour.usingColorSpace(.sRGB) ?? colour
        return SIMD4<Float>(Float(converted.redComponent), Float(converted.greenComponent),
                            Float(converted.blueComponent), Float(converted.alphaComponent))
    }

    private func colour(_ colour: GridColor, isBackground: Bool) -> SIMD4<Float> {
        switch colour {
        case .defaultForeground: return defaultForeground
        case .defaultBackground: return defaultBackground
        case .palette(let index):
            let slot = Int(index)
            return slot < ansi.count ? ansi[slot]
                : (isBackground ? defaultBackground : defaultForeground)
        case .rgb(let red, let green, let blue):
            return SIMD4<Float>(Float(red) / 255, Float(green) / 255, Float(blue) / 255, 1)
        }
    }

    // MARK: - Numbers

    public func statistics() -> [String: Double] {
        var result = stats.snapshot()
        result["atlasGlyphs"] = Double(atlas?.glyphCount ?? 0)
        result["rowCacheHits"] = Double(cacheHits)
        result["rowCacheMisses"] = Double(cacheMisses)
        result["rowCacheSize"] = Double(rowCache.count)
        result["overflowed"] = Double(overflowed)
        result["ringCapacity"] = Double(ringCapacity)
        result["emittedPeak"] = Double(emittedPeak)
        result["atlasRestarts"] = Double(atlasRestarts)
        result["atlasRestartsGivenUp"] = Double(atlasRestartsGivenUp)
        result["drawCalls"] = Double(drawCalls)
        result["atlasColouredGlyphs"] = Double(atlas?.colouredGlyphCount ?? 0)
        result["atlasBytes"] = Double(GlyphAtlas.side * GlyphAtlas.side * 4)
        result["atlasResets"] = Double(atlas?.resetCount ?? 0)
        result["active"] = isActive ? 1 : 0
        result["paused"] = (frameLink?.isPaused ?? true) ? 1 : 0
        result["motionEnabled"] = motionEnabled ? 1 : 0
        result["motionAllowed"] = motionAllowed ? 1 : 0
        result["reduceMotion"] = systemWantsReducedMotion ? 1 : 0
        result["scrollOffset"] = Double(drawnScrollOffset)
        result["cursorX"] = cursorNow.x
        result["cursorY"] = cursorNow.y
        result["cellWidth"] = Double(cellSize.width)
        result["cellHeight"] = Double(cellSize.height)
        result["scale"] = Double(scale)
        result["drawableWidth"] = Double(metalLayer?.drawableSize.width ?? 0)
        result["drawableHeight"] = Double(metalLayer?.drawableSize.height ?? 0)
        result["drawablesSuspended"] = drawablesSuspended ? 1 : 0
        return result
    }

    /// Wheel input is owned by SwiftTermBackend, while the renderer owns the
    /// dump read by the benches. These narrow entries keep the timing at the
    /// call sites without making either target reach into the other's state.
    public func noteWheelEvent(_ seconds: Double) { stats.noteWheel(seconds) }
    public func noteWheelScrollTo(_ seconds: Double) { stats.noteWheelScrollTo(seconds) }
    public func noteWheelSettle(_ seconds: Double) { stats.noteWheelSettle(seconds) }

    /// Captures one frame to a `.gputrace` for Xcode's frame debugger.
    ///
    /// The claim is that the glyphs live in a texture on the GPU and every
    /// cell is an instance of one draw; a capture is where a person can see
    /// the atlas and the instance buffer with their own eyes instead of
    /// taking a counter's word for it (ISC-19). Needs `MTL_CAPTURE_ENABLED=1`
    /// in the environment, which is why the failure is reported rather than
    /// swallowed.
    public func captureFrame(to path: String) -> String {
        let manager = MTLCaptureManager.shared()
        guard manager.supportsDestination(.gpuTraceDocument) else {
            return "capture unsupported: set MTL_CAPTURE_ENABLED=1 before launching"
        }
        let descriptor = MTLCaptureDescriptor()
        descriptor.captureObject = device
        descriptor.destination = .gpuTraceDocument
        descriptor.outputURL = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(atPath: path)
        do {
            try manager.startCapture(with: descriptor)
        } catch {
            return "capture refused: \(error.localizedDescription)"
        }
        markDirty()
        // One frame, then stop: a capture left running fills a disk.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MTLCaptureManager.shared().stopCapture()
        }
        return path
    }

    public func resetStatistics() {
        stats.reset()
        cacheHits = 0
        cacheMisses = 0
        overflowed = 0
        drawCalls = 0
        emittedPeak = 0
        atlasRestarts = 0
        atlasRestartsGivenUp = 0
    }
}

/// One rectangle for the GPU: where it goes, what part of the atlas it shows,
/// and in what colour. The layout matches `struct Instance` in the shader byte
/// for byte — 64 bytes, four sixteen-byte lanes.
struct CellInstance {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float>
    var colour: SIMD4<Float>
    /// `flags.x` is the mode — 0 solid, 1 coverage mask, 2 coloured glyph.
    /// A `uint4` rather than a `uint` because sixteen-byte lanes are what both
    /// languages agree on without either padding behind the other's back: the
    /// struct is 64 bytes on both sides, and that is checked at start-up.
    var flags: SIMD4<UInt32>

    static func solid(x: Float, y: Float, width: Float, height: Float,
                      colour: SIMD4<Float>) -> CellInstance {
        CellInstance(rect: SIMD4<Float>(x, y, width, height), uv: .zero,
                     colour: colour, flags: SIMD4<UInt32>(0, 0, 0, 0))
    }

    static func glyph(_ glyph: GlyphEntry, penX: Float, baselineY: Float,
                      colour: SIMD4<Float>) -> CellInstance {
        CellInstance(
            rect: SIMD4<Float>(penX + glyph.bearingX, baselineY - glyph.bearingTop,
                               glyph.width, glyph.height),
            uv: glyph.uv, colour: colour,
            flags: SIMD4<UInt32>(glyph.isColoured ? 2 : 1, 0, 0, 0))
    }
}
