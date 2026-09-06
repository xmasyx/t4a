//  ClipboardImage.swift — a picture from the clipboard or a drag, put where something
//  that only speaks in paths can reach it.
//
//  A terminal pastes strings. A screenshot is not a string, so ⌘V on one used
//  to do nothing at all, in the pane and in the bubble alike — no error, no
//  beep, just a key that looked broken (his report, 2026-08-24). An agent in
//  the pane can take the image itself, and for everything else the file on
//  disk is the only thing that can be handed over.

import AppKit
import Foundation

public enum ClipboardImage {
    /// File URLs carried by the pasteboard, quoted one by one for the hosted
    /// program. A Finder copy may also advertise a display name as plain text;
    /// the URL type is the authority, so this intentionally never reads that
    /// string while deciding whether files are present.
    public static func filePaths(on board: NSPasteboard = .general) -> [String] {
        guard board.availableType(from: [.fileURL]) != nil,
              let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL]
        else { return [] }
        return routedQuotedFilePaths(urls)
    }

    /// The non-AppKit half of `filePaths`, kept separate because a sandbox
    /// can deny every pasteboard while path spelling remains testable.
    public static func quotedFilePaths(_ urls: [URL]) -> [String] {
        urls.filter(\.isFileURL).map { quoted($0.path) }
    }

    /// Decision only — no I/O. `isDirectory` comes from the caller because a
    /// folder named "shots.png" is not an image.
    public static func shouldRouteThroughCache(path: String, isDirectory: Bool) -> Bool {
        guard !isDirectory else { return false }
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp", "heic"]
        return imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Copies an image file into the location where the hosted program accepts
    /// path-backed attachments. Failure is deliberately visible to the caller,
    /// which can still send the source path instead of losing the paste.
    public static func copyImageFileToCache(path: String) -> String? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/T4A/pasted", isDirectory: true)
        return copyImageFileToCache(path: path, cacheDirectory: directory, date: Date())
    }

    static func copyImageFileToCache(
        path: String,
        cacheDirectory: URL,
        date: Date
    ) -> String? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let source = URL(fileURLWithPath: path)
        let stamp = Int(date.timeIntervalSince1970 * 1000)
        let ext = source.pathExtension
        var disambiguator = 0
        while true {
            let suffix = disambiguator == 0 ? "" : "-\(disambiguator)"
            let destination = cacheDirectory
                .appendingPathComponent("paste-\(stamp)\(suffix).\(ext)")
            do {
                try manager.copyItem(at: source, to: destination)
                return destination.path
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                guard disambiguator < Int.max else { return nil }
                disambiguator += 1
            } catch {
                return nil
            }
        }
    }

    static func routedQuotedFilePaths(
        _ urls: [URL],
        copy: (String) -> String? = copyImageFileToCache(path:)
    ) -> [String] {
        urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let original = quoted(url.path)
            guard shouldRouteThroughCache(path: url.path, isDirectory: false) else {
                return original
            }

            let isDirectory: Bool
            do {
                // Unknown metadata must not turn a directory into a copied tree.
                isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? true
            } catch {
                return original
            }
            guard shouldRouteThroughCache(path: url.path, isDirectory: isDirectory) else {
                return original
            }
            guard let cached = copy(url.path) else { return original }
            return quoted(cached)
        }
    }

    /// True when the clipboard is carrying a picture.
    ///
    /// Asked separately from writing it, so the case that does not need a file
    /// — an agent reading the clipboard on its own — never leaves one behind.
    public static func isOnClipboard(_ board: NSPasteboard = .general) -> Bool {
        board.availableType(from: [.png, .tiff]) != nil
    }

    /// Writes the picture as PNG and answers with a path ready to be typed.
    ///
    /// The name carries the clock so two pastes never collide, and the
    /// quoting is not optional: the folder is under the home directory, which
    /// on a Mac with a two-word user name has a space in it.
    public static func writeToDisk(_ board: NSPasteboard = .general) -> String? {
        guard let type = board.availableType(from: [.png, .tiff]),
              let raw = board.data(forType: type) else { return nil }
        let png: Data
        if type == .png {
            png = raw
        } else if let rep = NSBitmapImageRep(data: raw),
                  let converted = rep.representation(using: .png, properties: [:]) {
            png = converted
        } else {
            return nil
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/T4A/pasted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = dir.appendingPathComponent("paste-\(stamp).png")
        do { try png.write(to: url) } catch { return nil }
        return quoted(url.path)
    }

    public static func quoted(_ path: String) -> String {
        // The measured Claude form is the quoted form, not merely the form
        // used when a shell happens to need protection from spaces. Keeping
        // one spelling also means a cache path without spaces and a Finder
        // path with spaces take the same, proven road.
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// What a drag is carrying, turned into things a terminal can say.
///
/// Nothing in T4A accepted a drop before this: neither the pane nor the bubble
/// registered a single dragged type, so a screenshot dragged onto the window
/// bounced with no sign at all (his report, 2026-08-24). A file already on
/// disk travels as its path; a picture dragged out of a browser has no path
/// yet, so one is made for it.
public enum DroppedItems {
    public static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    public static func paths(from board: NSPasteboard) -> [String] {
        let files = ClipboardImage.filePaths(on: board)
        if !files.isEmpty { return files }
        if let made = ClipboardImage.writeToDisk(board) { return [made] }
        return []
    }
}
