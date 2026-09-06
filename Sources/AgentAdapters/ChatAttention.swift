//  ChatAttention.swift — the small, pure decision behind the signs in the
//  tab strip and the route behind the waiting counter (ISC-237).

import Foundation
import TerminalCore

/// The memory behind a finished turn's attention.
///
/// A visit only counts while the turn is already finished.  A new finish
/// replaces that memory even if transcript events were coalesced and no
/// intermediate `working` refresh escaped; when it happens in the focused
/// pane, the answer is born seen and must never flash as unread.
public enum FinishedTurnAttention {
    public static func seenAfterUpdate(wasSeen: Bool,
                                       activity: AgentActivity,
                                       isNewFinish: Bool,
                                       isFocused: Bool) -> Bool {
        guard activity == .waiting else { return wasSeen }
        if isNewFinish { return isFocused }
        return wasSeen || isFocused
    }

    public static func needsAttention(activity: AgentActivity,
                                      wasSeen: Bool) -> Bool {
        activity == .waiting && !wasSeen
    }
}

/// What one tab has to say, after all of its panes have been considered.
///
/// The raw value is also the word exposed by the live dump.  Keeping the
/// precedence here means the painter, the controller and the tests cannot
/// quietly grow three different interpretations of the same booleans.
public enum ChatMarkKind: String, Sendable, Equatable {
    case none
    case working
    case finished
    case decision

    public static func resolve(decisions: Int, hasFinished: Bool,
                               finishedWasSeen: Bool,
                               hasWorking: Bool) -> ChatMarkKind {
        if decisions > 0 { return .decision }
        if hasFinished && !finishedWasSeen { return .finished }
        if hasWorking { return .working }
        return .none
    }
}

/// What a click on the exact `isWaitingForYou` result must do.
public enum WaitingRoute: String, Sendable, Equatable {
    case none
    case direct
    case menu

    public static func forCount(_ count: Int) -> WaitingRoute {
        if count <= 0 { return .none }
        if count == 1 { return .direct }
        return .menu
    }
}

/// A compact, stable age for a menu row.  It deliberately changes unit only
/// at whole boundaries: a menu opened at 59.8 seconds must not show a decimal
/// clock that twitches while somebody is choosing a chat.
public enum WaitingAge {
    public static func label(seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        if value < 5 { return "now" }
        if value < 60 { return "\(value) s" }
        if value < 3_600 { return "\(value / 60) min" }
        if value < 86_400 { return "\(value / 3_600) h" }
        return "\(value / 86_400) d"
    }
}
