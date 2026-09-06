//  TabDoorWatcher.swift — the local file channel that opens and closes panes.
//
//  A directory notification wakes it only when an entry changes. There is no
//  polling clock: an idle door schedules no work, just like transcript attach.

import Darwin
import Foundation
import TerminalCore

@MainActor
final class TabDoorWatcher {
    private let directory: URL
    private let openRequest: (TabRequest) -> UUID
    private let closeRequest: (UUID) -> DoorCloseResult
    private var descriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    init?(
        directory: URL,
        openRequest: @escaping (TabRequest) -> UUID,
        closeRequest: @escaping (UUID) -> DoorCloseResult
    ) {
        self.directory = directory
        self.openRequest = openRequest
        self.closeRequest = closeRequest
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            NSLog("T4A: could not create door at %@: %@", directory.path,
                  error.localizedDescription)
            return nil
        }

        // The door belongs to T4A; panes must not inherit its watch descriptor.
        descriptor = open(directory.path, O_RDONLY | O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            NSLog("T4A: could not watch door at %@: %@", directory.path,
                  String(cString: strerror(errno)))
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in self?.processPending() }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source

        // The watch is armed before the first scan so a request arriving
        // during launch cannot fall between "already there" and "new file".
        processPending()
        NSLog("T4A: door open at %@", directory.path)
    }

    deinit { source?.cancel() }

    private func processPending() {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            NSLog("T4A: could not read door at %@: %@", directory.path,
                  error.localizedDescription)
            return
        }

        for file in files {
            guard let request = TabDoor.kind(ofFile: file.lastPathComponent) else { continue }
            switch request.kind {
            case .open: processOpen(name: request.name, file: file)
            case .close: processClose(name: request.name, file: file)
            }
        }
    }

    private func processOpen(name: String, file: URL) {
        let result: Result<TabRequest, TabDoorError>
        do {
            let data = try Data(contentsOf: file)
            result = TabDoor.parseOpen(name: name, data: data) { path in
                var directory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                    && directory.boolValue
            }
        } catch {
            result = .failure(.notJSON)
        }
        guard consume(file) else { return }

        switch result {
        case .success(let request):
            let id = openRequest(request)
            writeReply(name: name, reply: .opened, object: ["session": id.uuidString])
        case .failure(let error):
            let reason = Self.reason(for: error)
            NSLog("T4A: door open %@ rejected: %@", name, reason)
            writeReply(name: name, reply: .rejected,
                       object: ["reason": reason])
        }
    }

    private func processClose(name: String, file: URL) {
        let id = (try? Data(contentsOf: file)).flatMap(TabDoor.parseClose)
        guard consume(file) else { return }
        guard let id else {
            NSLog("T4A: door close %@ names no session", name)
            writeReply(name: name, reply: .closed,
                       object: ["closed": false, "reason": "invalid"])
            return
        }

        let result = closeRequest(id)
        switch result {
        case .closed:
            writeReply(name: name, reply: .closed, object: ["closed": true])
        case .working:
            NSLog("T4A: door did not close session %@: working", id.uuidString)
            writeReply(name: name, reply: .closed,
                       object: ["closed": false, "reason": "working"])
        case .unknown:
            NSLog("T4A: door found no session %@", id.uuidString)
            writeReply(name: name, reply: .closed,
                       object: ["closed": false, "reason": "unknown"])
        case .last:
            NSLog("T4A: door did not close session %@: last pane", id.uuidString)
            writeReply(name: name, reply: .closed,
                       object: ["closed": false, "reason": "last"])
        }
    }

    /// Consumption precedes every side effect and every reply. If removal
    /// fails, processing stops so one request can never open two panes.
    private func consume(_ file: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: file)
            return true
        } catch {
            NSLog("T4A: could not consume door request %@: %@", file.lastPathComponent,
                  error.localizedDescription)
            return false
        }
    }

    private func writeReply(name: String, reply: TabDoor.Reply, object: [String: Any]) {
        let file = directory.appendingPathComponent(TabDoor.replyFileName(for: name,
                                                                          reply: reply))
        do {
            let data = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.sortedKeys])
            try data.write(to: file, options: [.atomic])
        } catch {
            NSLog("T4A: could not write door reply %@: %@", file.lastPathComponent,
                  error.localizedDescription)
        }
    }

    private static func reason(for error: TabDoorError) -> String {
        switch error {
        case .badName: return "invalid request name"
        case .notJSON: return "not a JSON object"
        case .missing(let field): return "missing \(field)"
        case .noSuchDirectory: return "cwd is not an existing directory"
        case .emptyCommand: return "command is empty"
        case .multilineCommand: return "command has more than one line"
        case .commandTooLong: return "command is too long"
        case .labelTooLong: return "label is too long"
        }
    }
}
