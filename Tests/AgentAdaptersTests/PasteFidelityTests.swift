//  PasteFidelityTests.swift — the payload decides whether Claude sees a path
//  or an attachment (ISC-241).

import Foundation
import Testing
@testable import TerminalCore

@Test func anAttachmentAloneIsExactlyOneQuotedPayload() {
    let path = #""/tmp/prova paste t4a.png""#
    let submission = ComposerSubmission(
        written: "[Image #1]",
        isolatedAttachments: ["[Image #1]": path])

    #expect(submission.text == path)
    #expect(submission.payloads == [path])
}

@Test func proseNeverSharesTheAttachmentFrame() {
    let path = #""/tmp/prova paste t4a.png""#
    let submission = ComposerSubmission(
        written: "guarda [Image #1] per favore",
        isolatedAttachments: ["[Image #1]": path])

    #expect(submission.text == "guarda \(path) per favore")
    #expect(submission.payloads == ["guarda ", path, " per favore"])
    let framed = PasteFraming.payloads(for: submission.payloads, bracketed: true)
    #expect(framed.count == 3)
    #expect(framed[1] == PasteFraming.start + Array(path.utf8) + PasteFraming.end)
    #expect(!framed[1].contains(0x0d))
}

@Test func collapsedTextStillExpandsInsideOneMessage() {
    let submission = ComposerSubmission(
        written: "prima [Pasted text #1 +5 lines] dopo",
        inlineExpansions: ["[Pasted text #1 +5 lines]": "uno\ndue\ntre\nquattro\ncinque"])

    #expect(submission.payloads == ["prima uno\ndue\ntre\nquattro\ncinque dopo"])
}

@Test func fileURLsBecomeFullQuotedPathsOneByOne() {
    let files = [
        URL(fileURLWithPath: "/tmp/cartella con spazi/film intero.mov"),
        URL(fileURLWithPath: "/tmp/secondo.mov"),
        URL(string: "https://example.com/not-a-file")!,
    ]

    #expect(ClipboardImage.quotedFilePaths(files) == [
        #""/tmp/cartella con spazi/film intero.mov""#,
        #""/tmp/secondo.mov""#,
    ])
}

@Test func temporaryItemsScreenshotRoutesThroughCache() {
    #expect(ClipboardImage.shouldRouteThroughCache(
        path: "/private/var/folders/x/TemporaryItems/NSIRD_screencaptureui_1/screenshot.png",
        isDirectory: false))
}

@Test func desktopImageRoutesThroughCacheWithoutALocationRule() {
    #expect(ClipboardImage.shouldRouteThroughCache(
        path: "/Users/example/Desktop/screenshot.png",
        isDirectory: false))
}

@Test func imageExtensionMatchingIsCaseInsensitive() {
    #expect(ClipboardImage.shouldRouteThroughCache(
        path: "/tmp/screenshot.PNG",
        isDirectory: false))
}

@Test func everySupportedImageExtensionRoutesThroughCache() {
    for ext in ["png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp", "heic"] {
        #expect(ClipboardImage.shouldRouteThroughCache(
            path: "/tmp/image.\(ext)",
            isDirectory: false))
    }
}

@Test func movieDoesNotRouteThroughCache() {
    #expect(!ClipboardImage.shouldRouteThroughCache(
        path: "/tmp/movie.mov",
        isDirectory: false))
}

@Test func directoryWithImageExtensionDoesNotRouteThroughCache() {
    #expect(!ClipboardImage.shouldRouteThroughCache(
        path: "/tmp/shots.png",
        isDirectory: true))
}

@Test func documentDoesNotRouteThroughCache() {
    #expect(!ClipboardImage.shouldRouteThroughCache(
        path: "/tmp/document.pdf",
        isDirectory: false))
}

@Test func imageCopyKeepsBytesAndOriginalExtension() throws {
    let fixture = try PasteCacheFixture()
    defer { fixture.remove() }
    let source = fixture.root.appendingPathComponent("source.HeIc")
    let bytes = Data([0x00, 0x01, 0xfe, 0xff, 0x42])
    try bytes.write(to: source)

    let copied = ClipboardImage.copyImageFileToCache(
        path: source.path,
        cacheDirectory: fixture.cache,
        date: Date(timeIntervalSince1970: 1))

    #expect(copied?.hasSuffix(".HeIc") == true)
    #expect(copied.map { FileManager.default.contents(atPath: $0) } == bytes)
    #expect(FileManager.default.contents(atPath: source.path) == bytes)
}

@Test func nonexistentImageCopyReturnsNil() throws {
    let fixture = try PasteCacheFixture()
    defer { fixture.remove() }

    #expect(ClipboardImage.copyImageFileToCache(
        path: fixture.root.appendingPathComponent("vanished.png").path,
        cacheDirectory: fixture.cache,
        date: Date(timeIntervalSince1970: 1)) == nil)
}

@Test func twoImageCopiesAtTheSameMillisecondDoNotCollide() throws {
    let fixture = try PasteCacheFixture()
    defer { fixture.remove() }
    let firstSource = fixture.root.appendingPathComponent("first.PNG")
    let secondSource = fixture.root.appendingPathComponent("second.PNG")
    try Data("first".utf8).write(to: firstSource)
    try Data("second".utf8).write(to: secondSource)

    let firstCopy = ClipboardImage.copyImageFileToCache(
        path: firstSource.path,
        cacheDirectory: fixture.cache,
        date: Date(timeIntervalSince1970: 1))
    let secondCopy = ClipboardImage.copyImageFileToCache(
        path: secondSource.path,
        cacheDirectory: fixture.cache,
        date: Date(timeIntervalSince1970: 1))

    #expect(firstCopy == fixture.cache.appendingPathComponent("paste-1000.PNG").path)
    #expect(secondCopy == fixture.cache.appendingPathComponent("paste-1000-1.PNG").path)
    #expect(firstCopy.map { FileManager.default.contents(atPath: $0) } == Data("first".utf8))
    #expect(secondCopy.map { FileManager.default.contents(atPath: $0) } == Data("second".utf8))
}

@Test func routingCopyFailureKeepsOriginalQuotedPath() throws {
    let fixture = try PasteCacheFixture()
    defer { fixture.remove() }
    let source = fixture.root.appendingPathComponent("source.png")
    try Data("source".utf8).write(to: source)

    let paths = ClipboardImage.routedQuotedFilePaths([source]) { _ in nil }

    #expect(paths == [ClipboardImage.quoted(source.path)])
}

@Test func routingKeepsDirectoryWithImageExtensionAtOriginalPath() throws {
    let fixture = try PasteCacheFixture()
    defer { fixture.remove() }
    let directory = fixture.root.appendingPathComponent("shots.png", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let paths = ClipboardImage.routedQuotedFilePaths([directory]) { _ in
        Issue.record("A directory must never reach the copier")
        return nil
    }

    #expect(paths == [ClipboardImage.quoted(directory.path)])
}

@Test func routingCopiesImagesAndLeavesOtherFileURLsAlone() throws {
    let fixture = try PasteCacheFixture()
    defer { fixture.remove() }
    let image = fixture.root.appendingPathComponent("source.webp")
    let movie = fixture.root.appendingPathComponent("source.mov")
    try Data("image".utf8).write(to: image)
    try Data("movie".utf8).write(to: movie)

    let paths = ClipboardImage.routedQuotedFilePaths([image, movie]) { path in
        ClipboardImage.copyImageFileToCache(
            path: path,
            cacheDirectory: fixture.cache,
            date: Date(timeIntervalSince1970: 2))
    }

    #expect(paths[0] == ClipboardImage.quoted(
        fixture.cache.appendingPathComponent("paste-2000.webp").path))
    #expect(paths[1] == ClipboardImage.quoted(movie.path))
}

private struct PasteCacheFixture {
    let root: URL
    let cache: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t4a-paste-cache-\(UUID().uuidString)", isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
