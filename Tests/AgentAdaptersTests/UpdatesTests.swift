//  UpdatesTests.swift — the pure contract for release decisions and Homebrew routing.
//
//  Both poles of every decision are fixtures: source detection never touches the filesystem,
//  and malformed release data can never become an invented version (ISC-248).

import Foundation
import Testing
@testable import TerminalCore

@Suite("Updates: versions")
struct UpdatesVersionTests {
    @Test func prefixedNewerTag() {
        #expect(Updates.newerVersion(current: "1.2.0", latestTag: "v1.3.0") == "1.3.0")
    }

    @Test func unprefixedNewerTag() {
        #expect(Updates.newerVersion(current: "1.2.0", latestTag: "1.2.1") == "1.2.1")
    }

    @Test func equalTagIsNotNewer() {
        #expect(Updates.newerVersion(current: "1.2.0", latestTag: "v1.2.0") == nil)
    }

    @Test func olderTagIsNotNewer() {
        #expect(Updates.newerVersion(current: "1.3.0", latestTag: "v1.2.9") == nil)
    }

    @Test func componentsCompareNumerically() {
        #expect(Updates.newerVersion(current: "1.9.0", latestTag: "v1.10.0") == "1.10.0")
        #expect(Updates.newerVersion(current: "1.10.0", latestTag: "v1.9.0") == nil)
    }

    @Test func missingComponentsAreZero() {
        #expect(Updates.newerVersion(current: "1.2", latestTag: "v1.2.1") == "1.2.1")
        #expect(Updates.newerVersion(current: "1.2.0", latestTag: "v1.2") == nil)
    }

    @Test func unparseableTextIsNotAVersion() {
        #expect(Updates.newerVersion(current: "1.2.0", latestTag: "garbage") == nil)
        #expect(Updates.newerVersion(current: "dev", latestTag: "v1.3.0") == nil)
        #expect(Updates.newerVersion(current: "1.2.0", latestTag: "") == nil)
    }
}

@Suite("Updates: source")
struct UpdatesSourceTests {
    let roots = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
    let home = "/Users/example"

    private func exists(_ present: Set<String>) -> (String) -> Bool {
        { present.contains($0) }
    }

    @Test func caskroomAndSystemApplicationsAreHomebrew() {
        let source = Updates.source(
            bundlePath: "/Applications/T4A.app",
            caskroomRoots: roots,
            homeDirectory: home,
            fileExists: exists(["/opt/homebrew/Caskroom/t4a"])
        )
        #expect(source == .homebrew)
    }

    @Test func intelCaskroomIsRecognized() {
        let source = Updates.source(
            bundlePath: "/Applications/T4A.app",
            caskroomRoots: roots,
            homeDirectory: home,
            fileExists: exists(["/usr/local/Caskroom/t4a"])
        )
        #expect(source == .homebrew)
    }

    @Test func userApplicationsIsRecognized() {
        let source = Updates.source(
            bundlePath: "/Users/example/Applications/T4A.app",
            caskroomRoots: roots,
            homeDirectory: home,
            fileExists: exists(["/opt/homebrew/Caskroom/t4a"])
        )
        #expect(source == .homebrew)
    }

    @Test func missingCaskroomIsManual() {
        let source = Updates.source(
            bundlePath: "/Applications/T4A.app",
            caskroomRoots: roots,
            homeDirectory: home,
            fileExists: exists([])
        )
        #expect(source == .manual)
    }

    @Test func anotherCaskDoesNotCount() {
        let source = Updates.source(
            bundlePath: "/Applications/T4A.app",
            caskroomRoots: roots,
            homeDirectory: home,
            fileExists: exists(["/opt/homebrew/Caskroom/nosleep"])
        )
        #expect(source == .manual)
    }

    @Test func bundleOutsideApplicationsIsManualEvenWithCaskroom() {
        let source = Updates.source(
            bundlePath: "/Users/example/Desktop/T4A.app",
            caskroomRoots: roots,
            homeDirectory: home,
            fileExists: exists(["/opt/homebrew/Caskroom/t4a"])
        )
        #expect(source == .manual)
    }
}

@Suite("Updates: actions")
struct UpdatesActionTests {
    @Test func exactHomebrewArguments() {
        #expect(Updates.upgradeArguments() == ["upgrade", "--cask", "xmasyx/tap/t4a"])
    }

    @Test func homebrewSourceUpgradesAndRelaunches() {
        #expect(
            Updates.action(for: .homebrew, version: "1.3.0")
                == .upgradeAndRelaunch(arguments: ["upgrade", "--cask", "xmasyx/tap/t4a"])
        )
    }

    @Test func manualSourceOpensReleasePage() {
        let url = URL(string: "https://github.com/xmasyx/t4a/releases/tag/v1.3.0")!
        #expect(Updates.action(for: .manual, version: "1.3.0") == .openReleasePage(url))
    }
}

@Suite("Updates: GitHub JSON")
struct UpdatesJSONTests {
    @Test func extractsTagFromReleaseJSON() {
        let data = Data(#"{"tag_name":"v1.3.0","name":"T4A 1.3.0","draft":false}"#.utf8)
        #expect(Updates.latestTag(fromReleaseJSON: data) == "v1.3.0")
    }

    @Test func missingTagReturnsNil() {
        #expect(Updates.latestTag(fromReleaseJSON: Data("{}".utf8)) == nil)
    }

    @Test func garbageReturnsNil() {
        #expect(Updates.latestTag(fromReleaseJSON: Data("<html>not JSON</html>".utf8)) == nil)
    }
}
