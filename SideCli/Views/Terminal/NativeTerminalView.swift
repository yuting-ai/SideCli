//
//  NativeTerminalView.swift
//  SideCli
//
//  Native terminal view powered by SwiftTerm.
//

import SwiftUI
import SwiftTerm
import AppKit
import Combine

// MARK: - Scroll State

final class TerminalScrollState: ObservableObject {
    /// 0 = at top (oldest history), 1 = at bottom (latest output).
    @Published private(set) var position: Double = 0
    /// Visible rows / total rows (including scrollback).
    @Published private(set) var thumbRatio: Double = 1

    /// Scrollbar is visible whenever there is scrollback content — same as a web page.
    var hasScrollback: Bool { thumbRatio < 0.999 }

    /// Set by NativeTerminalView; called by the scrollbar to drive SwiftTerm.
    var scrollAction: ((Double) -> Void)?

    func update(position: Double, thumbRatio: Double) {
        self.position = position
        self.thumbRatio = max(0.05, min(1, thumbRatio))
    }
}

// MARK: - Scrollbar View

/// Web-style scrollbar:
///   • Visible whenever there is scrollback content.
///   • Click anywhere on the track  → jump to that position.
///   • Drag the knob                → scroll to the dragged position.
struct TerminalScrollbarView: View {
    @ObservedObject var state: TerminalScrollState
    var isDark: Bool

    @State private var isDragging       = false
    @State private var isHoveringKnob   = false
    @State private var isHoveringTrack  = false
    @State private var isScrollActive   = false
    @State private var dragStartY: CGFloat  = 0
    @State private var dragStartPos: Double = 0
    @State private var fadeOutWorkItem: DispatchWorkItem? = nil

    private var trackFill: SwiftUI.Color {
        isDark ? SwiftUI.Color.white.opacity(0.07) : SwiftUI.Color.black.opacity(0.05)
    }
    private var knobFill: SwiftUI.Color {
        let a = isDragging ? 0.65 : (isHoveringKnob ? 0.55 : 0.40)
        return isDark ? SwiftUI.Color.white.opacity(a) : SwiftUI.Color.black.opacity(a)
    }

    private var isCurrentlyVisible: Bool {
        state.hasScrollback && (isScrollActive || isDragging || isHoveringTrack)
    }

    private func triggerScrollActive() {
        fadeOutWorkItem?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            isScrollActive = true
        }
        
        let item = DispatchWorkItem {
            if !isDragging && !isHoveringTrack {
                withAnimation(.easeIn(duration: 0.25)) {
                    isScrollActive = false
                }
            }
        }
        fadeOutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    var body: some View {
        GeometryReader { geo in
            let vpad: CGFloat = 3            // vertical padding inside track
            let trackH = max(0, geo.size.height - vpad * 2)
            let knobH  = max(20, trackH * state.thumbRatio)
            let travel = max(1, trackH - knobH)
            // position 0 = top → knob at top  |  position 1 = bottom → knob at bottom
            let knobTop = vpad + state.position * travel
            let cx = geo.size.width / 2      // horizontal centre of the track

            ZStack {
                // ── Track background (click anywhere to jump) ──────────────────
                RoundedRectangle(cornerRadius: 4)
                    .fill(trackFill)
                    .padding(.vertical, vpad)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("track"))
                            .onEnded { v in
                                guard travel > 0 else { return }
                                // Centre the knob on the tap/click point.
                                let tapped = min(max(v.location.y - knobH / 2, vpad), vpad + travel)
                                state.scrollAction?((tapped - vpad) / travel)
                                triggerScrollActive()
                             }
                    )

                // ── Draggable knob ─────────────────────────────────────────────
                // Use .position() so the hit-area moves with the visual.
                RoundedRectangle(cornerRadius: 3)
                    .fill(knobFill)
                    .frame(width: 7, height: knobH)
                    .position(x: cx, y: knobTop + knobH / 2)
                    .onHover { isHoveringKnob = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("track"))
                            .onChanged { v in
                                if !isDragging {
                                    isDragging     = true
                                    dragStartY     = v.startLocation.y
                                    dragStartPos   = state.position
                                }
                                guard travel > 0 else { return }
                                let originTop = vpad + dragStartPos * travel
                                let newTop    = min(max(originTop + v.location.y - dragStartY, vpad), vpad + travel)
                                state.scrollAction?((newTop - vpad) / travel)
                            }
                            .onEnded { _ in
                                isDragging = false
                                triggerScrollActive()
                            }
                    )
            }
        }
        .coordinateSpace(name: "track")
        .frame(width: 14)
        .opacity(isCurrentlyVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isCurrentlyVisible)
        .onHover { hovering in
            isHoveringTrack = hovering
            if hovering {
                fadeOutWorkItem?.cancel()
                withAnimation(.easeOut(duration: 0.15)) {
                    isScrollActive = true
                }
            } else {
                triggerScrollActive()
            }
        }
        .onReceive(state.$position) { _ in
            triggerScrollActive()
        }
    }
}

// MARK: - NativeTerminalView

struct NativeTerminalView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    var isDark: Bool
    var fontSize: Int
    var isVisible: Bool
    var scrollState: TerminalScrollState

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv

        applyAppearance(to: tv)

        // Hide SwiftTerm's legacy scroller — TerminalScrollbarView replaces it.
        for subview in tv.subviews {
            if let sc = subview as? NSScroller { sc.isHidden = true; break }
        }

        // Wire the scrollbar's drag/tap action to SwiftTerm's scroll API.
        scrollState.scrollAction = { [weak tv] position in
            tv?.scroll(toPosition: position)
        }

        session.onDataReceived = { [weak tv] data in
            let bytes = [UInt8](data)
            tv?.feed(byteArray: bytes[...])
        }

        return tv
    }

    func updateNSView(_ tv: TerminalView, context: Context) {
        let coord = context.coordinator

        if isVisible && !coord.wasVisible {
            tv.window?.makeFirstResponder(tv)
        }
        coord.wasVisible = isVisible

        if coord.isDark != isDark || coord.fontSize != fontSize {
            coord.isDark  = isDark
            coord.fontSize = fontSize
            applyAppearance(to: tv)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, scrollState: scrollState,
                    isDark: isDark, fontSize: fontSize, isVisible: isVisible)
    }

    private func applyAppearance(to tv: TerminalView) {
        tv.font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        if isDark {
            tv.nativeBackgroundColor = NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.129, alpha: 1)
            tv.nativeForegroundColor = NSColor(calibratedRed: 0.847, green: 0.847, blue: 0.847, alpha: 1)
        } else {
            tv.nativeBackgroundColor = NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
            tv.nativeForegroundColor = NSColor(calibratedRed: 0.1,  green: 0.1,  blue: 0.1,  alpha: 1)
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, TerminalViewDelegate {
        private let session: TerminalSession
        private let scrollState: TerminalScrollState
        weak var terminalView: TerminalView?
        var wasVisible: Bool
        var isDark: Bool
        var fontSize: Int

        private var sessionStarted = false
        private var startWorkItem: DispatchWorkItem?

        init(session: TerminalSession, scrollState: TerminalScrollState,
             isDark: Bool, fontSize: Int, isVisible: Bool) {
            self.session     = session
            self.scrollState = scrollState
            self.isDark      = isDark
            self.fontSize    = fontSize
            self.wasVisible  = isVisible
        }

        deinit { session.onDataReceived = nil }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let d = Data(data)
            if let s = String(data: d, encoding: .utf8), session.handleTerminalControlInput(s) { return }
            session.write(d)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.resize(cols: newCols, rows: newRows)
            guard !sessionStarted, newCols > 2, newRows > 1 else { return }
            startWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.sessionStarted else { return }
                self.sessionStarted = true
                self.session.start()
            }
            startWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        }

        func scrolled(source: TerminalView, position: Double) {
            scrollState.update(position: position,
                               thumbRatio: Double(source.scrollThumbsize))
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func bell(source: TerminalView) { NSSound.beep() }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
