//  Updates.swift — pure release decisions, isolated from network, processes and AppKit.
//
//  Version comparison, install-source detection and button actions live here so every branch can
//  be tested without touching the machine. The executor in T4A/Updater.swift is the only impure
//  edge, and it is entered only by an explicit button press (ISC-248).

import Foundation

public enum Updates {
    /// The GitHub repository that publishes T4A releases.
    public static let repo = "xmasyx/t4a"
    /// The cask token in the T4A Homebrew tap.
    public static let caskToken = "t4a"
    /// The Homebrew tap containing the T4A cask.
    public static let tap = "xmasyx/tap"

    /// How this copy of the app arrived on the Mac.
    public enum Source: Equatable, Sendable {
        case homebrew
        case manual
    }

    /// What the update button does when a newer version is available.
    public enum Action: Equatable, Sendable {
        /// Run Homebrew with these arguments, then relaunch the app.
        case upgradeAndRelaunch(arguments: [String])
        /// Open the release page so a manually installed copy can be replaced manually.
        case openReleasePage(URL)
    }

    /// Returns the normalized release version when `latestTag` is newer than `current`.
    ///
    /// Components are compared numerically, so 1.10.0 is newer than 1.9.0. Equal, older and
    /// unparseable versions return `nil`; an invalid tag is never guessed into a version.
    public static func newerVersion(current: String, latestTag: String) -> String? {
        func components(_ raw: String, acceptsPrefix: Bool) -> [Int]? {
            let version: Substring
            if acceptsPrefix, raw.first == "v" {
                version = raw.dropFirst()
            } else {
                version = raw[...]
            }
            guard !version.isEmpty else { return nil }
            let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
            guard !pieces.isEmpty else { return nil }
            let numbers = pieces.compactMap { piece -> Int? in
                guard !piece.isEmpty, piece.allSatisfy(\.isNumber) else { return nil }
                return Int(piece)
            }
            return numbers.count == pieces.count ? numbers : nil
        }

        guard let installed = components(current, acceptsPrefix: false),
              let released = components(latestTag, acceptsPrefix: true) else { return nil }
        let count = max(installed.count, released.count)
        for index in 0..<count {
            let old = index < installed.count ? installed[index] : 0
            let new = index < released.count ? released[index] : 0
            if new != old {
                return new > old ? released.map(String.init).joined(separator: ".") : nil
            }
        }
        return nil
    }

    /// Returns `.homebrew` only when the cask exists and this bundle is in an Applications folder.
    ///
    /// `fileExists` is injected so source detection remains a pure decision under test.
    public static func source(
        bundlePath: String,
        caskroomRoots: [String],
        homeDirectory: String,
        token: String = caskToken,
        fileExists: (_ path: String) -> Bool
    ) -> Source {
        let bundle = URL(fileURLWithPath: bundlePath).standardized.path
        let appName = URL(fileURLWithPath: bundle).lastPathComponent
        let systemApp = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(appName).standardized.path
        let userApp = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Applications")
            .appendingPathComponent(appName).standardized.path
        guard bundle == systemApp || bundle == userApp else { return .manual }

        let installed = caskroomRoots.contains { root in
            fileExists(URL(fileURLWithPath: root).appendingPathComponent(token).standardized.path)
        }
        return installed ? .homebrew : .manual
    }

    /// The arguments passed to Homebrew, excluding the executable itself.
    public static func upgradeArguments(token: String = caskToken, tap: String = tap) -> [String] {
        // Homebrew 6 removed its former quarantine option. The executor clears the attribute from
        // its own bundle after a successful installation instead (ISC-248).
        ["upgrade", "--cask", "\(tap)/\(token)"]
    }

    /// Selects the action for a newer version according to how this copy was installed.
    public static func action(for source: Source, version: String, repo: String = repo) -> Action {
        switch source {
        case .homebrew:
            return .upgradeAndRelaunch(arguments: upgradeArguments())
        case .manual:
            return .openReleasePage(
                URL(string: "https://github.com/\(repo)/releases/tag/v\(version)")!
            )
        }
    }

    /// Extracts `tag_name` from GitHub's latest-release JSON, or returns `nil` for invalid shapes.
    public static func latestTag(fromReleaseJSON data: Data) -> String? {
        struct Release: Decodable { let tagName: String }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Release.self, from: data).tagName
    }
}
