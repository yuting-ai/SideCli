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

    var onLiveResizeEnd: (() -> Void)?
    /// Called after a drag-snap animation completes with the final window origin.
    var onPositionCommitted: ((NSPoint) -> Void)?

    // MARK: - Init (mirrors FloatingWindow.init)

    init(contentRect: NSRect, contentView: NSView?) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
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

    // Notify EdgeSnapManager on every frame change (resize or drag).
    // Mirrors FloatingWindow.setFrame → edgeSnapManager?.windowFrameDidChange.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        edgeSnapManager?.windowFrameDidChange(to: frameRect)
        super.setFrame(frameRect, display: flag)
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

    func windowDidEndLiveResize(_ notification: Notification) {
        onLiveResizeEnd?()
    }
}
