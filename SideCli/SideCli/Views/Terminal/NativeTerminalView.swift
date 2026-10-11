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

    /// Set by TerminalPaneView; called by the scrollbar to drive SwiftTerm.
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

// MARK: - EnhancedTerminalView

class EnhancedTerminalView: TerminalView {
    
    @objc override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        
        // 1. Try to read file URLs FIRST (e.g. from dragging/copying files in Finder)
        // This is crucial because Finder often puts a TIFF icon on the pasteboard alongside the file URL.
        var filePaths: [String] = []
        if let items = pb.pasteboardItems {
            for item in items {
                if let urlString = item.string(forType: .fileURL),
                   let url = URL(string: urlString),
                   url.isFileURL {
                    filePaths.append(escapeFilePath(url.path))
                }
            }
        }
        
        if !filePaths.isEmpty {
            let pathsString = " " + filePaths.joined(separator: " ") + " "
            sendStringToTerminal(pathsString)
            return
        }
        
        // 2. Text wins over images. Word / Excel / Keynote / Notes put a PNG/TIFF
        //    preview next to the copied text; pasting that as an image path is wrong.
        //    Exception: a lone URL usually accompanies "Copy Image" in a browser.
        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isLoneWebURL(text) {
            super.paste(sender as Any)
            return
        }

        // 3. Try to read raw image data (e.g. from screenshot or "Copy Image" in browser)
        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil {
            let pasteDir = Self.pasteDirectory
            try? FileManager.default.createDirectory(at: pasteDir, withIntermediateDirectories: true)
            Self.removeStalePastes(in: pasteDir)
            let fileName = "SideCli_paste_\(UUID().uuidString).png"
            let fileURL = pasteDir.appendingPathComponent(fileName)

            var saved = false
            if let tiffData = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiffData), let pngData = rep.representation(using: .png, properties: [:]) {
                do {
                    try pngData.write(to: fileURL)
                    saved = true
                } catch { print("Failed to write TIFF->PNG: \(error)") }
            } else if let pngData = pb.data(forType: .png) {
                do {
                    try pngData.write(to: fileURL)
                    saved = true
                } catch { print("Failed to write PNG: \(error)") }
            }
            
            if saved {
                let pathString = " " + escapeFilePath(fileURL.path) + " "
                sendStringToTerminal(pathString)
                return
            }
        }
        
        // 4. Fallback to default SwiftTerm text paste
        super.paste(sender as Any)
    }

    /// Pasted images live in their own folder so they can be cleaned up without
    /// touching anything else in the temp directory.
    private static let pasteDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SideCli-pastes", isDirectory: true)

    /// The pasted path is consumed by whatever runs in the shell (e.g. an AI CLI
    /// reading the image), possibly a while later, so only drop files older than a day.
    private static func removeStalePastes(in directory: URL) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: directory,
                                                          includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            for file in files where file.lastPathComponent.hasPrefix("SideCli_paste_") {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    private func isLoneWebURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func escapeFilePath(_ path: String) -> String {
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    
    private func sendStringToTerminal(_ string: String) {
        guard let delegate = terminalDelegate else { return }
        let bytes = Array(string.utf8)
        delegate.send(source: self, data: bytes[...])
    }
}

// MARK: - Notification Name

extension Notification.Name {
    /// 由 FloatingPanel 在 windowDidEndLiveResize 时广播，
    /// 触发所有 TerminalPaneController 强制全量重绘 + 补发精准 resize。
    static let terminalLiveResizeDidEnd = Notification.Name("com.sidecli.terminalLiveResizeDidEnd")
}

