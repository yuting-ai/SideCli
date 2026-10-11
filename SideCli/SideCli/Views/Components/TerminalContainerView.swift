//
//  TerminalContainerView.swift
//  SideCli
//
//  The terminal area: every tab's split tree, laid out by an AppKit view.
//
//  SplitWorkspaceNSView keeps one TerminalPaneView per session (all tabs) in a
//  registry keyed by session id. Changing the tree only changes frames and
//  visibility, so SwiftTerm views — and their scrollback — survive splits,
//  closes and tab switches. SwiftUI only talks to it through WorkspaceHandle.
//

import SwiftUI
import Combine
import AppKit

enum SplitMode {
    /// Split along whichever axis has more room relative to the minimum pane size (⌘D).
    case auto
    /// The other axis from `auto` (⌘⇧D).
    case opposite
    case axis(SplitAxis)
}

enum FocusDirection {
    case left, right, up, down
}

// MARK: - Handle (SwiftUI → workspace)

/// Lets the toolbar, shortcuts and tab bar drive the workspace, which owns the
/// geometry needed to decide split direction and whether a split fits.
final class WorkspaceHandle: ObservableObject {
    struct Toast: Equatable {
        let id = UUID()
        let message: String
        let isWarning: Bool
    }

    /// Set while the active tab's layout doesn't fit and its focused pane is shown alone.
    struct Overflow: Equatable {
        let needed: CGSize
        let available: CGSize
    }

    @Published private(set) var toast: Toast?
    @Published fileprivate(set) var overflow: Overflow?
    fileprivate weak var workspace: SplitWorkspaceNSView?

    func split(_ mode: SplitMode) { workspace?.split(mode) }
    func toggleZoom() { workspace?.toggleZoom() }
    func equalize() { workspace?.equalize() }
    func moveFocus(_ direction: FocusDirection) { workspace?.moveFocus(direction) }
    func closeFocusedPane() { workspace?.closeFocusedPane() }

    func show(_ message: String, warning: Bool = false) {
        let toast = Toast(message: message, isWarning: warning)
        self.toast = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + (warning ? 4.5 : 2.4)) { [weak self] in
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    fileprivate func setOverflow(_ value: Overflow?) {
        if overflow != value { overflow = value }
    }
}

// MARK: - SwiftUI bridge

struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var manager: TerminalManager
    let workspace: WorkspaceHandle
    let panelController: PanelController
    let isDark: Bool
    let fontSize: Int

    func makeNSView(context: Context) -> SplitWorkspaceNSView {
        SplitWorkspaceNSView(manager: manager, panelController: panelController,
                             handle: workspace, isDark: isDark, fontSize: fontSize)
    }

    func updateNSView(_ view: SplitWorkspaceNSView, context: Context) {
        view.update(isDark: isDark, fontSize: fontSize)
        view.sync()
    }

    static func dismantleNSView(_ view: SplitWorkspaceNSView, coordinator: ()) {
        view.teardown()
    }
}

// MARK: - Workspace view

final class SplitWorkspaceNSView: NSView {
    private let manager: TerminalManager
    private weak var panelController: PanelController?
    private weak var handle: WorkspaceHandle?
    private var isDark: Bool
    private var fontSize: Int
    private var metrics: PaneMetrics

    private var panes: [UUID: TerminalPaneView] = [:]
    private var dividerViews: [SplitDividerView] = []
    /// Active tab's frames as currently shown (a single frame while zoomed).
    private var activeLayout = SplitLayout()
    /// Pane last made first responder, so layout passes don't keep stealing focus
    /// (e.g. from the tab-rename text field).
    private var focusTarget: UUID?
    private var mouseMonitor: Any?

    init(manager: TerminalManager, panelController: PanelController, handle: WorkspaceHandle,
         isDark: Bool, fontSize: Int) {
        self.manager = manager
        self.panelController = panelController
        self.handle = handle
        self.isDark = isDark
        self.fontSize = fontSize
        self.metrics = PaneMetrics(fontSize: fontSize)
        super.init(frame: .zero)
        handle.workspace = self
        wantsLayer = true
        layer?.backgroundColor = TerminalPaneView.backgroundColor(isDark: isDark).cgColor
        // SwiftTerm's mouseDown / becomeFirstResponder aren't overridable from outside
        // the module, so watch clicks to keep the model's focused pane in sync.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.focusPane(under: event)
            return event
        }
        sync()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    func teardown() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        panes.values.forEach { $0.teardown() }
    }

    override var isFlipped: Bool { true }

    /// Every tab (hidden ones included) is re-laid out on a size change, so a tab
    /// you switch to already has the panel's current size.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTarget = nil
        needsLayout = true
    }

    private func t(_ en: String, _ zh: String) -> String {
        AppPreferences.language() == .chinese ? zh : en
    }

    // MARK: Model → views

    func update(isDark: Bool, fontSize: Int) {
        guard isDark != self.isDark || fontSize != self.fontSize else { return }
        self.isDark = isDark
        self.fontSize = fontSize
        metrics = PaneMetrics(fontSize: fontSize)
        layer?.backgroundColor = TerminalPaneView.backgroundColor(isDark: isDark).cgColor
        panes.values.forEach { $0.update(isDark: isDark, fontSize: fontSize) }
        needsLayout = true
    }

    /// Creates views for new sessions, drops views of closed ones, and schedules layout.
    func sync() {
        let live = Set(manager.tabs.flatMap { $0.sessions.map(\.id) })
        for (id, pane) in panes where !live.contains(id) {
            pane.teardown()
            pane.removeFromSuperview()
            panes[id] = nil
        }
        for tab in manager.tabs {
            for session in tab.sessions where panes[session.id] == nil {
                let pane = TerminalPaneView(session: session, isDark: isDark, fontSize: fontSize,
                                            actions: actions(for: session.id))
                panes[session.id] = pane
                // Below the dividers, which must stay on top to receive drags.
                addSubview(pane, positioned: .below, relativeTo: dividerViews.first)
            }
        }
        needsLayout = true
        syncPanelWidth()
    }

    private func tab(containing sessionID: UUID) -> TerminalTab? {
        manager.tabs.first { $0.root.contains(sessionID) }
    }

    private func actions(for sessionID: UUID) -> PaneActions {
        PaneActions(
            splitVertical: { [weak self] in self?.split(.axis(.vertical), at: sessionID) },
            splitHorizontal: { [weak self] in self?.split(.axis(.horizontal), at: sessionID) },
            toggleZoom: { [weak self] in
                guard let self, let tab = self.tab(containing: sessionID) else { return }
                tab.focus(sessionID)
                self.manager.toggleZoom(in: tab)
            },
            close: { [weak self] in
                guard let self, let tab = self.tab(containing: sessionID) else { return }
                self.manager.closePane(sessionID, in: tab)
            }
        )
    }

    /// The panel size is shared by all tabs. Report whether any tab still has a
    /// left/right split, so an automatic widening can be undone once none does.
    private func syncPanelWidth() {
        let anyHorizontal = manager.tabs.contains { $0.root.hasHorizontalSplit }
        DispatchQueue.main.async { [weak panelController] in
            panelController?.layoutsChanged(anyTabHasHorizontalSplit: anyHorizontal)
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let rect = bounds
        guard rect.width > 1, rect.height > 1 else { return }

        var overflow: WorkspaceHandle.Overflow?
        for tab in manager.tabs {
            let isActive = tab.id == manager.activeTabId
            let normal = SplitLayout.compute(tab.root, in: rect, metrics: metrics)
            var zoomID = tab.zoomedSessionID
            if tab.isSplit, zoomID == nil {
                let need = SplitLayout.minSize(of: tab.root, metrics: metrics)
                if need.width > rect.width + 0.5 || need.height > rect.height + 0.5 {
                    // Doesn't fit: show just the focused pane until the panel is big enough again.
                    zoomID = tab.focusedSessionID
                    if isActive { overflow = .init(needed: need, available: rect.size) }
                }
            }
            let showsSeveral = isActive && tab.isSplit && zoomID == nil

            // Inactive tabs are laid out too (hidden), so their shells start and
            // keep the right size for when the tab is shown.
            for session in tab.sessions {
                guard let pane = panes[session.id] else { continue }
                let frame = zoomID == session.id ? rect : (normal.paneFrames[session.id] ?? rect)
                if pane.frame != frame { pane.frame = frame }
                let visible = isActive && (zoomID == nil || zoomID == session.id)
                if pane.isHidden == visible { pane.isHidden = !visible }
                if isActive {
                    let focused = session.id == tab.focusedSessionID
                    pane.setChrome(focused: showsSeveral && focused, dimmed: showsSeveral && !focused,
                                   multiPane: tab.isSplit, zoomed: zoomID != nil)
                }
            }
            if isActive {
                activeLayout = zoomID.map { SplitLayout(paneFrames: [$0: rect], dividers: []) } ?? normal
            }
        }
        layoutDividers()
        DispatchQueue.main.async { [weak handle] in handle?.setOverflow(overflow) }
        updateFirstResponder()
    }

    private func layoutDividers() {
        let infos = activeLayout.dividers
        while dividerViews.count < infos.count {
            let divider = SplitDividerView()
            divider.onDrag = { [weak self] info, point in self?.drag(info, to: point) }
            divider.onDragEnd = { [weak self] in
                // Let TUIs repaint at their final size, as after a window live resize.
                NotificationCenter.default.post(name: .terminalLiveResizeDidEnd, object: nil)
                // Ratio changes during a drag don't publish, so ask for a save here.
                self?.manager.scheduleSave()
            }
            addSubview(divider)
            dividerViews.append(divider)
        }
        while dividerViews.count > infos.count {
            dividerViews.removeLast().removeFromSuperview()
        }
        for (view, info) in zip(dividerViews, infos) {
            view.divider = info
            if view.frame != info.frame { view.frame = info.frame }
        }
    }

    private func drag(_ divider: SplitLayout.Divider, to point: NSPoint) {
        guard let tab = manager.activeTab else { return }
        let position = divider.axis == .horizontal ? point.x : point.y
        tab.setRatio(SplitLayout.ratio(for: divider, at: position), forBranch: divider.branchID)
        needsLayout = true
        layoutSubtreeIfNeeded()   // the divider runs a modal tracking loop; lay out now
    }

    // MARK: Focus

    private func updateFirstResponder() {
        guard let tab = manager.activeTab, tab.focusedSessionID != focusTarget else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.attachedSheet == nil,
                  let tab = self.manager.activeTab,
                  let pane = self.panes[tab.focusedSessionID], !pane.isHidden else { return }
            if window.makeFirstResponder(pane.terminalView) {
                self.focusTarget = tab.focusedSessionID
            }
        }
    }

    private func focusPane(under event: NSEvent) {
        guard let window, event.window === window, let tab = manager.activeTab else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        for session in tab.sessions {
            guard let pane = panes[session.id], !pane.isHidden, pane.frame.contains(point) else { continue }
            if tab.focusedSessionID != session.id {
                focusTarget = session.id   // the click itself makes it first responder
                tab.focus(session.id)
            }
            return
        }
    }

    func moveFocus(_ direction: FocusDirection) {
        guard let tab = manager.activeTab, tab.zoomedSessionID == nil else { return }
        let frames = activeLayout.paneFrames
        guard let current = frames[tab.focusedSessionID] else { return }
        var best: (id: UUID, distance: CGFloat)?
        for (id, frame) in frames where id != tab.focusedSessionID {
            let overlapsRows = frame.minY < current.maxY && frame.maxY > current.minY
            let overlapsCols = frame.minX < current.maxX && frame.maxX > current.minX
            let inDirection: Bool
            switch direction {   // flipped coordinates: up = smaller y
            case .left:  inDirection = frame.maxX <= current.minX + 1 && overlapsRows
            case .right: inDirection = frame.minX >= current.maxX - 1 && overlapsRows
            case .up:    inDirection = frame.maxY <= current.minY + 1 && overlapsCols
            case .down:  inDirection = frame.minY >= current.maxY - 1 && overlapsCols
            }
            guard inDirection else { continue }
            let distance = hypot(frame.midX - current.midX, frame.midY - current.midY)
            if best == nil || distance < best!.distance { best = (id, distance) }
        }
        if let best { tab.focus(best.id) }
    }

    // MARK: Commands

    func split(_ mode: SplitMode, at sessionID: UUID? = nil) {
        guard let tab = manager.activeTab else { return }
        let targetID = sessionID ?? tab.focusedSessionID
        guard let target = tab.sessions.first(where: { $0.id == targetID }) else { return }
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }

        let frame = SplitLayout.compute(tab.root, in: bounds, metrics: metrics).paneFrames[targetID] ?? bounds
        let grid = metrics.grid(for: frame.size)
        let roomAcross = Double(grid.cols) / Double(PaneMetrics.minColumns)
        let roomDown = Double(grid.rows) / Double(PaneMetrics.minRows)
        let autoAxis: SplitAxis = roomAcross >= roomDown ? .horizontal : .vertical
        let axis: SplitAxis
        switch mode {
        case .auto: axis = autoAxis
        case .opposite: axis = autoAxis.opposite
        case .axis(let fixed): axis = fixed
        }

        // Same structure as the real result; only the size requirements matter here.
        let candidate = tab.root.replacingLeaf(
            targetID,
            with: .branch(id: UUID(), axis: axis, ratio: 0.5, first: .leaf(target), second: .leaf(target))
        )
        let need = SplitLayout.minSize(of: candidate, metrics: metrics)
        let widthLimit = candidate.hasHorizontalSplit
            ? max(panelController?.autoWidenLimit ?? size.width, size.width)
            : size.width
        let name = axis == .horizontal ? t("left / right", "左右") : t("top / bottom", "上下")

        if need.width > widthLimit + 0.5 {
            let needed = Int(need.width.rounded(.up)), limit = Int(widthLimit)
            let hint = axis == .horizontal ? t(" Try splitting top / bottom instead.", "可以改用上下分屏。") : ""
            handle?.show(t("Not enough room to split \(name): needs at least \(needed) pt wide, and the panel can only be \(limit) pt.\(hint)",
                           "放不下\(name)分屏：至少需要 \(needed)pt 宽，面板最多只能有 \(limit)pt。\(hint)"),
                         warning: true)
            return
        }
        if need.height > size.height + 0.5 {
            let needed = Int(need.height.rounded(.up)), have = Int(size.height)
            handle?.show(t("Not enough room to split \(name): needs at least \(needed) pt tall, only \(have) pt available. Make the panel taller or zoom the current pane.",
                           "放不下\(name)分屏：至少需要 \(needed)pt 高，现在只有 \(have)pt。可以拉高面板，或放大当前窗格。"),
                         warning: true)
            return
        }

        manager.splitPane(targetID, in: tab, axis: axis)
        if candidate.hasHorizontalSplit {
            panelController?.autoWidenForSplit(minimumWidth: need.width)
        }
        if case .auto = mode {
            handle?.show(t("Split \(name) — there's more room that way", "已自动选择\(name)分屏（这个方向空间更充裕）"))
        }
    }

    func toggleZoom() {
        guard let tab = manager.activeTab else { return }
        guard tab.isSplit else {
            handle?.show(t("There's only one pane, so there's nothing to zoom.", "只有一个窗格，不需要放大。"))
            return
        }
        manager.toggleZoom(in: tab)
    }

    func equalize() {
        guard let tab = manager.activeTab, tab.isSplit else { return }
        manager.equalizePanes(in: tab)
    }

    func closeFocusedPane() {
        manager.closeFocusedPane()
    }
}

// MARK: - Divider

/// Draggable divider between two panes. AppKit instead of a SwiftUI gesture because
/// the modal tracking loop keeps receiving drags even while the cursor is over the
/// Metal-rendered terminal views, and cursor rects work reliably next to them.
final class SplitDividerView: NSView {
    var divider: SplitLayout.Divider? {
        didSet {
            if oldValue?.axis != divider?.axis {
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
            }
        }
    }
    var onDrag: ((SplitLayout.Divider, NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?

    private var isDragging = false

    override var isFlipped: Bool { true }

    private var cursor: NSCursor {
        divider?.axis == .vertical ? .resizeUpDown : .resizeLeftRight
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        guard divider != nil else { return }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, let superview else { return }
        isDragging = true
        needsDisplay = true
        cursor.set()

        var tracking = true
        while tracking, let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch next.type {
            case .leftMouseDragged:
                if let divider {
                    onDrag?(divider, superview.convert(next.locationInWindow, from: nil))
                }
                cursor.set()
            case .leftMouseUp:
                tracking = false
            default:
                break
            }
        }

        isDragging = false
        needsDisplay = true
        onDragEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let divider else { return }
        (isDragging ? NSColor.controlAccentColor : NSColor.separatorColor).setFill()
        if divider.axis == .horizontal {
            NSRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height).fill()
        } else {
            NSRect(x: 0, y: (bounds.height - 1) / 2, width: bounds.width, height: 1).fill()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
