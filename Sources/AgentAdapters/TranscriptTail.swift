//  TranscriptTail.swift — following a file someone else is writing, without
//  ever writing to it.
//
//  Two rules shape this file. It is READ-ONLY: the descriptor is opened
//  `O_RDONLY` and there is no code path here that can produce a write, which
//  is what ISC-5 checks from outside with a filesystem watch. And it is
//  EVENT-DRIVEN: a kqueue tells us the file grew, so a terminal watching an
//  idle agent for an hour costs exactly nothing, which is what ISC-38 says.

import Foundation

/// Follows one file, handing over whole lines as they are appended.
final class TranscriptTail {
    let url: URL
    private var descriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var partial = Data()

    /// Called on the main queue with the complete lines that just arrived.
    private let onLines: ([String]) -> Void
    /// Called when the file was replaced or removed under us.
    private let onVanished: () -> Void
    /// Called when the file was rewritten shorter and this tail went back to
    /// the beginning: whatever was built from the old bytes has to be built
    /// again, or the reader ends up with the file twice.
    var onTruncated: (() -> Void)?
    /// How many times that has happened, for the tests and the dump.
    private(set) var truncations = 0

    init?(url: URL, onLines: @escaping ([String]) -> Void,
          onVanished: @escaping () -> Void) {
        self.url = url
        self.onLines = onLines
        self.onVanished = onVanished
        // Read-only, and no `O_CREAT`: if the file is not there, nothing is
        // brought into being by looking for it. The observer belongs to T4A,
        // so a shell it starts must not inherit the descriptor.
        descriptor = open(url.path, O_RDONLY | O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.extend, .write, .delete, .rename, .link],
            queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.onVanished()
                return
            }
            self.drain()
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit { stop() }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    /// Reads everything appended since the last read and hands over whole
    /// lines. A record split across two writes is held until its newline
    /// arrives: half a JSON object parsed as a whole one is a lie that looks
    /// like a parse error.
    func drain() {
        guard descriptor >= 0 else { return }
        // A file that got SHORTER was rewritten, not appended to (ISC-134).
        //
        // Deletion and rename are handled — the source reports them and the
        // observer goes and finds the file again — but a truncation in place
        // is neither: the descriptor is still valid, still points at the same
        // inode, and the offset now sits past the end. `pread` returns 0 for
        // ever after and the pane goes quiet without a word. Both vendors
        // append today and this has never been seen; it costs one `fstat` a
        // drain, and the alternative is a session that stops updating with
        // nothing anywhere saying why.
        var info = stat()
        if fstat(descriptor, &info) == 0, offset > UInt64(max(0, info.st_size)) {
            NSLog("T4A: \(url.lastPathComponent) is shorter than what we had read "
                + "(\(offset) > \(info.st_size)); reading it again from the start")
            offset = 0
            partial.removeAll(keepingCapacity: false)
            truncations += 1
            onTruncated?()
        }
        var lines: [String] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let read = pread(descriptor, &buffer, buffer.count, off_t(offset))
            guard read > 0 else { break }
            offset += UInt64(read)
            partial.append(contentsOf: buffer[0..<read])
            while let index = partial.firstIndex(of: 0x0a) {
                let slice = partial[partial.startIndex..<index]
                partial.removeSubrange(partial.startIndex...index)
                if !slice.isEmpty { lines.append(String(decoding: slice, as: UTF8.self)) }
            }
            if read < buffer.count { break }
        }
        guard !lines.isEmpty else { return }
        onLines(lines)
    }

    /// How far into the file we have read. Used only for diagnosis.
    var bytesRead: UInt64 { offset }
}

/// Watches a directory for the file we are waiting for, then stops.
///
/// It exists because a session's transcript does not exist at the moment the
/// agent starts: the file is created when the first turn is written. A poll
/// would be the obvious answer and the wrong one — a directory kqueue fires
/// on the creation itself, so the attach is bounded by the write and not by
/// a tick (ISC-25 measures that bound).
final class DirectoryWatch {
    private var descriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    let url: URL

    init?(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        // Waiting for a transcript is T4A's work, not a descriptor that a
        // shell or anything it launches should carry.
        descriptor = open(url.path, O_RDONLY | O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main)
        source.setEventHandler { onChange() }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit { stop() }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }
}
