//  ShellIntegration.swift — how T4A gets OSC 133 into a shell it did not
//  install, without editing a single file the user owns.
//
//  Each shell already offers a door: zsh has ZDOTDIR, bash has $ENV in POSIX
//  mode (the only entry point a LOGIN bash reads that a terminal may set),
//  and fish has vendor_conf.d under XDG_DATA_DIRS. T4A knocks on those doors
//  and writes nothing under $HOME (ISC-16).

import Foundation

public enum ShellFamily: String, Sendable {
    case zsh, bash, fish, unknown

    public static func detect(executable: String) -> ShellFamily {
        switch (executable as NSString).lastPathComponent {
        case "zsh", "-zsh": return .zsh
        case "bash", "-bash", "sh": return .bash
        case "fish", "-fish": return .fish
        default: return .unknown
        }
    }
}

public struct ShellIntegration {
    /// Directory holding the shims — the app bundle's Resources/Integration.
    public let root: URL

    public init(root: URL) { self.root = root }

    /// Environment additions and argument rewrites that switch the shell's
    /// own loading path through our shim. Returns nil when the shell has no
    /// door we trust, in which case the terminal runs with no blocks and
    /// nothing else changes (graceful degradation is the whole contract).
    public struct Launch {
        public var arguments: [String]
        /// Nil keeps the login form `-name`.
        public var argv0: String?
    }

    public func prepare(executable: String,
                        arguments: [String],
                        environment: inout [String: String]) -> Launch {
        // TERM_PROGRAM and TERM_PROGRAM_VERSION are set by the session, for
        // every shell, integrated or not: they say which terminal this is, and
        // that is true whether or not the OSC 133 shims loaded.
        environment["T4A_INTEGRATION"] = "1"

        switch ShellFamily.detect(executable: executable) {
        case .zsh:
            let shim = root.appendingPathComponent("zsh")
            guard FileManager.default.fileExists(
                atPath: shim.appendingPathComponent(".zshenv").path)
            else { return Launch(arguments: arguments, argv0: nil) }
            // The user's own ZDOTDIR is handed back to every file we source,
            // so their configuration never sees ours.
            environment["T4A_USER_ZDOTDIR"] =
                ProcessInfo.processInfo.environment["ZDOTDIR"]
                ?? NSHomeDirectory()
            environment["ZDOTDIR"] = shim.path
            return Launch(arguments: arguments, argv0: nil)

        case .bash:
            let script = root.appendingPathComponent("bash/t4a-integration.bash")
            guard FileManager.default.fileExists(atPath: script.path)
            else { return Launch(arguments: arguments, argv0: nil) }
            // The door bash actually opens is `--rcfile`, and it only opens
            // for an interactive NON-login shell. Two measurements on
            // 2026-08-20 settled this: a login bash (argv[0] `-bash`) reads
            // the profile files and never looks at our shim, and the POSIX
            // route everyone recommends does not work on the bash macOS
            // ships — 3.2 with `--posix` and `$ENV` set sourced nothing.
            //
            // So bash starts as an ordinary interactive shell, `--rcfile`
            // brings the shim in, and the shim reads the login files itself,
            // in bash's own order, before installing anything.
            environment["T4A_BASH_LOGIN"] = "1"
            var rewritten = arguments.filter { $0 != "-l" && $0 != "--login" }
            rewritten.insert(contentsOf: ["--rcfile", script.path], at: 0)
            return Launch(arguments: rewritten,
                          argv0: (executable as NSString).lastPathComponent)

        case .fish:
            let dataDir = root.appendingPathComponent("fish")
            guard FileManager.default.fileExists(
                atPath: dataDir.appendingPathComponent("fish/vendor_conf.d/t4a-integration.fish").path)
            else { return Launch(arguments: arguments, argv0: nil) }
            let existing = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"]
                ?? "/usr/local/share:/usr/share"
            environment["XDG_DATA_DIRS"] = "\(dataDir.path):\(existing)"
            return Launch(arguments: arguments, argv0: nil)

        case .unknown:
            return Launch(arguments: arguments, argv0: nil)
        }
    }
}

public enum LoginShell {
    /// The user's login shell, as the directory service records it. Falls back
    /// to $SHELL and then to /bin/zsh, which is the macOS default.
    public static func path() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let value = String(cString: shell)
            if !value.isEmpty, FileManager.default.isExecutableFile(atPath: value) {
                return value
            }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }
}
