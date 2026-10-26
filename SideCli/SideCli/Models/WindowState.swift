//
//  WindowState.swift
//  SideCli
//
//  Where the panel was when SideCli last ran, so it comes back the same way:
//  docked to an edge, a regular window at its own position, or filling the screen.
//  (Docked width / height / y are kept by PanelController under their own keys.)
//

import AppKit

enum WindowState {
    private static let floatingKey = "sidecli.isFloating"
    private static let frameKey = "sidecli.panelFrame"
    private static let maximizedKey = "sidecli.isMaximized"
    private static let frameBeforeMaximizeKey = "sidecli.frameBeforeMaximize"

    /// How the panel is placed at launch.
    enum Placement {
        case docked
        /// A regular window at this frame.
        case floating(NSRect)
        /// Filling the screen; `edge` is set when it was filled from a docked panel,
        /// `before` is where the green button restores it to.
        case maximized(NSRect, before: NSRect?, edge: Edge?)
    }

    /// Decided once by PanelController before the panel is created; EdgeSnapManager
    /// reads it to know whether to snap the new panel to its edge.
    static var launchPlacement: Placement = .docked

    static func savedPlacement() -> Placement {
        let defaults = UserDefaults.standard
        // A frame on a monitor that is no longer attached falls back to docking.
        guard let frame = rect(frameKey).flatMap(onScreen) else { return .docked }
        if defaults.bool(forKey: maximizedKey) {
            let edge = defaults.bool(forKey: floatingKey) ? nil : EdgeSnapManager.savedEdge()
            return .maximized(frame, before: rect(frameBeforeMaximizeKey).flatMap(onScreen), edge: edge)
        }
        return defaults.bool(forKey: floatingKey) ? .floating(frame) : .docked
    }

    static func save(frame: NSRect?, isFloating: Bool, isMaximized: Bool, frameBeforeMaximize: NSRect?) {
        let defaults = UserDefaults.standard
        defaults.set(isFloating, forKey: floatingKey)
        defaults.set(isMaximized, forKey: maximizedKey)
        if let frame { defaults.set(NSStringFromRect(frame), forKey: frameKey) }
        defaults.set(frameBeforeMaximize.map(NSStringFromRect), forKey: frameBeforeMaximizeKey)
    }

    private static func rect(_ key: String) -> NSRect? {
        UserDefaults.standard.string(forKey: key).map(NSRectFromString).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `frame` moved fully onto the screen it mostly overlaps, shrunk to fit if that
    /// screen is smaller; nil when it no longer overlaps any screen.
    private static func onScreen(_ frame: NSRect) -> NSRect? {
        let area = { (r: NSRect) in r.width * r.height }
        guard let screen = NSScreen.screens.max(by: {
            area($0.visibleFrame.intersection(frame)) < area($1.visibleFrame.intersection(frame))
        }), area(screen.visibleFrame.intersection(frame)) > 0 else { return nil }
        let vf = screen.visibleFrame
        var fitted = frame
        fitted.size.width = max(300, min(frame.width, vf.width))
        fitted.size.height = max(200, min(frame.height, vf.height))
        fitted.origin.x = max(vf.minX, min(frame.minX, vf.maxX - fitted.width))
        fitted.origin.y = max(vf.minY, min(frame.minY, vf.maxY - fitted.height))
        return fitted
    }
}
