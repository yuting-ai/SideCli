//
//  TerminalPaneView.swift
//  SideCli
//
//  One terminal pane: SwiftTerm view + custom scrollbar + a path header that
//  slides in when the mouse reaches the top edge + focus ring / dim overlay.
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

// MARK: - Shared chrome state (read by the SwiftUI header)

final class PaneChromeState: ObservableObject {
    @Published var isMultiPane = false
    @Published var isZoomed = false
}

struct PaneActions {
    var splitVertical: () -> Void
    var splitHorizontal: () -> Void
    var toggleZoom: () -> Void
    var close: () -> Void
}

/// Overlay that never takes mouse events, so clicks reach the terminal below.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Pane view

final class TerminalPaneView: NSView {
    static let headerHeight: CGFloat = 26
    private static let scrollbarWidth: CGFloat = 14

    let session: TerminalSession
    let terminalView: EnhancedTerminalView
    let chrome = PaneChromeState()

    private let controller: TerminalPaneController
    private let scrollState = TerminalScrollState()
    private let scrollbarHost: NSHostingView<TerminalScrollbarView>
    private let headerHost: NSHostingView<PaneHeaderView>
    private let dimView = PassthroughView()
    private let focusRing = PassthroughView()
    private var headerTracking: NSTrackingArea?
    private var wantsHeader = false
    private var isDark: Bool
    private var fontSize: Int

    init(session: TerminalSession, isDark: Bool, fontSize: Int, actions: PaneActions) {
        self.session = session
        self.isDark = isDark
        self.fontSize = fontSize
        terminalView = EnhancedTerminalView(frame: .zero)
        controller = TerminalPaneController(session: session, scrollState: scrollState)
        scrollbarHost = NSHostingView(rootView: TerminalScrollbarView(state: scrollState, isDark: isDark))
        headerHost = NSHostingView(rootView: PaneHeaderView(session: session, chrome: chrome, actions: actions))
        super.init(frame: .zero)

        wantsLayer = true
        terminalView.terminalDelegate = controller
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
        focusRing.wantsLayer = true
        focusRing.layer?.borderWidth = 1.5
        dimView.isHidden = true
        focusRing.isHidden = true
        headerHost.alphaValue = 0
        headerHost.isHidden = true

        addSubview(terminalView)
        addSubview(scrollbarHost)
        addSubview(dimView)
        addSubview(focusRing)
        addSubview(headerHost)
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        terminalView.frame = NSRect(
            x: PaneMetrics.insetLeading,
            y: PaneMetrics.insetTop,
            width: max(0, b.width - PaneMetrics.insetLeading - PaneMetrics.insetTrailing),
            height: max(0, b.height - PaneMetrics.insetTop - PaneMetrics.insetBottom)
        )
        scrollbarHost.frame = NSRect(x: b.width - Self.scrollbarWidth, y: 0, width: Self.scrollbarWidth, height: b.height)
        dimView.frame = b
        focusRing.frame = b
        headerHost.frame = NSRect(x: 0, y: 0, width: b.width, height: Self.headerHeight)
    }

    // MARK: Header (shown while the mouse is at the pane's top edge)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let headerTracking { removeTrackingArea(headerTracking) }
        let zone = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight + 4)
        let area = NSTrackingArea(rect: zone, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        headerTracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHeaderVisible(true) }
    override func mouseExited(with event: NSEvent) { setHeaderVisible(false) }

    private func setHeaderVisible(_ visible: Bool) {
        wantsHeader = visible
        if visible { headerHost.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            headerHost.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            // Fully hide once faded out, so the invisible header can't eat clicks.
            guard let self, !self.wantsHeader else { return }
            self.headerHost.isHidden = true
        })
    }

    // MARK: Focus / dim / chrome

    func setChrome(focused: Bool, dimmed: Bool, multiPane: Bool, zoomed: Bool) {
        focusRing.isHidden = !focused
        dimView.isHidden = !dimmed
        if chrome.isMultiPane != multiPane || chrome.isZoomed != zoomed {
            // Called from layout(); publish outside the current view update.
            DispatchQueue.main.async { [chrome] in
                if chrome.isMultiPane != multiPane { chrome.isMultiPane = multiPane }
                if chrome.isZoomed != zoomed { chrome.isZoomed = zoomed }
            }
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
        dimView.layer?.backgroundColor = background.withAlphaComponent(0.42).cgColor
        focusRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    /// Detach from the session before the view goes away (the session may outlive it briefly).
    func teardown() {
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

// MARK: - Pane header (SwiftUI)

struct PaneHeaderView: View {
    @AppStorage(AppPreferences.languageKey) private var appLanguageRaw = AppPreferences.languageDefault
    @ObservedObject var session: TerminalSession
    @ObservedObject var chrome: PaneChromeState
    let actions: PaneActions

    @State private var hovered: String?
    @State private var showCopiedCheckmark = false

    private var language: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .english }
    private func t(_ en: String, _ zh: String) -> String { language == .chinese ? zh : en }

    private var displayText: String { session.currentDirectory ?? session.title }
    private var pathToCopy: String {
        session.currentDirectoryRawPath ?? session.startingDirectory ?? NSHomeDirectory()
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pathToCopy, forType: .string)
        withAnimation(.easeInOut(duration: 0.12)) { showCopiedCheckmark = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.12)) { showCopiedCheckmark = false }
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

            Button(action: copyPath) {
                Image(systemName: showCopiedCheckmark ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(showCopiedCheckmark ? .green : (hovered == "copy" ? .primary : .secondary))
                    .frame(width: 18, height: 18)
                    .background(hovered == "copy" ? Color.primary.opacity(0.08) : Color.clear)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .onHover { setHovered("copy", $0) }
            .help(showCopiedCheckmark ? t("Copied!", "已复制") : t("Copy Path", "复制路径"))

            Spacer(minLength: 0)

            glyphButton("split-v", .splitVertical, t("Split Top / Bottom", "上下分屏"), actions.splitVertical)
            glyphButton("split-h", .splitHorizontal, t("Split Left / Right", "左右分屏"), actions.splitHorizontal)
            if chrome.isMultiPane {
                glyphButton("zoom", .zoom,
                            chrome.isZoomed ? t("Restore Layout (⌘⇧↩)", "还原布局（⌘⇧↩）") : t("Zoom Pane (⌘⇧↩)", "放大窗格（⌘⇧↩）"),
                            actions.toggleZoom)
            }
            Button(action: actions.close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(hovered == "close" ? .white : .secondary)
                    .frame(width: 18, height: 18)
                    .background(hovered == "close" ? Color.red : Color.clear)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .onHover { setHovered("close", $0) }
            .help(chrome.isMultiPane ? t("Close Pane (⌘W)", "关闭窗格（⌘W）") : t("Close Tab (⌘W)", "关闭标签页（⌘W）"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque: it sits on top of the terminal's first line.
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(NSColor.separatorColor)),
            alignment: .bottom
        )
    }

    /// Exit events can arrive after the next button's enter; only clear our own id.
    private func setHovered(_ id: String, _ isHovering: Bool) {
        if isHovering { hovered = id } else if hovered == id { hovered = nil }
    }

    private func glyphButton(_ id: String, _ kind: PaneGlyphKind, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PaneGlyph(kind: kind, size: 12)
                .foregroundColor(hovered == id ? .primary : .secondary)
                .frame(width: 18, height: 18)
                .background(hovered == id ? Color.primary.opacity(0.08) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { setHovered(id, $0) }
        .help(help)
    }
}
