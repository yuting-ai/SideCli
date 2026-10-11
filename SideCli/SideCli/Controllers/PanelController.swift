//
//  PanelController.swift
//  SideCli
//
//  Mirrors SidePeek's WindowManager — delegates all window behavior
//  (edge snap, auto-hide, multi-monitor) to FloatingPanel + its managers.
//

import AppKit
import Combine
import SwiftUI

private enum K {
    static let widthKey     = "sidecli.panelWidth"
    static let heightKey    = "sidecli.panelHeight"
    static let posYKey      = "sidecli.panelY"
    static let fontSizeKey  = "sidecli.fontSize"
    static let darkThemeKey = "sidecli.isDarkTheme"
    static let pinnedKey    = "sidecli.isPinned"
    static let widthBeforeSplitKey = "sidecli.panelWidthBeforeSplit"
    static let defaultWidth:    CGFloat = 660
    static let defaultHeight:   CGFloat = 720
    static let defaultFontSize: Int     = 14
}

class PanelController: NSObject, ObservableObject {

    private var panel: FloatingPanel?

    @Published var isVisible    = false
    @Published var isPinned:    Bool    = UserDefaults.standard.object(forKey: K.pinnedKey)    as? Bool    ?? false
    @Published var isDarkTheme: Bool    = UserDefaults.standard.object(forKey: K.darkThemeKey) as? Bool    ?? true
    @Published var panelWidth:  CGFloat = UserDefaults.standard.object(forKey: K.widthKey)     as? CGFloat ?? K.defaultWidth
    @Published var panelHeight: CGFloat = UserDefaults.standard.object(forKey: K.heightKey)    as? CGFloat ?? K.defaultHeight
    @Published var fontSize:    Int     = UserDefaults.standard.object(forKey: K.fontSizeKey)  as? Int     ?? K.defaultFontSize
    /// Edge the panel is currently snapped to (nil = floating). Drives which
    /// side the width-resize handle sits on.
    @Published private(set) var snappedEdge: Edge? = EdgeSnapManager.savedEdge()

    /// Width the panel had before a left/right split widened it automatically.
    /// Restored once no tab has a left/right split; cleared as soon as the user
    /// sets a width themselves. The panel size is shared by every tab — switching
    /// tabs never resizes it.
    private var widthBeforeAutoWiden: CGFloat? = UserDefaults.standard.object(forKey: K.widthBeforeSplitKey) as? CGFloat {
        didSet { UserDefaults.standard.set(widthBeforeAutoWiden, forKey: K.widthBeforeSplitKey) }
    }

    let shortcutManager = GlobalShortcutManager()
    private var onboardingWasPinned: Bool?

    // MARK: - Setup

    func setup() {
        shortcutManager.onTrigger = { [weak self] in self?.toggle() }
        shortcutManager.register()
        createPanel()
        showPanel()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenChange() {
        // Wait for macOS to settle the new screen layout before re-snapping.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reSnapToCorrectScreen()
        }
    }

    private func reSnapToCorrectScreen() {
        guard let panel,
              let edgeManager   = panel.edgeSnapManager,
              let autoHideManager = panel.autoHideManager,
              let edge = edgeManager.getCurrentEdge(),
              let screen = edgeManager.findOutermostScreen(for: edge) else { return }

        if autoHideManager.getIsExpanded() {
            edgeManager.snapToEdge(edge, screen: screen)
        } else {
            // Re-apply hidden position on the correct screen.
            // AutoHideManager.hideToEdge() now uses getCurrentScreen() which
            // returns findOutermostScreen, so coordinates will be correct.
            autoHideManager.hideToEdge()
        }
    }

    private func createPanel() {
        // Size and place against the screen EdgeSnapManager will actually snap to,
        // not NSScreen.main — on multi-monitor setups they can differ in size/offset.
        let edge = EdgeSnapManager.savedEdge()
        guard let screen = EdgeSnapManager.findOutermostScreen(for: edge) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame

        // Saved size may come from a larger monitor that is no longer attached.
        let w = max(300, min(panelWidth, vf.width))
        let h = max(200, min(panelHeight, vf.height))
        panelWidth = w
        panelHeight = h

        let x = edge == .left ? vf.minX : vf.maxX - w
        // Restore saved Y position, or default to vertically centered
        let savedY = UserDefaults.standard.object(forKey: K.posYKey) as? CGFloat
        let y: CGFloat
        if let saved = savedY {
            y = max(vf.minY, min(saved, vf.maxY - h))
        } else {
            y = vf.midY - h / 2
        }
        let initialFrame = NSRect(x: x, y: y, width: w, height: h)

        // Build SwiftUI content wrapped in a background view
        let wrapper = PanelBackgroundView(frame: NSRect(origin: .zero, size: initialFrame.size))
        wrapper.autoresizingMask = [.width, .height]

        let rootView = ContentView()
            .environmentObject(self)
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = wrapper.bounds
        hosting.autoresizingMask = [.width, .height]
        wrapper.addSubview(hosting)

        let p = FloatingPanel(contentRect: initialFrame, contentView: wrapper)
        p.appearance = NSAppearance(named: isDarkTheme ? .darkAqua : .aqua)

        p.onLiveResizeEnd = { [weak self, weak p] in
            guard let self, let p else { return }
            self.storeWidth(p.frame.width)
            self.panelHeight = p.frame.height
            self.commitResize()
            self.saveYPosition(p.frame.origin.y)
        }

        p.onPositionCommitted = { [weak self] origin in
            self?.saveYPosition(origin.y)
        }

        self.panel = p
    }

    private func showPanel() {
        // makeKeyAndOrderFront triggers initializeManagers → EdgeSnapManager snaps to left
        panel?.makeKeyAndOrderFront(nil)
        // Restore persisted pin state into the newly created AutoHideManager.
        panel?.autoHideManager?.setPinned(isPinned)
        if let edgeManager = panel?.edgeSnapManager {
            snappedEdge = edgeManager.getCurrentEdge()
            edgeManager.onEdgeChanged = { [weak self] edge in self?.snappedEdge = edge }
        }
        isVisible = true
    }

    // MARK: - Show / Hide (menu bar toggle — mirrors SidePeek WindowManager)

    func showWindow() {
        guard let p = panel else { return }
        p.makeKeyAndOrderFront(nil)
        p.autoHideManager?.showFull()
        // Shown by shortcut, not by hovering the edge: keep it out until the
        // mouse visits the panel or it loses key focus, so typing isn't cut off.
        p.autoHideManager?.holdOpenUntilMouseVisits()
        p.autoHideManager?.resume()
        isVisible = true
    }

    func hideWindow() {
        panel?.autoHideManager?.suspend()
        panel?.orderOut(nil)
        isVisible = false
    }

    func toggle() {
        guard let p = panel else { return }
        // An auto-hidden panel is still ordered in (isVisible == true) but parked
        // off-screen, so treat it as hidden and bring it back.
        let isExpanded = p.autoHideManager?.getIsExpanded() ?? true
        if p.isVisible && isExpanded {
            hideWindow()
        } else {
            showWindow()
        }
    }

    // MARK: - Theme

    func toggleTheme() {
        isDarkTheme.toggle()
        UserDefaults.standard.set(isDarkTheme, forKey: K.darkThemeKey)
        panel?.appearance = NSAppearance(named: isDarkTheme ? .darkAqua : .aqua)
    }

    // MARK: - Pin

    func togglePin() {
        isPinned.toggle()
        UserDefaults.standard.set(isPinned, forKey: K.pinnedKey)
        panel?.autoHideManager?.setPinned(isPinned)
    }

    /// Temporarily disables auto-hide while a sheet (e.g. Settings) is presented.
    func setSheetPresented(_ active: Bool) {
        panel?.autoHideManager?.setSuppressed(active)
    }

    /// Temporarily disables auto-hide while onboarding is visible.
    func setOnboardingActive(_ active: Bool) {
        guard let panel else { return }
        if active {
            if onboardingWasPinned == nil {
                onboardingWasPinned = isPinned
            }
            if !isPinned {
                isPinned = true
                panel.autoHideManager?.setPinned(true)
            }
            panel.autoHideManager?.setSuppressed(true)
            panel.autoHideManager?.showFull()
        } else {
            panel.autoHideManager?.setSuppressed(false)
            if let previousPinned = onboardingWasPinned {
                isPinned = previousPinned
                panel.autoHideManager?.setPinned(previousPinned)
            }
            onboardingWasPinned = nil
        }
    }

    // MARK: - Resize (called by ContentView's drag handles)

    private func screenForPanel() -> NSScreen {
        guard let p = panel else { return NSScreen.screens.first ?? NSScreen() }
        return NSScreen.screens.first { $0.frame.intersects(p.frame) }
            ?? NSScreen.screens.first ?? NSScreen()
    }

    /// Current on-screen width (panelWidth can lag behind native resizes / clamping).
    var currentPanelWidth: CGFloat { panel?.frame.width ?? panelWidth }

    /// Width change driven by the handle on the panel's LEFT side: the right edge
    /// stays put and the left edge follows the mouse.
    func resize(to newWidth: CGFloat) {
        guard let p = panel else { return }
        let edge = p.edgeSnapManager?.getCurrentEdge()
        let screen = edge.flatMap { p.edgeSnapManager?.findOutermostScreen(for: $0) } ?? screenForPanel()
        let maxW = screen.visibleFrame.width * 0.90
        let clamped = max(300, min(newWidth, maxW))
        storeWidth(clamped)

        var frame = p.frame
        switch edge {
        case .right: frame.origin.x = screen.visibleFrame.maxX - clamped
        case .left:  break   // left edge is pinned to the screen; handle is hidden in this state
        case nil:    frame.origin.x = frame.maxX - clamped
        }
        frame.size.width = clamped
        p.edgeSnapManager?.setProgrammaticMove(true)
        p.setFrame(frame, display: true)
        p.edgeSnapManager?.setProgrammaticMove(false)
    }

    func resizeHeight(to newHeight: CGFloat) {
        guard let p = panel else { return }
        let maxH = screenForPanel().visibleFrame.height
        let clamped = max(200, min(newHeight, maxH))
        panelHeight = clamped

        var frame = p.frame
        let top = frame.maxY    // keep top fixed
        frame.size.height = clamped
        frame.origin.y = top - clamped
        p.edgeSnapManager?.setProgrammaticMove(true)
        p.setFrame(frame, display: true)
        p.edgeSnapManager?.setProgrammaticMove(false)
    }

    // MARK: - Split width (left/right splits widen the panel)

    /// Widest the panel may grow on its own for a left/right split: 60% of the screen.
    var autoWidenLimit: CGFloat {
        guard let p = panel else { return K.defaultWidth }
        let screen = p.edgeSnapManager?.getCurrentEdge().flatMap { p.edgeSnapManager?.findOutermostScreen(for: $0) }
            ?? screenForPanel()
        return (screen.visibleFrame.width * 0.6).rounded(.down)
    }

    /// A width the user chose. It applies to every tab and ends any pending
    /// "shrink back after the split closes".
    private func storeWidth(_ width: CGFloat) {
        panelWidth = width
        widthBeforeAutoWiden = nil
    }

    /// Called after a left/right split was created. Widens the shared panel width
    /// when the new layout needs it (up to `autoWidenLimit`).
    func autoWidenForSplit(minimumWidth: CGFloat) {
        guard let p = panel else { return }
        let current = p.frame.width
        guard current + 0.5 < minimumWidth else { return }
        let limit = autoWidenLimit
        // Same as the prototype: roomy rather than just-barely-fits, capped at 60% of the screen.
        let target = min(limit, max(minimumWidth.rounded(.up), (current * 1.8).rounded()))
        guard target > current + 0.5 else { return }
        if widthBeforeAutoWiden == nil { widthBeforeAutoWiden = current }
        panelWidth = target
        commitResize()
        applyWidth(target)
    }

    /// Called whenever any tab's layout may have changed. Once no tab has a
    /// left/right split any more, gives back the width an auto-widen took.
    func layoutsChanged(anyTabHasHorizontalSplit: Bool) {
        guard !anyTabHasHorizontalSplit, let previous = widthBeforeAutoWiden,
              let p = panel, !p.inLiveResize else { return }
        widthBeforeAutoWiden = nil
        panelWidth = previous
        commitResize()
        applyWidth(previous)
    }

    /// Grows the panel so a layout that doesn't fit fits again ("Resize panel to fit").
    func growToFit(contentNeeded needed: CGSize, contentAvailable available: CGSize) {
        guard let p = panel else { return }
        if needed.width > available.width {
            let width = (p.frame.width + needed.width - available.width).rounded(.up)
            storeWidth(width)
            applyWidth(width)
        }
        if needed.height > available.height {
            resizeHeight(to: (p.frame.height + needed.height - available.height).rounded(.up))
        }
        commitResize()
        NotificationCenter.default.post(name: .terminalLiveResizeDidEnd, object: nil)
    }

    /// Animates to `width`, keeping the snapped edge flush with the screen.
    private func applyWidth(_ width: CGFloat) {
        guard let p = panel else { return }
        let edge = p.edgeSnapManager?.getCurrentEdge()
        let screen = edge.flatMap { p.edgeSnapManager?.findOutermostScreen(for: $0) } ?? screenForPanel()
        let clamped = max(300, min(width, screen.visibleFrame.width * 0.90))
        guard abs(p.frame.width - clamped) > 0.5 else { return }

        var frame = p.frame
        frame.size.width = clamped
        let isExpanded = p.autoHideManager?.getIsExpanded() ?? true
        p.edgeSnapManager?.setProgrammaticMove(true)
        if isExpanded {
            switch edge {
            case .right: frame.origin.x = screen.visibleFrame.maxX - clamped
            case .left:  frame.origin.x = screen.visibleFrame.minX
            case nil:    break   // floating: grow to the right
            }
            p.setFrame(frame, display: true, animate: p.isVisible)
        } else {
            // Parked off-screen: resize, then re-park so no sliver peeks out.
            p.setFrame(frame, display: false)
            p.autoHideManager?.hideToEdge()
        }
        p.edgeSnapManager?.setProgrammaticMove(false)
        NotificationCenter.default.post(name: .terminalLiveResizeDidEnd, object: nil)
    }

    func commitResize() {
        UserDefaults.standard.set(panelWidth,  forKey: K.widthKey)
        UserDefaults.standard.set(panelHeight, forKey: K.heightKey)
    }

    func saveYPosition(_ y: CGFloat) {
        UserDefaults.standard.set(y, forKey: K.posYKey)
    }

    func updateFontSize(_ size: Int) {
        fontSize = max(10, min(size, 28))
        UserDefaults.standard.set(fontSize, forKey: K.fontSizeKey)
    }

    // MARK: - Session State

    func saveSessionState() {
        NotificationCenter.default.post(name: .saveSessionState, object: nil)
    }

    // MARK: - Cleanup

    deinit {
        NotificationCenter.default.removeObserver(self)
        panel?.close()
    }
}

// MARK: - Panel Background View

private class PanelBackgroundView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 0.97).setFill()
        bounds.fill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
    }
}
