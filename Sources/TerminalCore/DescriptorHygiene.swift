//  DescriptorHygiene.swift — keeping T4A's descriptors out of its children.

import Darwin

/// What crosses an exec is exactly the set of descriptors WITHOUT
/// FD_CLOEXEC in the parent at that moment, so a child that must start
/// clean is a property of the parent's table right before the spawn.
public enum DescriptorHygiene {
    /// Marks every descriptor from `lowest` up close-on-exec. Returns how
    /// many were marked (those that were open and not yet marked). Uses
    /// `proc_pidinfo(getpid(), PROC_PIDLISTFDS, …)` to visit only open
    /// descriptors — a loop to `getdtablesize()` is thousands of syscalls
    /// for a table with a few dozen entries.
    @discardableResult
    public static func markCloseOnExec(from lowest: Int32 = 3) -> Int {
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return 0 }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let written = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, bytes)
        }
        guard written > 0 else { return 0 }

        let firstDescriptor = max(Int32(3), lowest)
        var marked = 0
        for info in descriptors.prefix(Int(written) / MemoryLayout<proc_fdinfo>.size) {
            let descriptor = info.proc_fd
            guard descriptor >= firstDescriptor,
                  isCloseOnExec(descriptor) == false else { continue }
            if markCloseOnExec(descriptor) { marked += 1 }
        }
        return marked
    }

    /// Marks one descriptor. Returns false when `fcntl` refused.
    @discardableResult
    public static func markCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0 else { return false }
        return fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) >= 0
    }

    /// True when the descriptor carries FD_CLOEXEC. Nil when it is not open.
    public static func isCloseOnExec(_ descriptor: Int32) -> Bool? {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0 else { return nil }
        return flags & FD_CLOEXEC != 0
    }
}
