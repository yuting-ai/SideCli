//
//  FloatingPanel.swift
//  SideCli
//
//  NSPanel subclass — mirrors SidePeek's FloatingWindow.swift.
//  Uses NSPanel instead of NSWindow so it can be non-activating
//  (mouse-enters-to-show without stealing app focus).
//

import AppKit
import SwiftUI

class FloatingPanel: NSPanel {

    // MARK: - Properties

    private(set) var edgeSnapManager: EdgeSnapManager?
    private(set) var autoHideManager: AutoHideManager?

    /// Docked to a screen edge: floats above other apps on every Space and never
    /// activates SideCli. Otherwise it behaves like an ordinary app window.
    private(set) var isDocked = true

    var onLiveResizeEnd: (() -> Void)?
    /// Called after a drag-snap animation completes with the final window origin.
    var onPositionCommitted: ((NSPoint) -> Void)?

    // MARK: - Init (mirrors FloatingWindow.init)

    init(contentRect: NSRect, contentView: NSView?) {
        super.init(
            contentRect: contentRect,
            // .miniaturizable lets the toolbar's yellow button minimize this borderless
            // panel to the Dock (without it, miniaturize(_:) silently does nothing).
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        setupPanel()
        setupContentView(contentView)
    }

    // MARK: - Key / Main overrides (NSPanel must opt-in)

    override var canBecomeKey: Bool  { true  }
    override var canBecomeMain: Bool { false }

    // MARK: - Setup (mirrors FloatingWindow.setupWindow)

    private func setupPanel() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        isMovableByWindowBackground = false   // only the drag handle moves the window
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false

        minSize = NSSize(width: 300, height: 200)
        delegate = self

        let isDark = NSApp.effectiveAppearance.name == .darkAqua
        appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    private func setupContentView(_ view: NSView?) {
        guard let view = view else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        contentView = view
    }

    // MARK: - Lifecycle (mirrors FloatingWindow)

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        initializeManagers()
        maskThemeFrame()
    }

    // AppKit adds the sheet backdrop as a sibling of contentView inside the
    // theme frame (contentView.superview), not as a subview of contentView.
    // contentView.masksToBounds only clips its own children, so the sibling
    // backdrop leaks into the transparent corners as a dark rectangle.
    // Applying the same cornerRadius + masksToBounds to the theme frame clips
    // ALL its children — including any sheet backdrop — to the rounded shape.
    private func maskThemeFrame() {
        guard let themeFrame = contentView?.superview else { return }
        themeFrame.wantsLayer = true
        themeFrame.layer?.cornerRadius = 12
        themeFrame.layer?.masksToBounds = true
    }

    private func initializeManagers() {
        if edgeSnapManager == nil {
            edgeSnapManager = EdgeSnapManager(window: self)
            edgeSnapManager?.onPositionCommitted = { [weak self] origin in
                self?.onPositionCommitted?(origin)
            }
        }
        if autoHideManager == nil {
            autoHideManager = AutoHideManager(window: self)
        }
    }

    override func close() {
        edgeSnapManager = nil
        autoHideManager = nil
        super.close()
    }

    // Pin the incoming frame to the snapped edge before applying it, so live
    // resizes of a snapped panel stay flush with the screen edge.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let frame = edgeSnapManager?.constrainedFrame(for: frameRect) ?? frameRect
        super.setFrame(frame, display: flag)
    }

    // MARK: - Docked / window mode

    func setDocked(_ docked: Bool) {
        isDocked = docked
        level = docked ? .floating : .normal
        collectionBehavior = docked ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    // As a regular window, a click brings SideCli forward like any app
    // (.nonactivatingPanel would otherwise leave the other app active and in front).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isDocked, !NSApp.isActive {
            NSApp.activate()
        }
        super.sendEvent(event)
    }

    // MARK: - Appearance

    func updateAppearance(isDark: Bool) {
        appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

// MARK: - NSWindowDelegate

extension FloatingPanel: NSWindowDelegate {

    func windowDidMove(_ notification: Notification) {
        edgeSnapManager?.handleWindowMove()
    }

    // User switched to another app/window: a shortcut-revealed panel may auto-hide again.
    func windowDidResignKey(_ notification: Notification) {
        autoHideManager?.releaseHoldOpen()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        onLiveResizeEnd?()
        // 方案C：广播 live resize 结束通知，触发所有活跃终端 Coordinator
        // 补发一次精准的最终尺寸 resize 信号，确保 opencode 等 TUI 工具
        // 哪怕在拖动过程中漏掉了中间的 SIGWINCH，松手时也能完整重绘。
        NotificationCenter.default.post(name: .terminalLiveResizeDidEnd, object: nil)
    }
}
