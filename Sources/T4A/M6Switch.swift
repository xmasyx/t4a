//  M6Switch.swift — the one switch shape the whole app uses.
//
//  M6 is a gesture, not a state change: the knob STRETCHES in the direction
//  it is about to travel while the finger is down, then TRAVELS, then SETTLES.
//  A switch that snaps has no direction, and a switch whose direction you only
//  learn after releasing is a switch you have to try twice.
//
//  The quick tap is the case that matters and the one that is usually wrong:
//  a press-and-release inside a few milliseconds still gets the whole gesture,
//  compressed, because the animation is what tells you which way it went. The
//  gesture is timed here and reported in `lastGestureMs`, so "the tap gets the
//  gesture too" is a number a bench reads rather than a thing a person feels.

import AppKit

@MainActor
final class M6Switch: NSView, ThemeAware {
    func applyTheme() { applyColours() }

    /// How long the knob holds its stretch before it is allowed to travel.
    static let stretchMs: Double = 50
    /// How long the travel itself takes.
    static let travelSeconds: Double = 0.14

    private(set) var isOn: Bool
    /// The name a person reads for this switch. There is exactly one per row
    /// and it is this (ISC-104.6).
    let label: String
    var onChange: ((Bool) -> Void)?

    /// The last complete press-to-settled gesture, in milliseconds.
    private(set) var lastGestureMs: Double = 0

    private let track = CALayer()
    private let knob = CALayer()
    private var pressedAt: CFTimeInterval = 0
    private var pressed = false

    static let size = NSSize(width: 34, height: 18)

    init(label: String, isOn: Bool) {
        self.label = label
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        setAccessibilityLabel(label)
        toolTip = label
        layer?.addSublayer(track)
        track.addSublayer(knob)
        track.cornerRadius = 9
        track.borderWidth = 1
        knob.cornerRadius = 6
        applyColours()
        needsLayout = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        knob.frame = knobFrame(on: isOn, stretched: false)
        CATransaction.commit()
    }

    /// Off: the knob sits at the left. On: at the right. Stretched, it reaches
    /// toward where it is going and keeps its other edge planted.
    private func knobFrame(on: Bool, stretched: Bool) -> CGRect {
        let width: CGFloat = stretched ? 19 : 12
        let x: CGFloat = on ? bounds.width - 2 - width : 2
        return CGRect(x: x, y: 2, width: width, height: 12)
    }

    private func applyColours() {
        let palette = Theme.current
        track.backgroundColor = palette.ground.cgColor
        track.borderColor = (isOn ? palette.muted : palette.hairline).cgColor
        knob.backgroundColor = (isOn ? palette.ink : palette.whisper).cgColor
    }

    override func mouseDown(with event: NSEvent) { beginPress() }
    override func mouseUp(with event: NSEvent) { endPress() }

    private func beginPress() {
        pressedAt = CACurrentMediaTime()
        pressed = true
        animate(to: knobFrame(on: isOn, stretched: true), seconds: Self.stretchMs / 1000)
    }

    private func endPress() {
        guard pressed else { return }
        pressed = false
        let held = (CACurrentMediaTime() - pressedAt) * 1000
        let wait = max(0, Self.stretchMs - held) / 1000
        if wait == 0 { settle() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.settle() } }
    }

    /// Flip in place and let the travel carry the knob across. The value
    /// changes when the gesture commits, not when the finger lands: a press
    /// that has not been released yet has not chosen anything.
    private func settle() {
        isOn.toggle()
        applyColours()
        animate(to: knobFrame(on: isOn, stretched: false), seconds: Self.travelSeconds)
        let start = pressedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.travelSeconds) { [weak self] in
            guard let self else { return }
            self.lastGestureMs = (CACurrentMediaTime() - start) * 1000
        }
        onChange?(isOn)
    }

    private func animate(to frame: CGRect, seconds: Double) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(seconds)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        knob.frame = frame
        CATransaction.commit()
    }

    /// Presses the switch the way a click does, for the bench: the same
    /// gesture a person makes, not a private door into the same function.
    func press() {
        beginPress()
        endPress()
    }

    func set(on: Bool) {
        guard on != isOn else { return }
        isOn = on
        applyColours()
        animate(to: knobFrame(on: on, stretched: false), seconds: Self.travelSeconds)
    }
}
