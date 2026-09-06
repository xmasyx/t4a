//  LanguageUI.swift — push a changed language through what is already open.
//
//  Text is state, unlike a colour read again from `draw`: labels and composed
//  prose have to be set again. The walk is therefore the sibling of the theme
//  walk rather than another reason to make a list of views. A hand-maintained
//  list starts complete and becomes wrong the first time a new surface is
//  added; conformance keeps the responsibility beside the text it refreshes.

import AppKit

@MainActor
protocol LanguageAware {
    func applyLanguage()
}

enum LanguageUI {
    /// Re-set cached text in every open controller and view.
    @MainActor static func reapplyEverywhere() {
        for window in NSApp.windows {
            (window.windowController as? LanguageAware)?.applyLanguage()
            guard let content = window.contentView else { continue }
            walk(content)
        }
    }

    @MainActor private static func walk(_ view: NSView) {
        (view as? LanguageAware)?.applyLanguage()
        view.subviews.forEach(walk)
    }
}
