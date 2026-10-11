//
//  SplitTree.swift
//  SideCli
//
//  A tab's pane layout: a binary tree whose leaves are terminal sessions,
//  plus the pure geometry used to lay it out inside the narrow side panel.
//

import AppKit

/// How the two children of a split are arranged.
enum SplitAxis: String, Codable {
    /// Side by side (left | right); the divider is vertical.
    case horizontal
    /// Stacked (top / bottom); the divider is horizontal.
    case vertical

    var opposite: SplitAxis { self == .horizontal ? .vertical : .horizontal }
}

indirect enum SplitTree {
    case leaf(TerminalSession)
    case branch(id: UUID, axis: SplitAxis, ratio: CGFloat, first: SplitTree, second: SplitTree)

    /// Sessions in reading order (left→right, top→bottom).
    var leaves: [TerminalSession] {
        switch self {
        case .leaf(let session): return [session]
        case .branch(_, _, _, let first, let second): return first.leaves + second.leaves
        }
    }

    var isBranch: Bool {
        if case .branch = self { return true }
        return false
    }

    /// True if any split puts panes side by side (needs a wider panel).
    var hasHorizontalSplit: Bool {
        guard case let .branch(_, axis, _, first, second) = self else { return false }
        return axis == .horizontal || first.hasHorizontalSplit || second.hasHorizontalSplit
    }

    func contains(_ sessionID: UUID) -> Bool {
        leaves.contains { $0.id == sessionID }
    }

    func replacingLeaf(_ sessionID: UUID, with replacement: SplitTree) -> SplitTree {
        switch self {
        case .leaf(let session):
            return session.id == sessionID ? replacement : self
        case let .branch(id, axis, ratio, first, second):
            return .branch(id: id, axis: axis, ratio: ratio,
                           first: first.replacingLeaf(sessionID, with: replacement),
                           second: second.replacingLeaf(sessionID, with: replacement))
        }
    }

    /// Removes a leaf; its sibling takes the parent's place.
    /// `tree` is nil when the whole tree was that single leaf.
    func removingLeaf(_ sessionID: UUID) -> (tree: SplitTree?, sibling: SplitTree?) {
        switch self {
        case .leaf(let session):
            return session.id == sessionID ? (nil, nil) : (self, nil)
        case let .branch(id, axis, ratio, first, second):
            if case .leaf(let s) = first, s.id == sessionID { return (second, second) }
            if case .leaf(let s) = second, s.id == sessionID { return (first, first) }
            let a = first.removingLeaf(sessionID), b = second.removingLeaf(sessionID)
            return (.branch(id: id, axis: axis, ratio: ratio, first: a.tree ?? first, second: b.tree ?? second),
                    a.sibling ?? b.sibling)
        }
    }

    func settingRatio(_ newRatio: CGFloat, for branchID: UUID) -> SplitTree {
        guard case let .branch(id, axis, ratio, first, second) = self else { return self }
        if id == branchID {
            return .branch(id: id, axis: axis, ratio: newRatio, first: first, second: second)
        }
        return .branch(id: id, axis: axis, ratio: ratio,
                       first: first.settingRatio(newRatio, for: branchID),
                       second: second.settingRatio(newRatio, for: branchID))
    }

    /// Puts every divider in the middle of what it splits (same rule as Ghostty).
    /// A run of splits in the same direction counts as one row of equal panes, so
    /// three stacked panes get 1/3 each; a sub-split in the other direction counts
    /// as a single pane. E.g. "(TL / (a | b)) | (TR / c)": TL and TR are equally
    /// wide, a and b get a quarter each, c gets half.
    func equalized() -> SplitTree {
        guard case let .branch(id, axis, _, first, second) = self else { return self }
        let a = CGFloat(first.weight(along: axis)), b = CGFloat(second.weight(along: axis))
        return .branch(id: id, axis: axis, ratio: a / (a + b),
                       first: first.equalized(), second: second.equalized())
    }

    /// Number of equal slots this subtree takes along `axis`.
    func weight(along axis: SplitAxis) -> Int {
        guard case let .branch(_, branchAxis, _, first, second) = self, branchAxis == axis else { return 1 }
        return first.weight(along: axis) + second.weight(along: axis)
    }
}

// MARK: - Pane metrics

/// Cell size for the current font and the minimum usable pane.
/// A pane narrower than ~40 columns makes TUIs like Claude Code / vim wrap badly,
/// so splits that would go below this are refused (or the pane is auto-zoomed).
struct PaneMetrics: Equatable {
    static let minColumns = 40
    static let minRows = 8
    // Terminal insets inside a pane (trailing leaves room for the scrollbar).
    static let insetLeading: CGFloat = 8
    static let insetTrailing: CGFloat = 14
    static let insetTop: CGFloat = 4
    static let insetBottom: CGFloat = 4
    static let dividerThickness: CGFloat = 6

    let cellWidth: CGFloat
    let cellHeight: CGFloat

    init(fontSize: Int) {
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        cellWidth = ("W" as NSString).size(withAttributes: [.font: font]).width
        cellHeight = ceil(font.ascender - font.descender + font.leading)
    }

    var minPaneSize: CGSize {
        CGSize(width: ceil(CGFloat(Self.minColumns) * cellWidth) + Self.insetLeading + Self.insetTrailing,
               height: ceil(CGFloat(Self.minRows) * cellHeight) + Self.insetTop + Self.insetBottom)
    }

    func grid(for size: CGSize) -> (cols: Int, rows: Int) {
        let w = size.width - Self.insetLeading - Self.insetTrailing
        let h = size.height - Self.insetTop - Self.insetBottom
        return (max(0, Int(w / cellWidth)), max(0, Int(h / cellHeight)))
    }
}

// MARK: - Layout

/// Frames for one tab's panes and dividers, in a flipped (top-left origin) space.
struct SplitLayout {
    struct Divider {
        let branchID: UUID
        let axis: SplitAxis
        let frame: CGRect
        /// The rect the branch occupies; the divider moves within it.
        let container: CGRect
        let firstMin: CGSize
        let secondMin: CGSize
    }

    var paneFrames: [UUID: CGRect] = [:]
    var dividers: [Divider] = []

    static func minSize(of tree: SplitTree, metrics: PaneMetrics) -> CGSize {
        switch tree {
        case .leaf:
            return metrics.minPaneSize
        case let .branch(_, axis, _, first, second):
            let a = minSize(of: first, metrics: metrics), b = minSize(of: second, metrics: metrics)
            let d = PaneMetrics.dividerThickness
            return axis == .horizontal
                ? CGSize(width: a.width + b.width + d, height: max(a.height, b.height))
                : CGSize(width: max(a.width, b.width), height: a.height + b.height + d)
        }
    }

    static func compute(_ tree: SplitTree, in rect: CGRect, metrics: PaneMetrics) -> SplitLayout {
        var layout = SplitLayout()
        place(tree, in: rect, metrics: metrics, into: &layout)
        return layout
    }

    private static func place(_ tree: SplitTree, in rect: CGRect, metrics: PaneMetrics, into layout: inout SplitLayout) {
        switch tree {
        case .leaf(let session):
            layout.paneFrames[session.id] = rect
        case let .branch(id, axis, ratio, first, second):
            let firstMin = minSize(of: first, metrics: metrics)
            let secondMin = minSize(of: second, metrics: metrics)
            let d = PaneMetrics.dividerThickness
            let total = (axis == .horizontal ? rect.width : rect.height) - d
            let lo = axis == .horizontal ? firstMin.width : firstMin.height
            let hi = total - (axis == .horizontal ? secondMin.width : secondMin.height)
            var a = (total * ratio).rounded()
            // Keep both sides at their minimum whenever the whole thing fits; the stored
            // ratio stays untouched so the layout comes back when the panel grows again.
            if lo <= hi { a = min(max(a, lo), hi) }
            a = min(max(a, 0), max(total, 0))

            let firstRect, dividerRect, secondRect: CGRect
            if axis == .horizontal {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: a, height: rect.height)
                dividerRect = CGRect(x: rect.minX + a, y: rect.minY, width: d, height: rect.height)
                secondRect = CGRect(x: rect.minX + a + d, y: rect.minY, width: max(0, total - a), height: rect.height)
            } else {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: a)
                dividerRect = CGRect(x: rect.minX, y: rect.minY + a, width: rect.width, height: d)
                secondRect = CGRect(x: rect.minX, y: rect.minY + a + d, width: rect.width, height: max(0, total - a))
            }
            place(first, in: firstRect, metrics: metrics, into: &layout)
            layout.dividers.append(Divider(branchID: id, axis: axis, frame: dividerRect, container: rect,
                                           firstMin: firstMin, secondMin: secondMin))
            place(second, in: secondRect, metrics: metrics, into: &layout)
        }
    }

    /// Ratio for a divider dragged so its centre sits at `position` (x for a
    /// horizontal split, y for a vertical one), keeping both sides' minimums.
    static func ratio(for divider: Divider, at position: CGFloat) -> CGFloat {
        let d = PaneMetrics.dividerThickness
        let horizontal = divider.axis == .horizontal
        let origin = horizontal ? divider.container.minX : divider.container.minY
        let total = (horizontal ? divider.container.width : divider.container.height) - d
        guard total > 0 else { return 0.5 }
        let lo = horizontal ? divider.firstMin.width : divider.firstMin.height
        let hi = total - (horizontal ? divider.secondMin.width : divider.secondMin.height)
        var a = position - origin - d / 2
        a = lo <= hi ? min(max(a, lo), hi) : min(max(a, total * 0.1), total * 0.9)
        return a / total
    }
}
