//  OSCTap.swift — reads the operating-system-command sequences T4A cares
//  about out of the pty stream without consuming them.
//
//  Why a tap and not a handler: the VT engine has its own OSC 133 behaviour
//  (it tags cells so selection and prompt clicks work), and registering a
//  handler for a code REPLACES that behaviour. So every byte still goes to
//  the engine untouched, and we read the stream on the way past. The tap
//  reports a sequence at the exact byte boundary where it ends, which is what
//  lets the caller ask the grid where the cursor was at that instant.

import Foundation

public struct OSCSequence: Equatable, Sendable {
    public let code: Int
    /// Everything after the first `;`, without the terminator.
    public let payload: String

    public init(code: Int, payload: String) {
        self.code = code
        self.payload = payload
    }

    /// The payload split on `;`.
    public var fields: [String] {
        payload.isEmpty ? [] : payload.components(separatedBy: ";")
    }
}

public final class OSCTap {
    private enum State {
        case ground
        case escape          // saw ESC
        case code            // saw ESC ], reading digits
        case payload         // reading the payload
        case payloadEscape   // saw ESC inside the payload: ST candidate
    }

    /// Sequences longer than this are abandoned. A runaway OSC (a binary file
    /// catted into the terminal) must not grow a buffer without bound.
    private static let payloadCeiling = 64 * 1024

    private var state: State = .ground
    /// What the scanner is in the middle of, for diagnosis. A tap that wedges
    /// mid-sequence looks exactly like a shell that stopped talking, and the
    /// two need different repairs.
    public var stateName: String {
        switch state {
        case .ground: return "ground"
        case .escape: return "escape"
        case .code: return "code:\(code)"
        case .payload: return "payload:\(code)/\(payload.count)"
        case .payloadEscape: return "payloadEscape:\(code)"
        }
    }
    public private(set) var bytesSeen = 0
    public private(set) var sequencesSeen: [Int: Int] = [:]
    private var code = 0
    private var codeDigits = 0
    private var payload: [UInt8] = []
    /// Codes we bother to buffer a payload for. Everything else is parsed for
    /// its boundaries and thrown away, so an image pasted through OSC 1337
    /// costs nothing.
    private let interesting: Set<Int>

    public init(interesting: Set<Int> = [9, 133, 633, 777]) {
        self.interesting = interesting
    }

    /// Feeds `data` to `feed` in order, calling `sequence` immediately after
    /// the bytes that complete a recognised sequence. Every input byte reaches
    /// `feed` exactly once, in order.
    public func consume(_ data: ArraySlice<UInt8>,
                        feed: (ArraySlice<UInt8>) -> Void,
                        sequence: (OSCSequence) -> Void) {
        bytesSeen += data.count
        var segmentStart = data.startIndex

        func flush(through index: Int) {
            if index >= segmentStart {
                feed(data[segmentStart...index])
                segmentStart = index + 1
            }
        }

        for index in data.indices {
            let byte = data[index]
            switch state {
            case .ground:
                if byte == 0x1b { state = .escape }
            case .escape:
                if byte == 0x5d {            // ']'
                    state = .code
                    code = 0
                    codeDigits = 0
                    payload.removeAll(keepingCapacity: true)
                } else if byte == 0x1b {
                    // stay in .escape: ESC ESC
                } else {
                    state = .ground
                }
            case .code:
                if byte >= 0x30 && byte <= 0x39 {
                    if codeDigits < 6 {
                        code = code * 10 + Int(byte - 0x30)
                        codeDigits += 1
                    } else {
                        state = .ground   // absurd code, not ours
                    }
                } else if byte == 0x3b {     // ';'
                    state = codeDigits > 0 ? .payload : .ground
                } else if byte == 0x07 {
                    state = .ground          // OSC with no payload
                } else {
                    state = .ground
                }
            case .payload:
                if byte == 0x07 {            // BEL terminator
                    if let parsed = finish() { flush(through: index); sequence(parsed) }
                    state = .ground
                } else if byte == 0x1b {
                    state = .payloadEscape
                } else if byte == 0x18 || byte == 0x1a {  // CAN / SUB abort
                    state = .ground
                } else {
                    append(byte)
                }
            case .payloadEscape:
                if byte == 0x5c {            // ESC \  — the ST terminator
                    if let parsed = finish() { flush(through: index); sequence(parsed) }
                    state = .ground
                } else {
                    // Not a terminator: the ESC was payload after all.
                    append(0x1b)
                    append(byte)
                    state = .payload
                }
            }
        }

        if segmentStart <= data.indices.last ?? (segmentStart - 1) {
            feed(data[segmentStart...])
        }
    }

    private func append(_ byte: UInt8) {
        guard interesting.contains(code) else { return }
        guard payload.count < Self.payloadCeiling else {
            state = .ground
            return
        }
        payload.append(byte)
    }

    private func finish() -> OSCSequence? {
        guard interesting.contains(code) else { return nil }
        sequencesSeen[code, default: 0] += 1
        let text = String(decoding: payload, as: UTF8.self)
        payload.removeAll(keepingCapacity: true)
        return OSCSequence(code: code, payload: text)
    }
}
