//  TerminalLinkCursor.swift — the deterministic state behind Command-hover's
//  AppKit cursor side effects.

import Foundation

/// The last cursor decision and the counters that distinguish "never pushed"
/// from "pushed, then overwritten" in a live test-channel dump.
public struct TerminalLinkCursorTrace: Equatable, Sendable {
    public struct Transition: Equatable, Sendable {
        public let kind: String
        public let timestamp: TimeInterval

        public init(kind: String, timestamp: TimeInterval) {
            self.kind = kind
            self.timestamp = timestamp
        }
    }

    public private(set) var pushes = 0
    public private(set) var pops = 0
    public private(set) var pointingHandSets = 0
    public private(set) var cursorUpdatesConsumed = 0
    public private(set) var lastTransition: Transition?

    public init() {}

    mutating func recordPush(at timestamp: TimeInterval) {
        pushes += 1
        record("push", at: timestamp)
    }

    mutating func recordPop(at timestamp: TimeInterval) {
        pops += 1
        record("pop", at: timestamp)
    }

    mutating func recordPointingHandSet(for event: TerminalLinkCursorPointerEvent,
                                        at timestamp: TimeInterval) {
        pointingHandSets += 1
        switch event {
        case .mouseMoved:
            record("mouseMoved:setPointingHand", at: timestamp)
        case .cursorUpdate:
            cursorUpdatesConsumed += 1
            record("cursorUpdate:setPointingHand+consumed", at: timestamp)
        }
    }

    private mutating func record(_ kind: String, at timestamp: TimeInterval) {
        lastTransition = Transition(kind: kind, timestamp: timestamp)
    }
}

public enum TerminalLinkCursorStackAction: Equatable, Sendable {
    case none
    case push
    case pop
}

public enum TerminalLinkCursorPointerEvent: Equatable, Sendable {
    case mouseMoved
    case cursorUpdate
}

public struct TerminalLinkCursorEventAction: Equatable, Sendable {
    public let reassertPointingHand: Bool
    public let consume: Bool

    public init(reassertPointingHand: Bool, consume: Bool) {
        self.reassertPointingHand = reassertPointingHand
        self.consume = consume
    }
}

/// Owns one balanced cursor-stack entry and decides what the AppKit adapter
/// must do for each monitored event. It has no AppKit dependency so the exact
/// push/pop/consume contract can be exercised without a WindowServer.
public struct TerminalLinkCursorState: Equatable, Sendable {
    public private(set) var stackHeld = false
    public private(set) var trace = TerminalLinkCursorTrace()

    public init() {}

    public mutating func setHover(active: Bool,
                                  at timestamp: TimeInterval) -> TerminalLinkCursorStackAction {
        if active, !stackHeld {
            stackHeld = true
            trace.recordPush(at: timestamp)
            return .push
        }
        if !active, stackHeld {
            stackHeld = false
            trace.recordPop(at: timestamp)
            return .pop
        }
        return .none
    }

    public mutating func handle(_ event: TerminalLinkCursorPointerEvent,
                                at timestamp: TimeInterval) -> TerminalLinkCursorEventAction {
        guard stackHeld else {
            return TerminalLinkCursorEventAction(reassertPointingHand: false, consume: false)
        }
        trace.recordPointingHandSet(for: event, at: timestamp)
        switch event {
        case .mouseMoved:
            return TerminalLinkCursorEventAction(reassertPointingHand: true, consume: false)
        case .cursorUpdate:
            return TerminalLinkCursorEventAction(reassertPointingHand: true, consume: true)
        }
    }
}
