//  PasteFraming.swift — a message written in the bubble travels as a PASTE,
//  not as five thousand keystrokes (ISC-166).
//
//  The defect this exists for, measured 2026-08-25. He wrote 5275 bytes in the
//  composer and the session received the last 165 of them, starting mid-word
//  («oi sistemiamo il resto…»). Nothing was dropped by us: one
//  `DispatchIO.write` accepted all 5275 bytes. The tty hands them to the child
//  in pieces — measured on a bare `openpty` pair with the slave in raw mode:
//  1022, 1022, 1022, 1022, 1022, 165, the last piece beginning at byte 5110 —
//  and 5110 is EXACTLY the offset where the surviving fragment began in the
//  agent's transcript. A TUI that keeps one read of a burst of keystrokes
//  therefore keeps only the tail, and the person who wrote the message has no
//  way to see that it happened.
//
//  The cure is the one every terminal already uses for ⌘V: bracketed paste
//  (DECSET 2004). The markers tell the program on the other side that what
//  arrives between them is ONE object, to be accumulated until the end marker
//  whatever the read boundaries fall on — and, the second half of the same
//  bug, that the newlines inside it are text and not a Return each.
//
//  Two independent confirmations that this is the right shape, not a guess.
//  SwiftTerm already does it for a real paste (`MacTerminalView.insertText`,
//  `isPaste: true`), which is why he only ever saw the loss from the bubble.
//  And `claude` itself, when one session writes into another's pty, sends
//  `\u{1b}[200~<text>\u{1b}[201~` and then `\r` on a short timer — the same
//  two moves, read out of the 2.1.245 binary.

import Foundation

/// How the bytes of a composed message are laid out before they go down the
/// pty. Pure, so the framing can be asserted without a terminal.
public enum PasteFraming {
    /// DECSET 2004 start marker: `ESC [ 2 0 0 ~`.
    public static let start: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]
    /// DECSET 2004 end marker: `ESC [ 2 0 1 ~`.
    public static let end: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]
    /// Return, sent on its own after the paste has landed.
    public static let submit: [UInt8] = [0x0d]

    /// A payload the far side cannot mistake for typing.
    ///
    /// Only when it asked: writing the markers to a program that never enabled
    /// 2004 would put `ESC[200~` into its input as literal characters, so the
    /// flag is read from the terminal and never assumed. Unbracketed, the text
    /// travels as it did before — which is correct for a shell, the only thing
    /// that normally leaves 2004 off.
    public static func payload(for text: String, bracketed: Bool) -> [UInt8] {
        let body = Array(text.utf8)
        guard bracketed else { return body }
        return start + sanitized(body) + end
    }

    /// The one thing a pasted body must never carry: its own end marker.
    ///
    /// A payload containing `ESC[201~` would close the paste early and hand
    /// the rest of the clipboard to the program as keystrokes — a command
    /// ending in Return, typed by a page you copied from. Both markers are
    /// removed (a nested start is as foreign to a paste as an early end);
    /// everything else, tabs and newlines included, is the user's text and
    /// travels as it is. (Gemini audit 2026-09-06, ISC-166.)
    public static func sanitized(_ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(body.count)
        var index = 0
        while index < body.count {
            if body[index] == 0x1b,
               matches(body, at: index, end) || matches(body, at: index, start) {
                index += end.count
                continue
            }
            out.append(body[index])
            index += 1
        }
        return out
    }

    private static func matches(_ body: [UInt8], at index: Int, _ marker: [UInt8]) -> Bool {
        guard index + marker.count <= body.count else { return false }
        return Array(body[index ..< index + marker.count]) == marker
    }

    /// Several paste objects, each with its own boundary. In particular this
    /// keeps an attachment path out of the prose beside it.
    public static func payloads(for texts: [String], bracketed: Bool) -> [[UInt8]] {
        texts.map { payload(for: $0, bracketed: bracketed) }.filter { !$0.isEmpty }
    }
}

/// One message from the composer, kept as the paste objects the hosted
/// program must receive.
///
/// Most messages are one object. An image path is different: Claude decides
/// whether it is an attachment at the end of a bracketed-paste object, so
/// joining prose to either side of the path changes the object it is asked to
/// recognise. The visible token is therefore replaced by a payload of its
/// own; ordinary collapsed text is still expanded inline, exactly as before.
public struct ComposerSubmission: Equatable, Sendable {
    /// The old, fully expanded representation, used by history and receipts.
    public let text: String
    /// The ordered bracketed-paste objects written to the pty.
    public let payloads: [String]

    public init(written: String,
                inlineExpansions: [String: String] = [:],
                isolatedAttachments: [String: String] = [:]) {
        var source = written.trimmingCharacters(in: .whitespacesAndNewlines)
        for (token, body) in inlineExpansions {
            source = source.replacingOccurrences(of: token, with: body)
        }

        var payloads: [String] = []
        var remainder = source[...]
        while !remainder.isEmpty {
            let next = isolatedAttachments.compactMap { token, body ->
                (range: Range<String.Index>, body: String)? in
                guard let range = remainder.range(of: token) else { return nil }
                return (range, body)
            }.min { $0.range.lowerBound < $1.range.lowerBound }

            guard let next else {
                payloads.append(String(remainder))
                break
            }
            if next.range.lowerBound > remainder.startIndex {
                payloads.append(String(remainder[..<next.range.lowerBound]))
            }
            payloads.append(next.body)
            remainder = remainder[next.range.upperBound...]
        }

        self.payloads = payloads.filter { !$0.isEmpty }
        self.text = self.payloads.joined()
    }
}

/// Writing a payload to a pty without losing the part that did not fit.
public enum PtyWriter {
    /// The pty is non-blocking — `DispatchIO` made it so — so a write of more
    /// than the tty will hold comes back short, or refused with `EAGAIN`, and
    /// the rest has to be offered again. Answering a short write with «sent»
    /// is exactly the silent truncation this file exists for. Blocking, so it
    /// belongs on a queue of its own.
    @discardableResult
    public static func writeAll(_ bytes: [UInt8], to fd: Int32,
                                timeout: TimeInterval = 10) -> Bool {
        guard !bytes.isEmpty else { return true }
        var sent = 0
        let deadline = Date().addingTimeInterval(timeout)
        return bytes.withUnsafeBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            while sent < buffer.count {
                let written = write(fd, base.advanced(by: sent), buffer.count - sent)
                if written > 0 { sent += written; continue }
                if errno == EAGAIN || errno == EINTR {
                    guard Date() < deadline else { return false }
                    usleep(2_000)
                    continue
                }
                return false
            }
            return true
        }
    }
}
