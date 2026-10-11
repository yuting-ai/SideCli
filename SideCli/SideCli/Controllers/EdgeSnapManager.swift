//
//  EdgeSnapManager.swift
//  SideCli
//
//  Direct port of SidePeek's EdgeSnapManager.swift.
//  Only difference: FloatingWindow → FloatingPanel.
//

import AppKit
import QuartzCore

enum Edge: String, Equatable {
    case left
    case right
}

/// Manages window edge snapping — identical logic to SidePeek.
class EdgeSnapManager {

    // MARK: - Properties

    weak var window: NSWindow?
    var onPositionCommitted: ((NSPoint) -> Void)?
    /// Fired whenever the snapped edge changes (nil = floating).
    var onEdgeChanged: ((Edge?) -> Void)?
    private var currentEdge: Edge?
    private var isUserDragging = false
    private var isProgrammaticMove = false
    private var dragEndCheckTimer: Timer?
    private var animationTimer: Timer?

    private let snapThreshold: CGFloat = 80   // snap when within 80px of edge
    private let edgeMargin:    CGFloat = 0    // flush with screen edge

    private static let edgeKey = "sidecli.snapEdge"

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

    /// Edge the panel was last snapped to (defaults to left). Also used by
    /// PanelController to size/place the panel on the right screen at launch.
    static func savedEdge() -> Edge {
        UserDefaults.standard.string(forKey: edgeKey).flatMap(Edge.init(rawValue:)) ?? .left
    }

    private func setupInitialState() {
        let edge = Self.savedEdge()
        let screen = findOutermostScreen(for: edge)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let screen = screen {
            snapToEdge(edge, screen: screen)
        }
    }

    // Persist currentEdge so it survives app restarts and monitor reconnects.
    private func setCurrentEdge(_ edge: Edge?) {
        let changed = currentEdge != edge
        currentEdge = edge
        if let edge = edge {
            UserDefaults.standard.set(edge.rawValue, forKey: Self.edgeKey)
        }
        if changed { onEdgeChanged?(edge) }
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

    private static func isOuterEdge(edge: Edge, screen: NSScreen) -> Bool {
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
        // Resizing from the top/left border also moves the origin; that is not a drag.
        if window.inLiveResize { return }

        if let fp = window as? FloatingPanel,
           let ahm = fp.autoHideManager,
           !ahm.getIsExpanded() { return }

        isUserDragging = true

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
        if nearLeft  && Self.isOuterEdge(edge: .left,  screen: screen) { candidates.append((.left,  leftDist)) }
        if nearRight && Self.isOuterEdge(edge: .right, screen: screen) { candidates.append((.right, rightDist)) }

        if candidates.isEmpty {
            if let fp = window as? FloatingPanel,
               let ahm = fp.autoHideManager,
               currentEdge != nil && ahm.getIsExpanded() {
                setCurrentEdge(nil)
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

        setCurrentEdge(nearest.edge)
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
        // Keep the panel vertically on the target screen (e.g. after moving to a
        // monitor with a different height or vertical offset).
        let curY  = max(sf.minY, min(window.frame.origin.y, sf.maxY - winSz.height))

        var targetX: CGFloat
        switch edge {
        case .left:  targetX = sf.minX + edgeMargin
        case .right: targetX = sf.maxX - winSz.width - edgeMargin
        }

        setCurrentEdge(edge)
        isProgrammaticMove = true
        animateWindowPosition(targetX: targetX, targetY: curY, duration: 0.18) { [weak self] in
            self?.isProgrammaticMove = false
        }
    }

    // MARK: - Frame Constraint (called from FloatingPanel.setFrame)

    /// Returns `frame` with its x pinned to the snapped edge, so a live resize of a
    /// snapped panel keeps it flush with the screen edge. Applied to the frame that
    /// is about to be set (not the current one), and without a separate
    /// setFrameOrigin that super.setFrame would immediately overwrite.
    func constrainedFrame(for frame: NSRect) -> NSRect {
        guard let fp = window as? FloatingPanel,
              let edge = currentEdge,
              !isProgrammaticMove,
              !isUserDragging || fp.inLiveResize else { return frame }
        if let ahm = fp.autoHideManager, !ahm.getIsExpanded() { return frame }
        guard let screen = getCurrentScreen() else { return frame }

        let sf = screen.visibleFrame
        var constrained = frame
        switch edge {
        case .left:  constrained.origin.x = sf.minX + edgeMargin
        case .right: constrained.origin.x = sf.maxX - frame.width - edgeMargin
        }
        return constrained
    }

    // MARK: - Public Accessors

    func getCurrentEdge() -> Edge? { currentEdge }
    func isCurrentlyDragging() -> Bool { isUserDragging }
    func setProgrammaticMove(_ value: Bool) { isProgrammaticMove = value }

    /// Returns the screen whose outer edge matches `edge` (used by AutoHideManager
    /// and the screen-change handler to avoid wrong-screen coordinate calculations).
    func findOutermostScreen(for edge: Edge) -> NSScreen? {
        Self.findOutermostScreen(for: edge)
    }

    static func findOutermostScreen(for edge: Edge) -> NSScreen? {
        let candidates = NSScreen.screens.filter { isOuterEdge(edge: edge, screen: $0) }
        if candidates.isEmpty { return NSScreen.main }
        switch edge {
        case .left:  return candidates.min(by: { $0.frame.minX < $1.frame.minX })
        case .right: return candidates.max(by: { $0.frame.maxX < $1.frame.maxX })
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        dragEndCheckTimer?.invalidate(); dragEndCheckTimer = nil
        animationTimer?.invalidate();    animationTimer    = nil
        animCallback = nil
    }

    deinit { cleanup() }
}
