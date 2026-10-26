//
//  TerminalPaneView.swift
//  SideCli
//
//  One terminal pane: SwiftTerm view + custom scrollbar + dim overlay. The focused
//  pane is told apart by dimming the others, not by a border.
//  The focused pane's path is shown in the panel's bottom status bar, not over
//  the terminal, so nothing ever covers the first line.
//
//  Pane views are plain AppKit views kept in SplitWorkspaceNSView's registry,
//  keyed by session id. Splitting, closing other panes or switching tabs only
//  changes their frames, so the TerminalView (and its scrollback) is never
//  recreated — which a recursive SwiftUI split view could not guarantee.
//

import AppKit
import SwiftUI
import Combine
import SwiftTerm

/// Overlay that never takes mouse events, so clicks reach the terminal below.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Pane view

final class TerminalPaneView: NSView {
    private static let scrollbarWidth: CGFloat = 14
    /// Close button size; it sits at the top of the scrollbar gutter, never over text.
    private static let closeButtonSize: CGFloat = 14
    private static let closeButtonInset: CGFloat = 5

    let session: TerminalSession
    let terminalView: EnhancedTerminalView

    private let controller: TerminalPaneController
    private let scrollState = TerminalScrollState()
    private let scrollbarHost: NSHostingView<TerminalScrollbarView>
    private let dimView = PassthroughView()
    private let closeButton = PaneCloseButton()
    /// Background-coloured patch behind the close button, from the pane's top edge to
    /// just below the button: a scrollbar a full-screen program draws in its last
    /// column then appears to start under the button instead of behind it.
    private let closeBackdrop = PassthroughView()
    /// Set by the workspace; closes this pane.
    var onClose: (() -> Void)? {
        get { closeButton.onClick }
        set { closeButton.onClick = newValue }
    }
    /// Set by the workspace; removes the pane once its shell exited cleanly.
    var onShellExit: (() -> Void)?
    private var stateObserver: AnyCancellable?
    private var isTornDown = false
    /// Extra inset for the close button on sides that touch the workspace edge, so
    /// it sits as far from the window edge as other panes' buttons sit from their
    /// divider line (which is drawn in the middle of the divider).
    private var closeButtonOffset = CGSize.zero
    private var isDark: Bool
    private var fontSize: Int

    init(session: TerminalSession, isDark: Bool, fontSize: Int) {
        self.session = session
        self.isDark = isDark
        self.fontSize = fontSize
        terminalView = EnhancedTerminalView(frame: .zero)
        controller = TerminalPaneController(session: session, scrollState: scrollState)
        scrollbarHost = NSHostingView(rootView: TerminalScrollbarView(state: scrollState, isDark: isDark))
        super.init(frame: .zero)

        wantsLayer = true
        // The terminal view hangs past the right edge (see layout()); keep it inside the pane.
        layer?.masksToBounds = true
        terminalView.terminalDelegate = controller
        terminalView.onBufferSwitch = { [weak self] in self?.needsLayout = true }
        controller.terminalView = terminalView
        terminalView.optionAsMetaKey = true // 启用 Option 键作为 Meta 键，支持 Option+Backspace 删除单词

        // Hide SwiftTerm's legacy scroller — TerminalScrollbarView replaces it.
        for subview in terminalView.subviews {
            if let scroller = subview as? NSScroller { scroller.isHidden = true; break }
        }
        scrollState.scrollAction = { [weak terminalView] position in
            terminalView?.scroll(toPosition: position)
        }
        session.setDataReceiver(owner: controller) { [weak terminalView] data in
            let bytes = [UInt8](data)
            terminalView?.feed(byteArray: bytes[...])
        }

        dimView.wantsLayer = true
        dimView.isHidden = true

        addSubview(terminalView)
        addSubview(scrollbarHost)
        addSubview(dimView)
        closeButton.isHidden = true
        closeBackdrop.wantsLayer = true
        closeBackdrop.isHidden = true
        addSubview(closeBackdrop)
        addSubview(closeButton)   // on top of the dim overlay
        applyAppearance()

        stateObserver = session.$state.dropFirst().sink { [weak self] state in
            guard case .finished(let code) = state else { return }
            // $state fires before the value is stored; act once it has settled.
            DispatchQueue.main.async { self?.shellExited(code: code) }
        }
    }

    /// `exit` (code 0) closes the pane like Terminal.app does. Any other code leaves
    /// it open with a note, so an error or a shell that can't start stays visible.
    private func shellExited(code: Int32) {
        guard !isTornDown else { return }
        if code == 0 {
            onShellExit?()
            return
        }
        let note = AppPreferences.language() == .chinese
            ? "[进程已退出，代码 \(code)。按回车重新启动，⌘W 关闭]"
            : "[Process exited with code \(code). Press Return to restart, ⌘W to close.]"
        terminalView.feed(text: "\r\n\u{1b}[0m\u{1b}[?25h\u{1b}[2m\(note)\u{1b}[0m\r\n")
    }

    /// ⌘K: drops the scrollback and clears the screen. At a shell prompt the shell
    /// redraws its prompt (Ctrl-L); full-screen programs (vim, pi…) are left alone.
    func clearScreen() {
        guard !terminalView.getTerminal().isCurrentBufferAlternate else { return }
        if session.state == .running, session.foregroundProcessName() == nil {
            terminalView.feed(text: "\u{1b}[3J")
            session.write("\u{0c}")
        } else {
            terminalView.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        // Full-screen programs (pi, vim…) run in the alternate screen, where our
        // scrollbar is hidden: they get the gutter too, so a scrollbar they draw
        // themselves sits at the pane's edge, under the close button.
        let fullScreenProgram = terminalView.getTerminal().isCurrentBufferAlternate
        scrollbarHost.isHidden = fullScreenProgram
        let trailing = fullScreenProgram ? PaneMetrics.insetTrailingFullScreen : PaneMetrics.insetTrailing
        // SwiftTerm keeps room on its right for its own scroller, which we hide. Let
        // that room hang past the pane's edge (clipped) instead of wasting ~2 columns.
        let hiddenScroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        terminalView.frame = NSRect(
            x: PaneMetrics.insetLeading,
            y: PaneMetrics.insetTop,
            width: max(0, b.width - PaneMetrics.insetLeading - trailing + hiddenScroller),
            height: max(0, b.height - PaneMetrics.insetTop - PaneMetrics.insetBottom)
        )
        // In a split the close button takes the top of the scrollbar gutter, so the
        // scrollbar starts just below it.
        let gutterTop = closeButton.isHidden ? 0 : Self.closeButtonInset + closeButtonOffset.height + Self.closeButtonSize + 3
        scrollbarHost.frame = NSRect(x: b.width - Self.scrollbarWidth, y: gutterTop,
                                     width: Self.scrollbarWidth, height: max(0, b.height - gutterTop))
        closeButton.frame = NSRect(x: b.width - Self.scrollbarWidth + (Self.scrollbarWidth - Self.closeButtonSize) / 2
                                      - closeButtonOffset.width,
                                   y: Self.closeButtonInset + closeButtonOffset.height,
                                   width: Self.closeButtonSize, height: Self.closeButtonSize)
        // Only full-screen programs reach under the button; a shell's text stops at the gutter.
        closeBackdrop.isHidden = closeButton.isHidden || !fullScreenProgram
        closeBackdrop.frame = NSRect(x: closeButton.frame.minX - 1, y: 0,
                                     width: closeButton.frame.width + 2, height: closeButton.frame.maxY + 3)
        dimView.frame = b
    }

    // MARK: Focus / dim

    /// - Parameters:
    ///   - closable: the tab is split, so this pane shows its close button.
    ///   - closeButtonOffset: how far to move the close button left / down.
    func setChrome(dimmed: Bool, closable: Bool, closeButtonOffset: CGSize = .zero) {
        dimView.isHidden = !dimmed
        if closeButton.isHidden == closable || self.closeButtonOffset != closeButtonOffset {
            closeButton.isHidden = !closable
            self.closeButtonOffset = closeButtonOffset
            needsLayout = true
        }
    }

    // MARK: Appearance

    func update(isDark: Bool, fontSize: Int) {
        guard isDark != self.isDark || fontSize != self.fontSize else { return }
        let themeChanged = isDark != self.isDark
        self.isDark = isDark
        self.fontSize = fontSize
        applyAppearance()
        if themeChanged {
            scrollbarHost.rootView = TerminalScrollbarView(state: scrollState, isDark: isDark)
        }
    }

    static func backgroundColor(isDark: Bool) -> NSColor {
        isDark ? NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.129, alpha: 1)
               : NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
    }

    private func applyAppearance() {
        terminalView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        let background = Self.backgroundColor(isDark: isDark)
        terminalView.nativeBackgroundColor = background
        terminalView.nativeForegroundColor = isDark
            ? NSColor(calibratedRed: 0.847, green: 0.847, blue: 0.847, alpha: 1)
            : NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        layer?.backgroundColor = background.cgColor
        closeBackdrop.layer?.backgroundColor = background.cgColor
        dimView.layer?.backgroundColor = background.withAlphaComponent(0.42).cgColor
    }

    /// Detach from the session before the view goes away (the session may outlive it briefly).
    func teardown() {
        isTornDown = true
        stateObserver = nil
        onShellExit = nil
        onClose = nil
        session.clearDataReceiver(owner: controller)
    }
}

// MARK: - Terminal delegate

final class TerminalPaneController: NSObject, TerminalViewDelegate {
    private let session: TerminalSession
    private let scrollState: TerminalScrollState
    weak var terminalView: TerminalView?

    private var sessionStarted = false
    private var startWorkItem: DispatchWorkItem?

    init(session: TerminalSession, scrollState: TerminalScrollState) {
        self.session = session
        self.scrollState = scrollState
        super.init()
        // 监听窗口 resize 结束通知，在松手后强制 TerminalView 全量重绘。
        // SwiftTerm 使用 Metal 渲染，在 live resize 期间渲染会被节流，
        // 且交替屏缓冲区（opencode/vim 等）的内容可能因为快速连续 resize
        // 而出现残留。松手后强制刷新一次可以确保最终状态完全正确。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLiveResizeEnd),
            name: .terminalLiveResizeDidEnd,
            object: nil
        )
    }

    deinit {
        session.clearDataReceiver(owner: self)
        NotificationCenter.default.removeObserver(self)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // The shell has exited: Return starts a new one, other keys are ignored.
        // (A program that enabled the kitty keyboard protocol may have left Return
        // encoded as CSI 13 u.)
        if case .finished = session.state {
            if data.contains(13) || data.contains(10) || Data(data).range(of: Data("\u{1b}[13".utf8)) != nil {
                session.restart()
            }
            return
        }
        let d = Data(data)
        if let s = String(data: d, encoding: .utf8), session.handleTerminalControlInput(s) { return }
        session.write(d)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // 必须立即同步 PTY 尺寸！
        // SwiftTerm 在调用此回调前已经通过 processSizeChange 将内部 grid
        // 改为了 newCols x newRows。如果 PTY 尺寸不同步，子进程（opencode）
        // 仍按旧尺寸渲染，而 SwiftTerm 按新尺寸显示 → 布局撕裂。
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

    /// 窗口 resize 结束后，强制 TerminalView 执行一次全量重绘。
    ///
    /// 原因：SwiftTerm 使用 Metal 渲染器，在 live resize 期间通过
    /// queueMetalDisplay 进行 16ms 节流渲染，部分帧可能被跳过。
    /// 对于使用交替屏缓冲区的 TUI 程序（opencode/vim/htop），
    /// 当窗口从小放大时，跳过的帧意味着程序重绘的内容没有被渲染，
    /// 导致"内容没有跟随放大"的视觉 bug。
    ///
    /// 修复：松手后通过 terminal.refresh 标记所有行为脏行，
    /// 然后触发 Metal 重绘，确保最终状态 100% 正确。
    @objc private func handleLiveResizeEnd() {
        guard let tv = terminalView else { return }
        let terminal = tv.getTerminal()
        // 标记所有行为脏行，触发全量重绘
        terminal.refresh(startRow: 0, endRow: terminal.rows - 1)
        // 同时确保 PTY 尺寸与 SwiftTerm grid 完全一致（兜底）
        session.resize(cols: terminal.cols, rows: terminal.rows)
    }

    func scrolled(source: TerminalView, position: Double) {
        // 检测交替屏幕缓冲区（Alternate Screen Buffer）状态。
        // 当 opencode / vim / htop 等工具运行时会切入交替屏，
        // 此时历史滚动缓冲区无效，强制将 thumbRatio 设为 1 使滚动条隐藏，
        // 与 macOS 原生 Terminal 行为完全一致。
        if source.terminal.isCurrentBufferAlternate {
            scrollState.update(position: 1, thumbRatio: 1)
        } else {
            scrollState.update(position: position,
                               thumbRatio: Double(source.scrollThumbsize))
        }
    }

    // SwiftTerm's parser handles OSC sequences split across PTY reads,
    // so title / cwd come from here rather than from scanning raw bytes.
    func setTerminalTitle(source: TerminalView, title: String) {
        session.applyTerminalTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        session.applyWorkingDirectory(oscURL: directory)
    }

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

// MARK: - Close button

/// Small × at the top of a pane's scrollbar gutter (split tabs only). Faint at rest,
/// a red circle on hover — the same treatment as the tab bar's close buttons.
final class PaneCloseButton: NSView {
    var onClick: (() -> Void)?
    private var isHovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = AppPreferences.language() == .chinese ? "关闭窗格（⌘W）" : "Close Pane (⌘W)"
        setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        // Refresh in case the language changed since the button was created.
        toolTip = AppPreferences.language() == .chinese ? "关闭窗格（⌘W）" : "Close Pane (⌘W)"
    }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        let inset = bounds.width * 0.32
        let path = NSBezierPath()
        path.move(to: NSPoint(x: inset, y: inset))
        path.line(to: NSPoint(x: bounds.width - inset, y: bounds.height - inset))
        path.move(to: NSPoint(x: bounds.width - inset, y: inset))
        path.line(to: NSPoint(x: inset, y: bounds.height - inset))
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        (isHovering ? NSColor.white : NSColor.secondaryLabelColor.withAlphaComponent(0.7)).setStroke()
        path.stroke()
    }
}
