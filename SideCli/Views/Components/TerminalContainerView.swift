//
//  TerminalContainerView.swift
//  SideCli
//
//  Container view for displaying terminal tabs.
//  Each tab renders one or two panes (left / right split) with a draggable divider.
//
//  SwiftTerm TerminalView identity is preserved across split changes by:
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
    @AppStorage(AppPreferences.languageKey) private var appLanguageRaw = AppPreferences.languageDefault
    private var language: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .english }
    private func t(_ en: String, _ zh: String) -> String { language == .chinese ? zh : en }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(t("No Active Terminal", "当前无活动终端"))
                .font(.title2)
                .foregroundColor(.secondary)
            Text(t("Click + or press ⌘T to open a new terminal", "点击 + 或按 ⌘T 打开新终端"))
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

    private var terminalBgColor: Color {
        if isDark {
            return Color(NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.129, alpha: 1))
        } else {
            return Color(NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.98, alpha: 1))
        }
    }

    var body: some View {
        let dividerActive = index > 0 && tab.isSplit
        HStack(spacing: 0) {
            // Divider is always at position 0 in this HStack (0-width for left pane,
            // draggable for right pane) so the VStack stays at position 1 and the
            // underlying SwiftTerm TerminalView is never recreated on split state changes.
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
                // Path header — shown in both split and single-pane modes.
                SplitPaneHeader(session: session, showCloseButton: tab.isSplit, onClose: onClose)
                    .frame(height: 26)
                    .clipped()

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
        .background(terminalBgColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Draggable Divider (NSViewRepresentable)
//
// Using AppKit directly instead of SwiftUI gestures because:
// 1. NSTrackingArea gives reliable cursor changes next to Metal-rendered views.
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
    // arrives, completely bypassing the normal hit-test/dispatch chain. The
    // terminal view never sees these events, so dragging in either direction works
    // regardless of which view the cursor passes over. This is the same pattern
    // AppKit itself uses for NSSlider, NSSplitView dividers, etc.

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
    @AppStorage(AppPreferences.languageKey) private var appLanguageRaw = AppPreferences.languageDefault
    @ObservedObject var session: TerminalSession
    let showCloseButton: Bool
    let onClose: () -> Void

    @State private var isHoveringClose = false
    @State private var isHoveringHeader = false
    @State private var isHoveringCopy = false
    @State private var showCopiedCheckmark = false

    private var language: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .english }
    private func t(_ en: String, _ zh: String) -> String { language == .chinese ? zh : en }

    private var displayText: String {
        session.currentDirectory ?? session.title
    }

    private var pathToCopy: String {
        session.currentDirectoryRawPath ?? session.startingDirectory ?? NSHomeDirectory()
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pathToCopy, forType: .string)
        withAnimation(.easeInOut(duration: 0.12)) {
            showCopiedCheckmark = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.12)) {
                showCopiedCheckmark = false
            }
        }
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

            if isHoveringHeader || showCopiedCheckmark {
                Button(action: copyPath) {
                    Image(systemName: showCopiedCheckmark ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(showCopiedCheckmark ? .green : (isHoveringCopy ? .primary : .secondary))
                        .frame(width: 16, height: 16)
                        .background(isHoveringCopy ? Color.primary.opacity(0.08) : Color.clear)
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringCopy = hovering
                }
                .help(showCopiedCheckmark ? t("Copied!", "已复制") : t("Copy Path", "复制路径"))
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            if showCloseButton {
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHoveringHeader = hovering
            }
        }
    }
}

// MARK: - Single Pane

struct SingleTerminalView: View {
    @ObservedObject var session: TerminalSession
    let isVisible: Bool
    let isDark: Bool
    let fontSize: Int
    @StateObject private var scrollState = TerminalScrollState()

    private var terminalBgColor: Color {
        if isDark {
            return Color(NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.129, alpha: 1))
        } else {
            return Color(NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.98, alpha: 1))
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NativeTerminalView(
                session: session,
                isDark: isDark,
                fontSize: fontSize,
                isVisible: isVisible,
                scrollState: scrollState
            )
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TerminalScrollbarView(state: scrollState, isDark: isDark)
        }
        .background(terminalBgColor)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    // NativeTerminalView uses Metal which is unavailable in Xcode Previews.
    // Show a placeholder so the preview canvas stays usable.
    ZStack {
        Color(NSColor.windowBackgroundColor)
        VStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Terminal (Metal — run app to preview)")
                .foregroundColor(.secondary)
        }
    }
    .frame(width: 800, height: 600)
}
