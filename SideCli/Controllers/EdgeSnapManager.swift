//
//  EdgeSnapManager.swift
//  SideCli
//
//  Direct port of SidePeek's EdgeSnapManager.swift.
//  Only difference: FloatingWindow → FloatingPanel.
//

import AppKit
import QuartzCore

enum Edge: Equatable {
    case left
    case right
}

/// Manages window edge snapping — identical logic to SidePeek.
class EdgeSnapManager {

    // MARK: - Properties

    weak var window: NSWindow?
    var onPositionCommitted: ((NSPoint) -> Void)?
    private var currentEdge: Edge?
    private var isUserDragging = false
    private var isProgrammaticMove = false
    private var dragEndCheckTimer: Timer?
    private var animationTimer: Timer?

    private let snapThreshold: CGFloat = 80   // snap when within 80px of edge
    private let edgeMargin:    CGFloat = 0    // flush with screen edge

    // MARK: - Animation state

    private var animStartX: CGFloat = 0
    private var animStartY: CGFloat = 0
    private var animTargetX: CGFloat = 0
    private var animTargetY: CGFloat = 0
    private var animStartTime: Date = Date()
    private var animDuration: TimeInterval = 0
    private var animCallback: (() -> Void)?

    // MARK: - Init

    init(window: NSWindow) {
        self.window = window
        setupInitialState()
    }

    // MARK: - Setup

    private func setupInitialState() {
        if let screen = NSScreen.main {
            snapToEdge(.left, screen: screen)
        }
    }

    // MARK: - Screen Detection

    private func getCurrentScreen() -> NSScreen? {
        guard let window = window else { return NSScreen.main }
        let windowFrame = window.frame

        var referencePoint: NSPoint
        if let edge = currentEdge {
            if edge == .left {
                referencePoint = NSPoint(x: windowFrame.origin.x + 1,
                                        y: windowFrame.origin.y + windowFrame.height / 2)
            } else {
                referencePoint = NSPoint(x: windowFrame.origin.x + windowFrame.width - 1,
                                        y: windowFrame.origin.y + windowFrame.height / 2)
            }
        } else {
            referencePoint = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        }

        var nearestScreen: NSScreen?
        var minDistance = CGFloat.greatestFiniteMagnitude
        for screen in NSScreen.screens {
            let c = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
            let d = sqrt(pow(referencePoint.x - c.x, 2) + pow(referencePoint.y - c.y, 2))
            if d < minDistance { minDistance = d; nearestScreen = screen }
        }
        return nearestScreen ?? NSScreen.main
    }

    private func isOuterEdge(edge: Edge, screen: NSScreen) -> Bool {
        let sf = screen.frame
        let threshold: CGFloat = 50
        for other in NSScreen.screens {
            if other == screen { continue }
            let of = other.frame
            let hasVerticalOverlap = !(sf.maxY < of.minY || sf.minY > of.maxY)
            if !hasVerticalOverlap { continue }
            switch edge {
            case .left:
                if abs(of.maxX - sf.minX) < threshold { return false }
            case .right:
                if abs(sf.maxX - of.minX) < threshold { return false }
            }
        }
        return true
    }

    // MARK: - Animation (easeOutCubic, 60fps — identical to SidePeek)

    private func easeOutCubic(_ t: CGFloat) -> CGFloat {
        1 - pow(1 - t, 3)
    }

    private func animateWindowPosition(targetX: CGFloat, targetY: CGFloat,
                                       duration: TimeInterval, callback: @escaping () -> Void) {
        guard let window = window else { return }
        animStartX    = window.frame.origin.x
        animStartY    = window.frame.origin.y
        animTargetX   = targetX
        animTargetY   = targetY
        animStartTime = Date()
        animDuration  = duration
        animCallback  = callback
        animationTimer?.invalidate()
        scheduleAnimationFrame()
    }

    private func scheduleAnimationFrame() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: false) { [weak self] _ in
            self?.animationStep()
        }
    }

    private func animationStep() {
        guard let window = window else { return }
        let elapsed  = Date().timeIntervalSince(animStartTime)
        let progress = min(elapsed / animDuration, 1.0)
        let eased    = easeOutCubic(CGFloat(progress))

        let x = animStartX + (animTargetX - animStartX) * eased
        let y = animStartY + (animTargetY - animStartY) * eased
        if x.isFinite && y.isFinite {
            window.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
        }

        if progress < 1.0 {
            scheduleAnimationFrame()
        } else {
            animationTimer = nil
            animCallback?()
            animCallback = nil
        }
    }

    // MARK: - Window Movement (mirrors SidePeek handleWindowMove)

    func handleWindowMove() {
        if isProgrammaticMove { return }
        guard let window = window else { return }

        if let fp = window as? FloatingPanel,
           let ahm = fp.autoHideManager,
           !ahm.getIsExpanded() { return }

        if !isUserDragging {
            isUserDragging = true
            if let fp = window as? FloatingPanel,
               let ahm = fp.autoHideManager,
               !ahm.getIsExpanded() {
                ahm.showFull()
            }
        }

        dragEndCheckTimer?.invalidate()
        dragEndCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.handleDragEnd()
        }
    }

    func handleDragEnd() {
        if !isUserDragging { return }
        isUserDragging = false
        dragEndCheckTimer?.invalidate()
        dragEndCheckTimer = nil
        handleWindowSnapToEdge()
    }

    private func handleWindowSnapToEdge() {
        guard let window = window, let screen = getCurrentScreen() else { return }

        let sf       = screen.visibleFrame
        let displayX = sf.minX
        let dispW    = sf.width
        let wf       = window.frame
        let winX     = wf.origin.x
        let winY     = wf.origin.y
        let winW     = wf.width

        let leftDist  = abs(winX - displayX)
        let rightDist = abs((winX + winW) - (displayX + dispW))
        let nearLeft  = winX <= displayX + snapThreshold
        let nearRight = (winX + winW) >= (displayX + dispW - snapThreshold)

        var candidates: [(edge: Edge, dist: CGFloat)] = []
        if nearLeft  && isOuterEdge(edge: .left,  screen: screen) { candidates.append((.left,  leftDist)) }
        if nearRight && isOuterEdge(edge: .right, screen: screen) { candidates.append((.right, rightDist)) }

        if candidates.isEmpty {
            if let fp = window as? FloatingPanel,
               let ahm = fp.autoHideManager,
               currentEdge != nil && ahm.getIsExpanded() {
                currentEdge = nil
            }
            return
        }

        let nearest = candidates.min(by: { $0.dist < $1.dist })!
        var targetX: CGFloat
        switch nearest.edge {
        case .left:  targetX = floor(displayX + edgeMargin)
        case .right: targetX = floor(displayX + dispW - winW - edgeMargin)
        }
        let targetY = winY

        if !targetX.isFinite || !targetY.isFinite { return }

        let tol: CGFloat = 3
        if currentEdge == nearest.edge && abs(winX - targetX) <= tol && abs(winY - targetY) <= tol {
            if let fp = window as? FloatingPanel, let ahm = fp.autoHideManager, !ahm.getIsExpanded() {
                ahm.showFull()
            }
            return
        }

        currentEdge = nearest.edge
        isProgrammaticMove = true

        if let fp = window as? FloatingPanel, let ahm = fp.autoHideManager, !ahm.getIsExpanded() {
            ahm.showFull()
        }

        animateWindowPosition(targetX: targetX, targetY: targetY, duration: 0.18) { [weak self] in
            self?.isProgrammaticMove = false
            if let origin = self?.window?.frame.origin {
                self?.onPositionCommitted?(origin)
            }
        }
    }

    // MARK: - Snap to Edge

    func snapToEdge(_ edge: Edge, screen: NSScreen) {
        guard let window = window else { return }
        let sf    = screen.visibleFrame
        let winSz = window.frame.size
        let curY  = window.frame.origin.y

        var targetX: CGFloat
        switch edge {
        case .left:  targetX = sf.minX + edgeMargin
        case .right: targetX = sf.maxX - winSz.width - edgeMargin
        }

        currentEdge = edge
        isProgrammaticMove = true
        animateWindowPosition(targetX: targetX, targetY: curY, duration: 0.18) { [weak self] in
            self?.isProgrammaticMove = false
        }
    }

    // MARK: - Frame Change (called from FloatingPanel.setFrame)

    func windowFrameDidChange(to frame: NSRect) {
        guard let window = window as? FloatingPanel,
              let edge = currentEdge,
              !isUserDragging,
              !isProgrammaticMove,
              let screen = getCurrentScreen() else { return }

        if let ahm = window.autoHideManager, !ahm.getIsExpanded() { return }

        maintainEdgePosition(edge: edge, screen: screen)
    }

    private func maintainEdgePosition(edge: Edge, screen: NSScreen) {
        guard let window = window else { return }
        let sf     = screen.visibleFrame
        let winSz  = window.frame.size
        let curY   = window.frame.origin.y
        let tol: CGFloat = 2
        var targetX = window.frame.origin.x
        var needsRepos = false

        switch edge {
        case .left:
            let expected = sf.minX + edgeMargin
            if abs(window.frame.origin.x - expected) > tol { targetX = expected; needsRepos = true }
        case .right:
            let expected = sf.maxX - winSz.width - edgeMargin
            if abs(window.frame.origin.x - expected) > tol { targetX = expected; needsRepos = true }
        }

        if needsRepos {
            isProgrammaticMove = true
            window.setFrameOrigin(NSPoint(x: targetX, y: curY))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.isProgrammaticMove = false
            }
        }
    }

    // MARK: - Public Accessors

    func getCurrentEdge() -> Edge? { currentEdge }
    func isCurrentlyDragging() -> Bool { isUserDragging }
    func setProgrammaticMove(_ value: Bool) { isProgrammaticMove = value }

    // MARK: - Cleanup

    func cleanup() {
        dragEndCheckTimer?.invalidate(); dragEndCheckTimer = nil
        animationTimer?.invalidate();    animationTimer    = nil
        animCallback = nil
    }

    deinit { cleanup() }
}
