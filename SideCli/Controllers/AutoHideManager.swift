//
//  AutoHideManager.swift
//  SideCli
//
//  Direct port of SidePeek's AutoHideManager.swift.
//  Only change: FloatingWindow → FloatingPanel.
//

import AppKit

/// Manages auto-hide/show based on mouse proximity — identical logic to SidePeek.
class AutoHideManager {

    // MARK: - Properties

    weak var window: NSWindow?
    private var mouseCheckTimer: Timer?
    private var hideTimeout: Timer?
    private var positionCheckTimer: Timer?
    private var isExpanded = true
    private var isPinned   = false
    private var isSuppressed = false

    private let hideDelay:              TimeInterval = 0.4
    private let mouseCheckInterval:     TimeInterval = 0.1
    private let positionCheckInterval:  TimeInterval = 2.0
    private let visibleSize:            CGFloat      = 6  // detection zone when hidden

    // MARK: - Init

    init(window: NSWindow) {
        self.window = window
        if UserDefaults.standard.object(forKey: "autoHideEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "autoHideEnabled")
        }
        startMouseTracking()
        startPositionChecking()
    }

    // MARK: - Mouse Tracking

    private func startMouseTracking() {
        guard mouseCheckTimer == nil else { return }
        mouseCheckTimer = Timer.scheduledTimer(withTimeInterval: mouseCheckInterval, repeats: true) { [weak self] _ in
            self?.checkMousePosition()
        }
    }

    private func startPositionChecking() {
        guard positionCheckTimer == nil else { return }
        positionCheckTimer = Timer.scheduledTimer(withTimeInterval: positionCheckInterval, repeats: true) { [weak self] _ in
            self?.syncWindowState()
        }
    }

    private func syncWindowState() {
        guard let window = window,
              let screen = getCurrentScreen(),
              !isSuppressed,
              !isPinned,
              UserDefaults.standard.bool(forKey: "autoHideEnabled") else { return }

        let wf  = window.frame
        let sf  = screen.visibleFrame

        let visibleLeft  = abs(wf.minX - sf.minX) < 5
        let visibleRight = abs(wf.maxX - sf.maxX) < 5
        let actuallyVisible = visibleLeft || visibleRight

        if actuallyVisible && !isExpanded {
            isExpanded = true
            if !isMouseNearWindow() { startHideTimeout() }
        } else if actuallyVisible && isExpanded {
            if !isMouseNearWindow() && hideTimeout == nil { startHideTimeout() }
        }
    }

    private func checkMousePosition() {
        guard let fp = window as? FloatingPanel else { return }
        if fp.edgeSnapManager?.isCurrentlyDragging() == true { return }

        if isSuppressed {
            if !isExpanded { showFull() }
            cancelHideTimeout()
            return
        }

        let autoHideEnabled = UserDefaults.standard.bool(forKey: "autoHideEnabled")
        if !autoHideEnabled {
            if !isExpanded { showFull() }
            return
        }

        let isNear = isMouseNearWindow()

        if isNear {
            cancelHideTimeout()
            if !isExpanded { showFull() }
        } else {
            if isPinned { return }  // pinned → never auto-hide regardless of mouse position
            if isExpanded && hideTimeout == nil {
                if fp.edgeSnapManager?.getCurrentEdge() != nil {
                    startHideTimeout()
                }
            }
        }
    }

    private func isMouseNearWindow() -> Bool {
        guard let window = window else { return false }
        let cursor = NSEvent.mouseLocation
        let wf     = window.frame

        if isExpanded {
            guard let screen = getCurrentScreen() else { return false }
            let sf = screen.visibleFrame
            let margin: CGFloat = 2
            var checkX = wf.origin.x
            var checkW = wf.width

            if let edge = (window as? FloatingPanel)?.edgeSnapManager?.getCurrentEdge() {
                if edge == .left {
                    checkX = sf.minX
                    checkW = wf.width + margin
                } else {
                    checkW = wf.width + margin
                }
            }
            return cursor.x >= checkX && cursor.x <= checkX + checkW &&
                   cursor.y >= wf.origin.y && cursor.y <= wf.origin.y + wf.height
        }

        guard let edge = (window as? FloatingPanel)?.edgeSnapManager?.getCurrentEdge(),
              let screen = getCurrentScreen() else { return false }
        let sf = screen.visibleFrame
        var visAreaX: CGFloat
        if edge == .left {
            visAreaX = sf.minX
        } else {
            visAreaX = sf.maxX - visibleSize
        }
        return cursor.x >= visAreaX && cursor.x <= visAreaX + visibleSize &&
               cursor.y >= wf.origin.y && cursor.y <= wf.origin.y + wf.height
    }

    // MARK: - Hide / Show

    private func startHideTimeout() {
        cancelHideTimeout()
        hideTimeout = Timer.scheduledTimer(withTimeInterval: hideDelay, repeats: false) { [weak self] _ in
            self?.hideToEdge()
            self?.hideTimeout = nil
        }
    }

    private func cancelHideTimeout() {
        hideTimeout?.invalidate()
        hideTimeout = nil
    }

    /// Move window fully off-screen to its snapped edge (visibleSize = 0).
    /// Mirrors SidePeek's hideToEdge / stickToEdge.
    func hideToEdge() {
        guard let fp = window as? FloatingPanel,
              let edge = fp.edgeSnapManager?.getCurrentEdge(),
              let screen = getCurrentScreen() else { return }

        let sf     = screen.visibleFrame
        let wf     = fp.frame
        let winW   = wf.width
        var targetX: CGFloat
        let targetY = wf.origin.y

        if edge == .left {
            targetX = floor(sf.minX - winW)   // fully off-screen left
        } else {
            targetX = floor(sf.maxX)           // fully off-screen right
        }

        if !targetX.isFinite { return }

        isExpanded = false
        fp.edgeSnapManager?.setProgrammaticMove(true)
        fp.setFrameOrigin(NSPoint(x: targetX, y: targetY))
        fp.edgeSnapManager?.setProgrammaticMove(false)
    }

    /// Expand window back to its snapped edge position.
    /// Mirrors SidePeek's showFull.
    func showFull() {
        guard let fp = window as? FloatingPanel,
              let edge = fp.edgeSnapManager?.getCurrentEdge(),
              let screen = getCurrentScreen() else { return }

        let sf    = screen.visibleFrame
        let wf    = fp.frame
        var winW  = wf.width
        let winH  = wf.height

        let maxW = max(300, sf.width)
        if winW > maxW {
            winW = maxW
            fp.setContentSize(NSSize(width: winW, height: winH))
        }

        var targetX: CGFloat
        let targetY = wf.origin.y
        switch edge {
        case .left:  targetX = floor(sf.minX)
        case .right: targetX = floor(sf.maxX - winW)
        }

        if !targetX.isFinite { return }

        fp.edgeSnapManager?.setProgrammaticMove(true)
        isExpanded = true
        fp.setFrameOrigin(NSPoint(x: targetX, y: targetY))
        fp.edgeSnapManager?.setProgrammaticMove(false)
    }

    // MARK: - Screen Detection (same logic as EdgeSnapManager — edge-relative reference point)

    private func getCurrentScreen() -> NSScreen? {
        guard let window = window else { return NSScreen.main }
        let wf = window.frame
        var ref: NSPoint
        if let edge = (window as? FloatingPanel)?.edgeSnapManager?.getCurrentEdge() {
            ref = edge == .left
                ? NSPoint(x: wf.origin.x + 1,            y: wf.midY)
                : NSPoint(x: wf.origin.x + wf.width - 1, y: wf.midY)
        } else {
            ref = NSPoint(x: wf.midX, y: wf.midY)
        }
        var nearest: NSScreen?
        var minDist = CGFloat.greatestFiniteMagnitude
        for screen in NSScreen.screens {
            let c = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
            let d = sqrt(pow(ref.x - c.x, 2) + pow(ref.y - c.y, 2))
            if d < minDist { minDist = d; nearest = screen }
        }
        return nearest ?? NSScreen.main
    }

    // MARK: - Pin Control

    func setPinned(_ pinned: Bool) { isPinned = pinned }
    func getPinned() -> Bool { isPinned }
    func getIsExpanded() -> Bool { isExpanded }
    func setSuppressed(_ suppressed: Bool) {
        isSuppressed = suppressed
        if suppressed {
            cancelHideTimeout()
            showFull()
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        cancelHideTimeout()
        mouseCheckTimer?.invalidate();    mouseCheckTimer   = nil
        positionCheckTimer?.invalidate(); positionCheckTimer = nil
    }

    deinit { cleanup() }
}
