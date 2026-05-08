//
//  TerminalContainerView.swift
//  SideCli
//
//  Container view for displaying terminal tabs.
//  Each tab renders one or two panes (left / right split) with a draggable divider.
//
//  WKWebView identity is preserved across split changes by:
//  1. ForEach(tab.sessions, id: \.id) — SwiftUI tracks panes by session ID, not position.
//  2. SplitDivider is always at position 0 inside SplitPaneView's HStack (0-width when
//     inactive), so the terminal VStack stays at position 1 and is never recreated.
//

import SwiftUI

// MARK: - Container

struct TerminalContainerView: View {
    @ObservedObject var manager: TerminalManager
    @EnvironmentObject private var panelController: PanelController

    var body: some View {
        ZStack {
            if manager.tabs.isEmpty {
                EmptyTerminalView()
            } else {
                ForEach(manager.tabs) { tab in
                    TabContentView(
                        tab: tab,
                        isVisible: manager.activeTabId == tab.id,
                        isDark: panelController.isDarkTheme,
                        fontSize: panelController.fontSize,
                        onClose: { index in manager.closePane(at: index, of: tab) }
                    )
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - Empty State

struct EmptyTerminalView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Active Terminal")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Click + or press ⌘T to open a new terminal")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Tab Content

struct TabContentView: View {
    @ObservedObject var tab: TerminalTab
    let isVisible: Bool
    let isDark: Bool
    let fontSize: Int
    let onClose: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(tab.sessions.enumerated()), id: \.element.id) { index, session in
                    let leftPaneWidth = max(geo.size.width * tab.splitRatio - SplitDivider.width / 2, 0)
                    SplitPaneView(
                        tab: tab,
                        session: session,
                        index: index,
                        totalWidth: geo.size.width,
                        isVisible: isVisible,
                        isDark: isDark,
                        fontSize: fontSize,
                        onClose: { onClose(index) }
                    )
                    // Use explicit width for the left pane so drag works in both directions.
                    // maxWidth only limits growth and can make right-drag appear stuck.
                    .frame(width: (tab.isSplit && index == 0) ? leftPaneWidth : nil)
                }
            }
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Split Pane

struct SplitPaneView: View {
    @ObservedObject var tab: TerminalTab
    @ObservedObject var session: TerminalSession
    let index: Int
    let totalWidth: CGFloat
    let isVisible: Bool
    let isDark: Bool
    let fontSize: Int
    let onClose: () -> Void

    var body: some View {
        let dividerActive = index > 0 && tab.isSplit
        HStack(spacing: 0) {
            // Divider is always at position 0 in this HStack (0-width for left pane,
            // draggable for right pane) so the VStack stays at position 1 and the
            // underlying WKWebView is never recreated on split state changes.
            SplitDivider(
                isActive: dividerActive,
                ratio: $tab.splitRatio,
                totalWidth: totalWidth
            )
            // Explicit frame is required: NSViewRepresentable without a frame takes
            // an arbitrary SwiftUI-assigned width, which shifts the terminal sideways
            // in single-pane mode. Clamping to 0 when inactive prevents this.
            .frame(width: dividerActive ? SplitDivider.width : 0)
            .clipped()

            VStack(spacing: 0) {
                // Path header — 0-height in single-pane mode.
                SplitPaneHeader(session: session, onClose: onClose)
                    .frame(height: tab.isSplit ? 26 : 0)
                    .clipped()
                    .animation(.easeInOut(duration: 0.15), value: tab.isSplit)

                SingleTerminalView(
                    session: session,
                    isVisible: isVisible,
                    isDark: isDark,
                    fontSize: fontSize
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Draggable Divider (NSViewRepresentable)
//
// Using AppKit directly instead of SwiftUI gestures because:
// 1. NSTrackingArea gives reliable cursor changes next to WKWebViews.
// 2. mouseDragged events continue to fire even when the cursor leaves the
//    divider bounds, so dragging right (into the left pane) works correctly.

struct SplitDivider: NSViewRepresentable {
    // Interaction hot zone: ~5px on each side of the center line.
    // This makes hover/click much easier and matches user expectation.
    static let width: CGFloat = 10

    let isActive: Bool
    @Binding var ratio: CGFloat
    let totalWidth: CGFloat

    func makeNSView(context: Context) -> DividerNSView { DividerNSView() }

    func updateNSView(_ view: DividerNSView, context: Context) {
        view.isActive = isActive
        view.onDelta = { [totalWidth] pixelDelta in
            let newRatio = ratio + pixelDelta / max(totalWidth, 1)
            ratio = min(max(newRatio, 0.2), 0.8)
        }
    }
}

final class DividerNSView: NSView {

    var isActive = false {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Called with the incremental horizontal pixel movement on each drag tick.
    var onDelta: ((CGFloat) -> Void)?

    private var isDragging = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        window?.invalidateCursorRects(for: self)
    }

    override func removeFromSuperview() { super.removeFromSuperview() }

    // Backup: also register a cursor rect so the cursor still flips correctly
    // even when cursorUpdate notifications haven't fired yet.
    override func resetCursorRects() {
        if isActive {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }

    // MARK: Drag — synchronous modal event tracking.
    //
    // window.nextEvent(matching:) blocks the run loop until the matching event
    // arrives, completely bypassing the normal hit-test/dispatch chain. WKWebView
    // never sees these events, so dragging in either direction works regardless
    // of which view the cursor passes over. This is the same pattern AppKit
    // itself uses for NSSlider, NSSplitView dividers, etc.

    override func mouseDown(with event: NSEvent) {
        guard isActive, let win = window else { return }
        isDragging = true
        needsDisplay = true
        var lastX = event.locationInWindow.x

        // Keep resize cursor visible during drag.
        NSCursor.resizeLeftRight.set()

        var tracking = true
        while tracking, let next = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch next.type {
            case .leftMouseDragged:
                let x = next.locationInWindow.x
                onDelta?(x - lastX)
                lastX = x
                NSCursor.resizeLeftRight.set()
            case .leftMouseUp:
                tracking = false
            default:
                break
            }
        }

        isDragging = false
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isActive else { return }
        (isDragging ? NSColor.controlAccentColor : NSColor.separatorColor).setFill()
        NSRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height).fill()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Pane Header

struct SplitPaneHeader: View {
    @ObservedObject var session: TerminalSession
    let onClose: () -> Void

    @State private var isHoveringClose = false

    private var displayText: String {
        session.currentDirectory ?? session.title
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Text(displayText)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.secondary)

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isHoveringClose ? .white : .secondary)
                    .frame(width: 16, height: 16)
                    .background(isHoveringClose ? Color.red : Color.clear)
                    .cornerRadius(3)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) { isHoveringClose = hovering }
            }
            .padding(.trailing, 6)
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(NSColor.separatorColor)),
            alignment: .bottom
        )
    }
}

// MARK: - Single Pane

struct SingleTerminalView: View {
    @ObservedObject var session: TerminalSession
    let isVisible: Bool
    let isDark: Bool
    let fontSize: Int

    var body: some View {
        TerminalWebView(
            session: session,
            onReady: nil,
            isDark: isDark,
            fontSize: fontSize
        )
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    let manager = TerminalManager()
    return TerminalContainerView(manager: manager)
        .environmentObject(PanelController())
        .frame(width: 800, height: 600)
}
