//
//  ContentView.swift
//  SideCli
//

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var manager = TerminalManager()
    @EnvironmentObject private var panelController: PanelController
    @AppStorage(AppPreferences.languageKey) private var appLanguageRaw = AppPreferences.languageDefault
    @State private var showSettings = false
    @State private var showWelcomeSheet = !UserDefaults.standard.bool(forKey: "sidecli.hasSeenWelcome")
    @State private var showCoachMarks = false
    @State private var showSplitWarning = false
    @State private var onboardingStepIndex = 0
    @State private var onboardingTargetFrames: [OnboardingTarget: CGRect] = [:]

    private var activeTabIsSplit: Bool { manager.activeTab?.isSplit ?? false }
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
                target: .split,
                title: t("Split Pane", "分栏"),
                description: t("Split the current tab into two panes so you can run commands side by side.",
                               "将当前标签页拆分为两个窗格，便于并排执行命令。")
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
                description: t("Customize shortcuts, font size, close confirmations, and view About information.",
                               "你可以自定义快捷键、字体大小、关闭确认，并查看关于信息。")
            ),
            OnboardingStep(
                target: .pin,
                title: t("Pin Window", "窗口置顶"),
                description: t("Pin SideCli to prevent auto-hide while you work.",
                               "将 SideCli 置顶，工作时可避免自动隐藏。")
            )
        ]
    }

    private func splitCurrentTab() {
        guard let tab = manager.activeTab else { return }
        if tab.isSplit {
            showSplitWarning = true
        } else {
            manager.addSplitPane(to: tab, startingDirectory: tab.primarySession.currentDirectoryRawPath)
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                toolbarView
                TerminalTabBar(manager: manager, onNewTab: { manager.createTab() })
                TerminalContainerView(manager: manager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BottomResizeHandle()
            }
            .background(Color(NSColor.windowBackgroundColor))
            .ignoresSafeArea(.container, edges: .bottom)

            ResizeHandle()

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
        .onAppear {
            setupNotifications()
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
        .sheet(isPresented: $showSettings) {
            SettingsView(panelController: panelController)
        }
        .sheet(isPresented: $showWelcomeSheet) {
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
            Button("") { manager.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
            Button("") { manager.nextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("") { manager.previousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("") { panelController.updateFontSize(panelController.fontSize + 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("") { panelController.updateFontSize(panelController.fontSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { splitCurrentTab() }
                .keyboardShortcut("d", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .hidden()
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("SideCli")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Text(toolbarSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                Button(action: splitCurrentTab) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(activeTabIsSplit ? .accentColor : .secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help(activeTabIsSplit ? t("Already split (⌘D)", "已经分栏（⌘D）") : t("Split Terminal (⌘D)", "分割终端（⌘D）"))
                .captureOnboardingTarget(.split)
                .popover(isPresented: $showSplitWarning, arrowEdge: .bottom) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text(t("This tab is already split.\nClose the current split first.",
                               "这个标签页已分栏。\n请先关闭当前分栏。"))
                            .font(.system(size: 12))
                            .fixedSize()
                    }
                    .padding(12)
                }

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

    private var toolbarSubtitle: String {
        guard let active = manager.activeSession else { return t("No active session", "当前无活动会话") }
        switch active.state {
        case .idle:             return "\(active.title) · \(t("starting", "启动中"))"
        case .running:          return "\(active.title) · \(t("active session", "活动会话"))"
        case .finished(let c):  return "\(active.title) · \(t("exited with", "已退出，代码")) \(c)"
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .createNewTerminal, object: nil, queue: .main
        ) { [weak manager] _ in manager?.createTab() }

        NotificationCenter.default.addObserver(
            forName: .closeActiveTerminal, object: nil, queue: .main
        ) { [weak manager] _ in manager?.closeActiveTab() }

        NotificationCenter.default.addObserver(
            forName: .saveSessionState, object: nil, queue: .main
        ) { [weak manager] _ in manager?.saveSessionState() }
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
                        if !isDragging {
                            isDragging = true
                            dragStartWidth = panelController.panelWidth
                        }
                        // Panel is on the right edge: dragging left (negative width) increases panel width.
                        panelController.resize(to: dragStartWidth - value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragStartWidth = 0
                        panelController.commitResize()
                        if !isHovering { NSCursor.pop() }
                    }
            )
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
