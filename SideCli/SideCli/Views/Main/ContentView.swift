//
//  ContentView.swift
//  SideCli
//

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var manager = TerminalManager()
    @StateObject private var workspace = WorkspaceHandle()
    @EnvironmentObject private var panelController: PanelController
    @AppStorage(AppPreferences.languageKey) private var appLanguageRaw = AppPreferences.languageDefault
    @State private var showSettings = false
    @State private var showWelcomeSheet = !UserDefaults.standard.bool(forKey: "sidecli.hasSeenWelcome")
    @State private var showCoachMarks = false
    @State private var onboardingStepIndex = 0
    /// Overflow the user closed the banner for; it comes back if the situation changes.
    @State private var dismissedOverflow: WorkspaceHandle.Overflow?
    @State private var onboardingTargetFrames: [OnboardingTarget: CGRect] = [:]

    private var activeTabIsSplit: Bool { manager.activeTab?.isSplit ?? false }
    private var activeTabIsZoomed: Bool { manager.activeTab?.zoomedSessionID != nil }
    /// The tab bar only appears with two or more tabs ("+" always lives in the toolbar).
    private var showsTabBar: Bool { manager.tabs.count > 1 }
    private var isOnboardingVisible: Bool { showWelcomeSheet || showCoachMarks }
    private var language: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .english }
    private func t(_ en: String, _ zh: String) -> String {
        language == .chinese ? zh : en
    }
    private var onboardingSteps: [OnboardingStep] {
        [
            OnboardingStep(
                target: .drag,
                title: t("Drag & Snap", "拖拽与吸附"),
                description: t("Press and hold the left mouse button on the top drag area to move SideCli. You can place it anywhere, and when released near the left or right screen edge it snaps into place.",
                               "在顶部拖拽区域按住鼠标左键可移动 SideCli。你可以将它放到任意位置，靠近屏幕左侧或右侧释放时会自动吸附。")
            ),
            OnboardingStep(
                target: .resize,
                title: t("Resize Window", "调整窗口大小"),
                description: t("Drag the bottom edge to adjust height, the side edge to adjust width, or the corner to resize both at once.",
                               "拖拽底边可调整高度，拖拽侧边可调整宽度，拖拽角落可同时调整两者。")
            ),
            OnboardingStep(
                target: .split,
                title: t("Split Panes", "分屏"),
                description: t("Split the current pane top / bottom or left / right. ⌘D picks the direction with more room. Left / right splits widen the panel automatically.",
                               "把当前窗格上下或左右切开。⌘D 会自动选择空间更充裕的方向；左右分屏时面板会自动加宽。")
            ),
            OnboardingStep(
                target: .theme,
                title: t("Theme Toggle", "主题切换"),
                description: t("Switch between dark and light theme for better readability.",
                               "在深色和浅色主题之间切换，提升可读性。")
            ),
            OnboardingStep(
                target: .settings,
                title: t("Settings", "设置"),
                description: t("Customize shortcuts, font size, and view About information.",
                               "你可以自定义快捷键、字体大小，并查看关于信息。")
            ),
            OnboardingStep(
                target: .pin,
                title: t("Pin Window", "固定窗口"),
                description: t("Pin SideCli to prevent auto-hide while you work.",
                               "固定 SideCli，工作时可避免自动隐藏。")
            )
        ]
    }

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                toolbarView
                if showsTabBar {
                    TerminalTabBar(
                        manager: manager,
                        onCloseTab: { workspace.closeTab($0) },
                        onSplit: { tab, axis in
                            manager.activateTab(tab)
                            workspace.split(.axis(axis))
                        }
                    )
                }
                TerminalContainerView(
                    manager: manager,
                    workspace: workspace,
                    panelController: panelController,
                    isDark: panelController.isDarkTheme,
                    fontSize: panelController.fontSize
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { overflowBanner }
                .overlay(alignment: .bottom) { toastView }
                .animation(.easeOut(duration: 0.18), value: workspace.toast)
                // Path of the focused pane. Lives below the terminals so it never
                // covers output; the resize strip sits on its bottom edge.
                statusBar
                    .overlay(alignment: .bottom) {
                        BottomResizeHandle()
                            .captureOnboardingTarget(.resize)
                    }
            }
            .background(Color(NSColor.windowBackgroundColor))
            .ignoresSafeArea(.container, edges: .bottom)

            // When snapped left, this side is glued to the screen edge; the native
            // right border handles width instead.
            if panelController.snappedEdge != .left {
                ResizeHandle()
            }

            if showCoachMarks {
                OnboardingCoachMarksView(
                    stepIndex: onboardingStepIndex,
                    steps: onboardingSteps,
                    targetFrame: onboardingTargetFrames[onboardingSteps[onboardingStepIndex].target],
                    onNext: advanceOnboarding,
                    onBack: backOnboarding,
                    onSkip: finishOnboarding
                )
            }
        }
        .coordinateSpace(name: "onboardingSpace")
        .onPreferenceChange(OnboardingTargetFramePreferenceKey.self) { frames in
            onboardingTargetFrames = frames
        }
        .preferredColorScheme(panelController.isDarkTheme ? .dark : .light)
        .background(appShortcuts)
        .onReceive(NotificationCenter.default.publisher(for: .appCommand)) { note in
            if let box = note.object as? AppCommand.CommandBox { perform(box.command) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveSessionState)) { _ in
            manager.saveNow()
        }
        .onAppear {
            if isOnboardingVisible {
                panelController.setOnboardingActive(true)
            }
            if showWelcomeSheet {
                onboardingStepIndex = 0
            }
        }
        .onChange(of: showWelcomeSheet) { _, _ in
            panelController.setOnboardingActive(isOnboardingVisible)
        }
        .onChange(of: showCoachMarks) { _, _ in
            panelController.setOnboardingActive(isOnboardingVisible)
        }
        .onChange(of: showSettings) { _, active in
            panelController.setSheetPresented(active)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(panelController: panelController)
        }
        .sheet(isPresented: $showWelcomeSheet, onDismiss: {
            UserDefaults.standard.set(true, forKey: "sidecli.hasSeenWelcome")
        }) {
            WelcomeView {
                startCoachMarks()
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    private var appShortcuts: some View {
        Group {
            shortcut("t") { perform(.newTab) }
            // ⌘W closes the focused pane; the last pane of a tab closes the tab.
            shortcut("w") { perform(.closePane) }
            shortcut("+") { perform(.fontBigger) }
            // ⌘= is what users actually press on US layouts ("+" needs Shift).
            shortcut("=") { perform(.fontBigger) }
            shortcut("-") { perform(.fontSmaller) }
            shortcut("0") { perform(.fontReset) }
            shortcut("d") { perform(.split(.auto)) }
            shortcut("d", [.command, .shift]) { perform(.split(.opposite)) }
            shortcut(.return, [.command, .shift]) { perform(.toggleZoom) }
            shortcut(.leftArrow, [.command, .option]) { perform(.moveFocus(.left)) }
            shortcut(.rightArrow, [.command, .option]) { perform(.moveFocus(.right)) }
            shortcut(.upArrow, [.command, .option]) { perform(.moveFocus(.up)) }
            shortcut(.downArrow, [.command, .option]) { perform(.moveFocus(.down)) }
            shortcut("k") { perform(.clearScreen) }
            shortcut(",") { perform(.showSettings) }
            // Also while docked, when SideCli isn't the active app and its menu bar isn't shown.
            shortcut("q") { NSApp.terminate(nil) }
            // ⌘⇧] / ⌘⇧[ — some layouts report the shifted character instead.
            shortcut("]", [.command, .shift]) { perform(.nextTab) }
            shortcut("}", [.command, .shift]) { perform(.nextTab) }
            shortcut("[", [.command, .shift]) { perform(.previousTab) }
            shortcut("{", [.command, .shift]) { perform(.previousTab) }
            ForEach(1...9, id: \.self) { number in
                shortcut(KeyEquivalent(Character(String(number)))) { perform(.selectTab(number)) }
            }
        }
        .frame(width: 0, height: 0)
        .hidden()
    }

    private func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers = .command,
                          action: @escaping () -> Void) -> some View {
        Button("", action: action).keyboardShortcut(key, modifiers: modifiers)
    }

    /// Runs a command from a shortcut, the toolbar, the menu bar or the status-bar menu.
    private func perform(_ command: AppCommand) {
        switch command {
        case .newTab:               manager.createTab()
        case .closePane:            workspace.closeFocusedPane()
        case .split(let mode):      workspace.split(mode)
        case .toggleZoom:           workspace.toggleZoom()
        case .equalize:             workspace.equalize()
        case .moveFocus(let to):    workspace.moveFocus(to)
        case .selectTab(let number):
            // ⌘9 is always the last tab, as in browsers.
            let index = number == 9 ? manager.tabs.count - 1 : number - 1
            if manager.tabs.indices.contains(index) { manager.activateTab(manager.tabs[index]) }
        case .nextTab:              cycleTab(by: 1)
        case .previousTab:          cycleTab(by: -1)
        case .fontBigger:           panelController.updateFontSize(panelController.fontSize + 1)
        case .fontSmaller:          panelController.updateFontSize(panelController.fontSize - 1)
        case .fontReset:            panelController.resetFontSize()
        case .clearScreen:          workspace.clearFocusedPane()
        case .toggleTheme:          panelController.toggleTheme()
        case .showSettings:         showSettings = true
        }
    }

    private func cycleTab(by step: Int) {
        let tabs = manager.tabs
        guard tabs.count > 1, let current = tabs.firstIndex(where: { $0.id == manager.activeTabId }) else { return }
        manager.activateTab(tabs[(current + step + tabs.count) % tabs.count])
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        // A narrow panel gets the pane and theme buttons in a "⋯" menu; otherwise the
        // toolbar would be wider than the panel and push the whole layout off its edges.
        ViewThatFits(in: .horizontal) {
            toolbarRow(compact: false)
            toolbarRow(compact: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // The toolbar's empty space acts as a title bar: drag to move, double-click
        // to zoom. The buttons sit on top and keep their own clicks.
        .background(
            PanelDragHandle(onDoubleClick: { panelController.titleBarDoubleClicked() })
                .captureOnboardingTarget(.drag)
        )
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(NSColor.separatorColor)),
                 alignment: .bottom)
    }

    private func toolbarRow(compact: Bool) -> some View {
        HStack(spacing: 0) {
            // Window buttons, like a regular macOS window: hide / minimize to Dock / fill screen.
            TrafficLights(
                isMaximized: panelController.isMaximized,
                closeHelp: t("Hide SideCli (⌘` or the Dock icon brings it back)", "隐藏 SideCli（按 ⌘` 或点 Dock 图标唤回）"),
                minimizeHelp: t("Minimize to Dock", "最小化到 Dock"),
                zoomHelp: panelController.isMaximized ? t("Restore Size", "还原大小") : t("Fill Screen", "铺满屏幕"),
                onClose: { panelController.hideWindow() },
                onMinimize: { panelController.minimizeToDock() },
                onZoom: { panelController.toggleMaximize() }
            )

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                iconButton("plus", help: t("New Tab (⌘T)", "新建标签页（⌘T）")) { perform(.newTab) }

                if compact {
                    moreMenu
                } else {
                    HStack(spacing: 2) {
                        paneButton(.splitVertical, help: t("Split Top / Bottom (⌘D picks a direction automatically)", "上下分屏（⌘D 自动选方向）")) {
                            perform(.split(.axis(.vertical)))
                        }
                        paneButton(.splitHorizontal, help: t("Split Left / Right", "左右分屏")) {
                            perform(.split(.axis(.horizontal)))
                        }
                    }
                    .captureOnboardingTarget(.split)
                    paneButton(.zoom, isActive: activeTabIsZoomed, isEnabled: activeTabIsSplit,
                               help: activeTabIsZoomed ? t("Restore Layout (⌘⇧↩)", "还原布局（⌘⇧↩）") : t("Zoom Pane (⌘⇧↩)", "放大当前窗格（⌘⇧↩）")) {
                        perform(.toggleZoom)
                    }
                    paneButton(.equalize, isEnabled: activeTabIsSplit, help: t("Equalize Panes", "均分窗格")) {
                        perform(.equalize)
                    }

                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, 4)

                    iconButton(panelController.isDarkTheme ? "moon.fill" : "sun.max.fill",
                               help: panelController.isDarkTheme ? t("Switch to Light Theme", "切换为浅色主题") : t("Switch to Dark Theme", "切换为深色主题")) {
                        perform(.toggleTheme)
                    }
                    .captureOnboardingTarget(.theme)
                }

                iconButton("gearshape", help: t("Settings (⌘,)", "设置（⌘,）")) { perform(.showSettings) }
                    .captureOnboardingTarget(.settings)

                iconButton(panelController.isPinned ? "pin.fill" : "pin",
                           tint: panelController.isPinned ? .accentColor : .secondary,
                           help: !panelController.isDocked
                               ? t("Auto-hide only applies when SideCli is docked to a screen edge", "仅在吸附到屏幕边缘时才会自动隐藏")
                               : panelController.isPinned ? t("Unpin (allow auto-hide)", "取消固定（允许自动隐藏）") : t("Pin (prevent auto-hide)", "固定（阻止自动隐藏）")) {
                    panelController.togglePin()
                }
                // Auto-hide only exists while docked to a screen edge.
                .disabled(!panelController.isDocked)
                .opacity(panelController.isDocked ? 1 : 0.4)
                .captureOnboardingTarget(.pin)
            }
        }
    }

    /// The pane and theme buttons, for a panel too narrow to show them all.
    private var moreMenu: some View {
        Menu {
            Button(t("Split Top / Bottom", "上下分屏")) { perform(.split(.axis(.vertical))) }
            Button(t("Split Left / Right", "左右分屏")) { perform(.split(.axis(.horizontal))) }
            Divider()
            Button(activeTabIsZoomed ? t("Restore Layout", "还原布局") : t("Zoom Pane", "放大当前窗格")) { perform(.toggleZoom) }
                .disabled(!activeTabIsSplit)
            Button(t("Equalize Panes", "均分窗格")) { perform(.equalize) }
                .disabled(!activeTabIsSplit)
            Divider()
            Button(panelController.isDarkTheme ? t("Switch to Light Theme", "切换为浅色主题") : t("Switch to Dark Theme", "切换为深色主题")) {
                perform(.toggleTheme)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(t("More", "更多"))
    }

    private func iconButton(_ systemName: String, tint: Color = .secondary, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarButtonStyle())
        .help(help)
    }

    private func paneButton(_ kind: PaneGlyphKind, isActive: Bool = false, isEnabled: Bool = true,
                            help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PaneGlyph(kind: kind, size: 15)
                .foregroundColor(isActive ? .accentColor : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
    }

    // MARK: - Status bar

    @State private var showCopiedPath = false

    private var statusBar: some View {
        let session = manager.activeTab?.focusedSession
        let displayPath = session.map { $0.currentDirectory ?? $0.title } ?? ""
        let rawPath = session.flatMap { $0.currentDirectoryRawPath ?? $0.startingDirectory } ?? NSHomeDirectory()
        return HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(displayPath)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(rawPath)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rawPath, forType: .string)
                withAnimation(.easeInOut(duration: 0.12)) { showCopiedPath = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeInOut(duration: 0.12)) { showCopiedPath = false }
                }
            } label: {
                Image(systemName: showCopiedPath ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(showCopiedPath ? .green : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ToolbarButtonStyle())
            .help(showCopiedPath ? t("Copied!", "已复制") : t("Copy Path", "复制路径"))

            Spacer(minLength: 8)

            if activeTabIsZoomed {
                Text(t("Zoomed", "已放大"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.bottom, 2)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(NSColor.separatorColor)), alignment: .top)
    }

    // MARK: - Workspace feedback

    @ViewBuilder
    private var toastView: some View {
        if let toast = workspace.toast {
            Text(toast.message)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(toast.isWarning ? Color.orange.opacity(0.95) : Color.black.opacity(0.78))
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .id(toast.id)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var overflowBanner: some View {
        if let overflow = workspace.overflow, overflow != dismissedOverflow {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(t("Not enough room for this layout (needs \(Int(overflow.needed.width.rounded(.up)))×\(Int(overflow.needed.height.rounded(.up))), has \(Int(overflow.available.width))×\(Int(overflow.available.height))). Showing the current pane only; the layout comes back when the panel is big enough.",
                       "空间不足：这个布局至少需要 \(Int(overflow.needed.width.rounded(.up)))×\(Int(overflow.needed.height.rounded(.up)))，现在只有 \(Int(overflow.available.width))×\(Int(overflow.available.height))。已临时只显示当前窗格，面板够大后会自动恢复。"))
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(t("Resize Panel to Fit", "调整面板到刚好放下")) {
                    panelController.growToFit(contentNeeded: overflow.needed, contentAvailable: overflow.available)
                }
                .controlSize(.small)
                Button(action: { dismissedOverflow = overflow }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t("Hide this notice", "关闭提示"))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            )
            .padding(10)
        }
    }

    private func advanceOnboarding() {
        if onboardingStepIndex < onboardingSteps.count - 1 {
            onboardingStepIndex += 1
        } else {
            finishOnboarding()
        }
    }

    private func backOnboarding() {
        onboardingStepIndex = max(0, onboardingStepIndex - 1)
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "sidecli.hasSeenWelcome")
        showCoachMarks = false
    }

    private func startCoachMarks() {
        showWelcomeSheet = false
        showCoachMarks = true
        onboardingStepIndex = 0
    }
}

// MARK: - Bottom Resize Handle

/// 5 pt resize strip along the status bar's bottom edge; drag down to grow, up to shrink.
private struct BottomResizeHandle: View {
    @EnvironmentObject private var panelController: PanelController
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartHeight: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(maxWidth: .infinity)
            .frame(height: 5)
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(isHovering || isDragging ? 0.22 : 0))
                    .frame(height: 2)
                    .animation(.easeInOut(duration: 0.15), value: isHovering || isDragging),
                alignment: .bottom
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else if !isDragging {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartHeight = panelController.panelHeight
                        }
                        panelController.resizeHeight(to: dragStartHeight + value.translation.height)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragStartHeight = 0
                        panelController.commitResize()
                        // 通知终端强制全量重绘，确保 TUI 程序（opencode 等）
                        // 在窗口放大后内容能正确跟随。
                        NotificationCenter.default.post(name: .terminalLiveResizeDidEnd, object: nil)
                        if !isHovering { NSCursor.pop() }
                    }
            )
    }
}

// MARK: - Left Resize Handle

/// 8 pt left-edge resize strip; shows a 2 pt highlight line on hover.
private struct ResizeHandle: View {
    @EnvironmentObject private var panelController: PanelController
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat = 0
    @State private var dragStartMouseX: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(isHovering || isDragging ? 0.25 : 0))
                    .frame(width: 2)
                    .animation(.easeInOut(duration: 0.15), value: isHovering || isDragging),
                alignment: .leading
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else if !isDragging {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        // Measure in screen coordinates: this handle moves with the
                        // window's left edge, so a window-relative translation would
                        // cancel itself out while the panel grows to the left.
                        let mouseX = NSEvent.mouseLocation.x
                        if !isDragging {
                            isDragging = true
                            dragStartWidth = panelController.currentPanelWidth
                            // Window hasn't moved yet, so the first translation is exact;
                            // back it out to recover where the press started.
                            dragStartMouseX = mouseX - value.translation.width
                        }
                        // Handle is on the left side: dragging left increases width.
                        panelController.resize(to: dragStartWidth - (mouseX - dragStartMouseX))
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragStartWidth = 0
                        panelController.commitResize()
                        // 通知终端强制全量重绘，确保 TUI 程序（opencode 等）
                        // 在窗口放大后内容能正确跟随。
                        NotificationCenter.default.post(name: .terminalLiveResizeDidEnd, object: nil)
                        if !isHovering { NSCursor.pop() }
                    }
            )
            .onDisappear {
                if isHovering || isDragging { NSCursor.pop() }
            }
    }
}

// MARK: - Panel Drag Handle
//
// Direct port of SidePeek's WindowDragHandle / DragHandleView.
// Full XY movement — EdgeSnapManager handles snapping to left/right edge after drag ends.

struct PanelDragHandle: NSViewRepresentable {
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> DragHandleView {
        let view = DragHandleView()
        view.onDoubleClick = onDoubleClick
        return view
    }
    func updateNSView(_ nsView: DragHandleView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

class DragHandleView: NSView {
    var onDoubleClick: (() -> Void)?
    private var isDragging = false
    private var dragStartScreenLocation: NSPoint = .zero
    private var windowStartLocation: NSPoint = .zero

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var acceptsFirstResponder: Bool { true }

    // Clicks reach the toolbar even while another app is active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window = self.window else { return }
        if event.clickCount == 2 {
            isDragging = false
            onDoubleClick?()
            return
        }
        isDragging = true
        dragStartScreenLocation = NSEvent.mouseLocation
        windowStartLocation = window.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let window = self.window else { return }
        let cur = NSEvent.mouseLocation
        let deltaX = cur.x - dragStartScreenLocation.x
        let deltaY = cur.y - dragStartScreenLocation.y
        window.setFrameOrigin(NSPoint(x: windowStartLocation.x + deltaX,
                                      y: windowStartLocation.y + deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(PanelController())
        .frame(width: 440, height: 700)
}

// MARK: - Window buttons

/// Red / yellow / green buttons drawn like the system ones (12 pt, glyphs on hover).
/// The panel is borderless, so the standard titlebar buttons aren't available.
private struct TrafficLights: View {
    let isMaximized: Bool
    let closeHelp: String
    let minimizeHelp: String
    let zoomHelp: String
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            light(color: Color(red: 1.0, green: 0.373, blue: 0.341), glyph: "xmark", help: closeHelp, action: onClose)
            light(color: Color(red: 0.996, green: 0.737, blue: 0.180), glyph: "minus", help: minimizeHelp, action: onMinimize)
            light(color: Color(red: 0.157, green: 0.784, blue: 0.251),
                  glyph: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                  help: zoomHelp, action: onZoom)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private func light(color: Color, glyph: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
                .overlay {
                    if isHovering {
                        Image(systemName: glyph)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(Color.black.opacity(0.55))
                    }
                }
                .frame(width: 12, height: 12)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}


// MARK: - Toolbar button style

/// Plain icon button with a soft rounded highlight on hover and press, shared by
/// the toolbar buttons so they all react the same way.
struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.14 : isHovering ? 0.08 : 0))
                )
                .onHover { isHovering = $0 }
        }
    }
}
