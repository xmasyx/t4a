//  SplitTree.swift — panes inside one tab.
//
//  A split is not a second view of the same terminal: it is another child
//  process, another directory, another scrollback, exactly like a tab
//  (ISC-68). The tree is rebuilt into NSSplitViews on every change, which is
//  cheap because splitting is a thing people do a few times an hour, and it
//  keeps one description of the layout instead of two.

import AppKit

@MainActor
final class SplitTree {
    indirect enum Node {
        case leaf(PaneView)
        /// `vertical` means the divider is vertical, so panes sit side by side.
        case split(vertical: Bool, [Node])
    }

    private(set) var root: Node

    init(root: PaneView) { self.root = .leaf(root) }

    var panes: [PaneView] { Self.panes(in: root) }

    private static func panes(in node: Node) -> [PaneView] {
        switch node {
        case .leaf(let pane): return [pane]
        case .split(_, let children): return children.flatMap { panes(in: $0) }
        }
    }

    /// Puts `newPane` beside `target`. When the target already sits in a split
    /// running the same way, the pane joins that split instead of nesting a
    /// new one — otherwise three side-by-side panes would need two dividers
    /// doing the same job.
    func insert(_ newPane: PaneView, beside target: PaneView, vertical: Bool) {
        root = Self.insert(newPane, beside: target, vertical: vertical, into: root).node
    }

    private static func insert(_ newPane: PaneView, beside target: PaneView,
                               vertical: Bool, into node: Node) -> (node: Node, done: Bool) {
        switch node {
        case .leaf(let pane):
            guard pane === target else { return (node, false) }
            return (.split(vertical: vertical, [.leaf(pane), .leaf(newPane)]), true)
        case .split(let isVertical, var children):
            for index in children.indices {
                if case .leaf(let pane) = children[index], pane === target {
                    if isVertical == vertical {
                        children.insert(.leaf(newPane), at: index + 1)
                    } else {
                        children[index] = .split(vertical: vertical,
                                                 [.leaf(pane), .leaf(newPane)])
                    }
                    return (.split(vertical: isVertical, children), true)
                }
                let result = insert(newPane, beside: target, vertical: vertical,
                                    into: children[index])
                if result.done {
                    children[index] = result.node
                    return (.split(vertical: isVertical, children), true)
                }
            }
            return (node, false)
        }
    }

    /// Removes a pane and collapses any split left with a single child.
    /// Returns false when the pane was the last one in the tab.
    @discardableResult
    func remove(_ pane: PaneView) -> Bool {
        guard panes.count > 1 else { return false }
        if let pruned = Self.remove(pane, from: root) { root = pruned }
        return true
    }

    private static func remove(_ pane: PaneView, from node: Node) -> Node? {
        switch node {
        case .leaf(let existing):
            return existing === pane ? nil : node
        case .split(let vertical, let children):
            let pruned = children.compactMap { remove(pane, from: $0) }
            if pruned.isEmpty { return nil }
            if pruned.count == 1 { return pruned[0] }
            return .split(vertical: vertical, pruned)
        }
    }

    /// Builds the AppKit view for the tree. Pane views are reused, never
    /// recreated: they own live child processes.
    func makeView() -> NSView { Self.makeView(root) }

    private static func makeView(_ node: Node) -> NSView {
        switch node {
        case .leaf(let pane):
            pane.removeFromSuperview()
            return pane
        case .split(let vertical, let children):
            let splitView = DividerSplitView()
            splitView.isVertical = vertical
            splitView.dividerStyle = .thin
            splitView.translatesAutoresizingMaskIntoConstraints = false
            for child in children {
                let view = makeView(child)
                // NSSplitView lays its children out by frame. A child left in
                // autolayout mode gets no frame from it at all: measured on
                // 2026-08-20, a two-way split reported 116 columns and 2.
                view.translatesAutoresizingMaskIntoConstraints = true
                splitView.addSubview(view)
            }
            return splitView
        }
    }
}

/// A split view whose divider is a hairline in the app's own palette (the
/// system divider brings another app's colours into the page, MacAppRules §7)
/// and whose panes start out the same size.
final class DividerSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.current.hairline }
    override var dividerThickness: CGFloat { 1 }

    private var hasDistributed = false

    override func layout() {
        super.layout()
        guard !hasDistributed, subviews.count > 1 else { return }
        let span = isVertical ? bounds.width : bounds.height
        guard span > 1 else { return }
        hasDistributed = true
        distributeEvenly(span: span)
    }

    /// A new split opens with its panes equal. Anything the user drags after
    /// that is theirs to keep, which is why this runs once.
    private func distributeEvenly(span: CGFloat) {
        let count = CGFloat(subviews.count)
        let dividers = (count - 1) * dividerThickness
        let each = (span - dividers) / count
        for index in 0..<(subviews.count - 1) {
            let position = (each + dividerThickness) * CGFloat(index + 1) - dividerThickness
            setPosition(position, ofDividerAt: index)
        }
    }
}
