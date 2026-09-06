//  PasteFramingTests.swift — the message that arrived as its own last 165
//  bytes, and the framing that stops it (ISC-166).
//
//  The negative pole is the point of this file. `deliversTheTailOnlyWithoutTheMarkers`
//  reproduces the defect on a real pty: the same 5275 bytes, written the way
//  the bubble used to write them, reach the far side in SIX reads, and a
//  reader that keeps one of them keeps 165 bytes starting mid-word. The
//  positive pole then shows those same bytes arriving as ONE object because
//  the markers say where it begins and ends. If the negative pole ever goes
//  green, the test above it has stopped meaning anything.

import Foundation
import Testing
import TerminalCore

/// A pty pair with the far side in raw mode, which is the mode every TUI puts
/// it in. Returns the two descriptors; the caller closes them.
private func rawPtyPair() -> (master: Int32, slave: Int32)? {
    var master: Int32 = 0
    var slave: Int32 = 0
    guard openpty(&master, &slave, nil, nil, nil) == 0 else { return nil }
    var raw = termios()
    tcgetattr(slave, &raw)
    cfmakeraw(&raw)
    tcsetattr(slave, TCSANOW, &raw)
    return (master, slave)
}

/// Reads until `wanted` bytes have arrived, reporting every read separately —
/// the reads are the whole subject here, not the total.
private func reads(from fd: Int32, until wanted: Int) -> [[UInt8]] {
    var pieces: [[UInt8]] = []
    var total = 0
    var buffer = [UInt8](repeating: 0, count: 65536)
    while total < wanted {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        pieces.append(Array(buffer[0 ..< n]))
        total += n
    }
    return pieces
}

/// His message, to the byte: 5247 characters, 5275 bytes of UTF-8.
private let longMessage = String(repeating: "un messaggio lungo come quello vero. ", count: 142)
    + "e poi sistemiamo il resto."

@Test func deliversTheTailOnlyWithoutTheMarkers() throws {
    let pair = try #require(rawPtyPair())
    defer { close(pair.master); close(pair.slave) }
    let payload = PasteFraming.payload(for: longMessage, bracketed: false)
    #expect(payload.count > 5000)

    let done = DispatchSemaphore(value: 0)
    var pieces: [[UInt8]] = []
    DispatchQueue.global().async {
        pieces = reads(from: pair.slave, until: payload.count)
        done.signal()
    }
    #expect(PtyWriter.writeAll(payload, to: pair.master))
    #expect(done.wait(timeout: .now() + 5) == .success)

    // The write was one call and every byte of it was accepted. The tty still
    // hands it over in pieces, and that is the whole defect: a reader that
    // keeps its last read keeps the tail of the message and nothing else.
    #expect(pieces.count > 1, "a message this long cannot arrive in one read")
    let tail = try #require(pieces.last)
    #expect(tail.count < payload.count / 2)
    #expect(pieces.flatMap { $0 } == payload)
}

@Test func marksTheWholeMessageAsOneObject() throws {
    let pair = try #require(rawPtyPair())
    defer { close(pair.master); close(pair.slave) }
    let payload = PasteFraming.payload(for: longMessage, bracketed: true)

    let done = DispatchSemaphore(value: 0)
    var pieces: [[UInt8]] = []
    DispatchQueue.global().async {
        pieces = reads(from: pair.slave, until: payload.count)
        done.signal()
    }
    #expect(PtyWriter.writeAll(payload, to: pair.master))
    #expect(done.wait(timeout: .now() + 5) == .success)

    let arrived = pieces.flatMap { $0 }
    // Still several reads — nothing can change that. What changed is that the
    // first one says «a paste begins» and the last one says where it ends, so
    // the far side knows to keep the pieces instead of the newest.
    #expect(pieces.count > 1)
    #expect(Array(arrived.prefix(PasteFraming.start.count)) == PasteFraming.start)
    #expect(Array(arrived.suffix(PasteFraming.end.count)) == PasteFraming.end)
    let body = arrived.dropFirst(PasteFraming.start.count).dropLast(PasteFraming.end.count)
    #expect(String(decoding: body, as: UTF8.self) == longMessage)
}

@Test func leavesTheMarkersOffAProgramThatNeverAskedForThem() {
    // Sent to a bare shell the markers are not a protocol, they are six
    // characters of rubbish on the command line.
    let plain = PasteFraming.payload(for: "ciao", bracketed: false)
    #expect(plain == Array("ciao".utf8))
    let marked = PasteFraming.payload(for: "ciao", bracketed: true)
    #expect(marked == PasteFraming.start + Array("ciao".utf8) + PasteFraming.end)
}

@Test func keepsTheNewlinesInsideTheMessage() {
    // The other half of the same defect: written as keystrokes, every newline
    // is a Return, so a message on three lines was three messages. Inside the
    // markers they are text.
    let payload = PasteFraming.payload(for: "primo\nsecondo\nterzo", bracketed: true)
    let body = payload.dropFirst(PasteFraming.start.count).dropLast(PasteFraming.end.count)
    #expect(body.filter { $0 == 0x0a }.count == 2)
    #expect(PasteFraming.submit == [0x0d])
}

@Test func writesEveryByteOrSaysItDidNot() {
    // A closed descriptor is the case where a writer that trusts one `write`
    // call would report success on nothing at all.
    #expect(PtyWriter.writeAll([], to: -1))
    #expect(!PtyWriter.writeAll([0x61], to: -1, timeout: 0.1))
}

/// A clipboard that carries the paste-end sequence must not be able to end
/// the paste: what follows it would otherwise reach the program as typed
/// keys, Return included (Gemini audit 2026-09-06).
@Test func aPastedEndMarkerCannotCloseTheBracketEarly() {
    let hostile = "harmless\u{1b}[201~rm -rf ~\r\u{1b}[200~"
    let bytes = PasteFraming.payload(for: hostile, bracketed: true)
    let body = Array(bytes[PasteFraming.start.count ..< bytes.count - PasteFraming.end.count])
    #expect(body == Array("harmless" .utf8) + Array("rm -rf ~\r".utf8))
    // Exactly one start and one end: ours, at the edges.
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(text.components(separatedBy: "\u{1b}[201~").count == 2)
    #expect(text.components(separatedBy: "\u{1b}[200~").count == 2)
    // Unbracketed, nothing is touched: a shell asked for raw keys.
    #expect(PasteFraming.payload(for: "a\tb\n", bracketed: false) == Array("a\tb\n".utf8))
}

