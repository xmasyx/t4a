//  RetryAdoptionPolicy.swift — when an idle pane may poll for a late agent pid.

/// A still pane pays for a process-tree lookup only during the one state that
/// can make progress: its live agent is attached but has no process yet.
public enum RetryAdoptionPolicy {
    public static func shouldRun(sessionIsAlive: Bool, isAttached: Bool,
                                 hasProcess: Bool) -> Bool {
        sessionIsAlive && isAttached && !hasProcess
    }
}
