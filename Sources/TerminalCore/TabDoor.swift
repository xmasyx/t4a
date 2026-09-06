//  TabDoor.swift — requests from local programs to open and close panes.
//
//  The protocol is deliberately only parsing here. The core knows neither
//  about the filesystem watcher nor about windows, which leaves every rule
//  that rejects a request testable without launching the app.

import Foundation

public struct TabRequest: Equatable, Sendable {
    public let name: String
    public let cwd: String
    public let command: String
    public let label: String?

    public init(name: String, cwd: String, command: String, label: String?) {
        self.name = name
        self.cwd = cwd
        self.command = command
        self.label = label
    }
}

public enum TabDoorError: Error, Equatable, Sendable {
    case badName
    case notJSON
    case missing(String)
    case noSuchDirectory
    case emptyCommand
    case multilineCommand
    case commandTooLong
    case labelTooLong
}

public enum TabDoor {
    public enum Kind: Equatable, Sendable { case open, close }
    public enum Reply: Equatable, Sendable { case opened, rejected, closed }

    public static let commandByteCap = 4096
    public static let labelCap = 80

    /// The door can be redirected for a bench without leaving requests in
    /// the real channel. An empty override means the ordinary per-user path.
    public static func directory(environment: [String: String], home: String) -> URL {
        if let named = environment["T4A_DOOR"], !named.isEmpty {
            return URL(fileURLWithPath: named)
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".cache/t4a/door")
    }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 46 || byte == 95 || byte == 45
        }
    }

    public static func kind(ofFile fileName: String) -> (name: String, kind: Kind)? {
        let endings: [(String, Kind)] = [(".open.json", .open), (".close.json", .close)]
        for (ending, kind) in endings where fileName.hasSuffix(ending) {
            let name = String(fileName.dropLast(ending.count))
            guard isValidName(name) else { return nil }
            return (name, kind)
        }
        return nil
    }

    public static func parseOpen(
        name: String,
        data: Data,
        isDirectory: (String) -> Bool
    ) -> Result<TabRequest, TabDoorError> {
        guard isValidName(name) else { return .failure(.badName) }
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            return .failure(.notJSON)
        }
        guard let cwd = object["cwd"] as? String else { return .failure(.missing("cwd")) }
        guard cwd.hasPrefix("/"), isDirectory(cwd) else {
            return .failure(.noSuchDirectory)
        }
        guard let rawCommand = object["command"] as? String else {
            return .failure(.missing("command"))
        }
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .failure(.emptyCommand) }
        guard command.rangeOfCharacter(from: .newlines) == nil else {
            return .failure(.multilineCommand)
        }
        guard command.utf8.count <= commandByteCap else { return .failure(.commandTooLong) }

        let label = (object["label"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.map(\.count) ?? 0 <= labelCap else { return .failure(.labelTooLong) }
        return .success(TabRequest(name: name, cwd: cwd, command: command,
                                   label: label?.isEmpty == true ? nil : label))
    }

    public static func parseClose(data: Data) -> UUID? {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any],
              let session = object["session"] as? String else { return nil }
        return UUID(uuidString: session)
    }

    public static func replyFileName(for name: String, reply: Reply) -> String {
        let ending: String
        switch reply {
        case .opened: ending = "opened"
        case .rejected: ending = "rejected"
        case .closed: ending = "closed"
        }
        return "\(name).\(ending).json"
    }
}
