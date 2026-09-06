//  BackendFactory.swift — the single place in the app that names an engine.
//
//  Everything else builds against `TerminalBackend`. The day the core VT
//  changes, this file changes and nothing else does — which is the whole
//  point of the grid interface, and the reason the falsifier for it is a
//  grep: `import SwiftTermBackend` may appear in exactly one file of the app
//  target, and `import SwiftTerm` in none.

import AppKit
import SwiftTermBackend
import TerminalCore

enum BackendFactory {
    @MainActor
    static func make(columns: Int, rows: Int, scrollback: Int, font: NSFont,
                     useGPU: Bool) -> TerminalBackend {
        SwiftTermSession(columns: columns, rows: rows,
                         scrollback: scrollback, font: font, useGPU: useGPU)
    }

    /// Flips a live pane between the GPU renderer and the engine's own.
    /// Naming the backend is this file's job, and so is knowing which of them
    /// can do this (ISC-24).
    @MainActor
    static func setGPURenderer(_ enabled: Bool, on backend: TerminalBackend) {
        (backend as? SwiftTermSession)?.setGPURenderer(enabled)
    }
}
