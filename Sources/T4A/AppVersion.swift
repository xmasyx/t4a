//  AppVersion.swift — what T4A calls itself to the programs it hosts.
//
//  The number is read from the bundle rather than typed here, so it can only
//  ever be the version of the app that is actually running: a constant in the
//  source and a string in Info.plist drift apart the first time one of them is
//  bumped alone (ISC-110).

import Foundation

enum AppVersion {
    /// `CFBundleShortVersionString`, or an honest marker when T4A is running
    /// from a bare build with no bundle around it. A program asking
    /// TERM_PROGRAM_VERSION is asking which terminal features it may use, and
    /// a made-up number is worse than a visible "this is not a release".
    static let short: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0-dev"
    }()

    static let name = "T4A"
}
