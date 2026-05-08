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
    static let widthKey    = "sidecli.panelWidth"
    static let heightKey   = "sidecli.panelHeight"
    static let posYKey     = "sidecli.panelY"
    static let fontSizeKey = "sidecli.fontSize"
    static let defaultWidth:    CGFloat = 440
    static let defaultHeight:   CGFloat = 720
    static let defaultFontSize: Int     = 14
}

class PanelController: NSObject, ObservableObject {

    private var panel: FloatingPanel?

    @Published var isVisible    = false
    @Published var isPinned     = false
    @Published var isDarkTheme  = true
    @Published var panelWidth:  CGFloat = UserDefaults.standard.object(forKey: K.widthKey)  as? CGFloat ?? K.defaultWidth
    @Published var panelHeight: CGFloat = UserDefaults.standard.object(forKey: K.heightKey) as? CGFloat ?? K.defaultHeight
    @Published var fontSize:    Int     = UserDefaults.standard.object(forKey: K.fontSizeKey) as? Int ?? K.defaultFontSize

    let shortcutManager = GlobalShortcutManager()
    private var onboardingWasPinned: Bool?

    // MARK: - Setup

    func setup() {
        shortcutManager.onTrigger = { [weak self] in self?.toggle() }
        shortcutManager.register()
        createPanel()
        showPanel()
    }

    private func createPanel() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame

        let w = panelWidth
        let h = min(panelHeight, vf.height)

        let x = vf.minX
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
            self.panelWidth  = p.frame.width
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
        isVisible = true
    }

    // MARK: - Show / Hide (menu bar toggle — mirrors SidePeek WindowManager)

    func showWindow() {
        guard let p = panel else { return }
        p.makeKeyAndOrderFront(nil)
        p.autoHideManager?.showFull()
        isVisible = true
    }

    func hideWindow() {
        panel?.orderOut(nil)
        isVisible = false
    }

    func toggle() {
        guard let p = panel else { return }
        if p.isVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }

    // MARK: - Theme

    func toggleTheme() {
        isDarkTheme.toggle()
        panel?.appearance = NSAppearance(named: isDarkTheme ? .darkAqua : .aqua)
    }

    // MARK: - Pin

    func togglePin() {
        isPinned.toggle()
        panel?.autoHideManager?.setPinned(isPinned)
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

    func resize(to newWidth: CGFloat) {
        guard let p = panel else { return }
        let screen = screenForPanel()
        let maxW = screen.visibleFrame.width * 0.90
        let clamped = max(300, min(newWidth, maxW))
        panelWidth = clamped

        var frame = p.frame
        if p.edgeSnapManager?.getCurrentEdge() == .right {
            frame.origin.x = screen.visibleFrame.maxX - clamped
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
