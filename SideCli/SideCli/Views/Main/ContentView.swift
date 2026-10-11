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
    /// The tab bar only appears with two or more tabs; until then "+" lives in the toolbar.
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
                title: t("Pin Window", "窗口置顶"),
                description: t("Pin SideCli to prevent auto-hide while you work.",
                               "将 SideCli 置顶，工作时可避免自动隐藏。")
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
                        onNewTab: { manager.createTab() },
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
                BottomResizeHandle()
                    .captureOnboardingTarget(.resize)
            }
            .background(Color(NSColor.windowBackgroundColor))
            .ignoresSafeArea(.container, edges: .bottom)

            // When snapped left, this side is glued to the screen edge; the native
            // right border handles width instead.
            if panelController.snappedEdge != .left {
                ResizeHandle()
            }

            VStack {
                PanelDragHandle()
                    .frame(height: 20)
                    .frame(maxWidth: .infinity)
                    .captureOnboardingTarget(.drag)
                Spacer()
            }
            .allowsHitTesting(true)

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
        .onReceive(NotificationCenter.default.publisher(for: .createNewTerminal)) { _ in
            manager.createTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeActiveTerminal)) { _ in
            manager.closeFocusedPane()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveSessionState)) { _ in
            manager.saveSessionState()
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
            Button("") { manager.createTab() }
                .keyboardShortcut("t", modifiers: .command)
            // ⌘W closes the focused pane; the last pane of a tab closes the tab.
            Button("") { workspace.closeFocusedPane() }
                .keyboardShortcut("w", modifiers: .command)
            Button("") { panelController.updateFontSize(panelController.fontSize + 1) }
                .keyboardShortcut("+", modifiers: .command)
            // ⌘= is what users actually press on US layouts ("+" needs Shift).
            Button("") { panelController.updateFontSize(panelController.fontSize + 1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { panelController.updateFontSize(panelController.fontSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { workspace.split(.auto) }
                .keyboardShortcut("d", modifiers: .command)
            Button("") { workspace.split(.opposite) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("") { workspace.toggleZoom() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("") { workspace.moveFocus(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("") { workspace.moveFocus(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("") { workspace.moveFocus(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("") { workspace.moveFocus(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        .frame(width: 0, height: 0)
        .hidden()
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        HStack(spacing: 0) {
            // Logo lockup: the app icon (same in both themes) + a monospaced wordmark
            // that follows the theme (light text on dark, dark text on light).
            HStack(spacing: 9) {
                Image("LogoMark")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text("SideCli")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .kerning(-0.3)
                    .foregroundColor(.primary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                if !showsTabBar {
                    Button(action: { manager.createTab() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help(t("New Tab (⌘T)", "新建标签页（⌘T）"))
                }

                HStack(spacing: 2) {
                    paneButton(.splitVertical, help: t("Split Top / Bottom (⌘D picks a direction automatically)", "上下分屏（⌘D 自动选方向）")) {
                        workspace.split(.axis(.vertical))
                    }
                    paneButton(.splitHorizontal, help: t("Split Left / Right", "左右分屏")) {
                        workspace.split(.axis(.horizontal))
                    }
                }
                .captureOnboardingTarget(.split)

                paneButton(.zoom, isActive: activeTabIsZoomed, isEnabled: activeTabIsSplit,
                           help: activeTabIsZoomed ? t("Restore Layout (⌘⇧↩)", "还原布局（⌘⇧↩）") : t("Zoom Pane (⌘⇧↩)", "放大当前窗格（⌘⇧↩）")) {
                    workspace.toggleZoom()
                }
                paneButton(.equalize, isEnabled: activeTabIsSplit, help: t("Equalize Panes", "均分窗格")) {
                    workspace.equalize()
                }

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 4)

                Button(action: { panelController.toggleTheme() }) {
                    Image(systemName: panelController.isDarkTheme ? "moon.fill" : "sun.max.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help(panelController.isDarkTheme ? t("Switch to Light Theme", "切换为浅色主题") : t("Switch to Dark Theme", "切换为深色主题"))
                .captureOnboardingTarget(.theme)

                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help(t("Settings", "设置"))
                .captureOnboardingTarget(.settings)

                Button(action: { panelController.togglePin() }) {
                    Image(systemName: panelController.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(panelController.isPinned ? .accentColor : .secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help(panelController.isPinned ? t("Unpin (allow auto-hide)", "取消置顶（允许自动隐藏）") : t("Pin (prevent auto-hide)", "置顶（阻止自动隐藏）"))
                .captureOnboardingTarget(.pin)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(NSColor.separatorColor)),
                 alignment: .bottom)
    }

    private func paneButton(_ kind: PaneGlyphKind, isActive: Bool = false, isEnabled: Bool = true,
                            help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PaneGlyph(kind: kind, size: 15)
                .foregroundColor(isActive ? .accentColor : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(help)
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

/// 8 pt bottom resize strip; drag down to increase height, drag up to decrease.
private struct BottomResizeHandle: View {
    @EnvironmentObject private var panelController: PanelController
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartHeight: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(maxWidth: .infinity)
            .frame(height: 8)
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
    func makeNSView(context: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_ nsView: DragHandleView, context: Context) {}
}

class DragHandleView: NSView {
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

    override func mouseDown(with event: NSEvent) {
        guard let window = self.window else { return }
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
