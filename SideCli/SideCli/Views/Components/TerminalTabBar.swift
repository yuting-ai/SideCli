//
//  TerminalTabBar.swift
//  SideCli
//
//  Tab bar component for switching between terminal tabs.
//  Right-click a tab to rename it, split its focused pane, or close it.
//

import SwiftUI

// MARK: - Tab Bar

struct TerminalTabBar: View {
    @ObservedObject var manager: TerminalManager
    /// Close a tab (goes through the workspace, which asks first if a program is running).
    var onCloseTab: ((TerminalTab) -> Void)?
    /// Split the tab's focused pane (goes through the workspace, which checks it fits).
    var onSplit: ((TerminalTab, SplitAxis) -> Void)?

    @State private var hoveredTabId: UUID?
    @State private var draggingId: UUID?
    @State private var dropTargetId: UUID?
    @State private var dragOffsetX: CGFloat = 0
    @State private var tabFrames: [UUID: CGRect] = [:]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(manager.tabs) { tab in
                        TerminalTabItem(
                            tab: tab,
                            isActive: manager.activeTabId == tab.id,
                            isHovered: hoveredTabId == tab.id,
                            onRename:   { manager.renameTab(tab, to: $0) },
                            onSelect:   { manager.activateTab(tab) },
                            onClose:    { onCloseTab?(tab) },
                            onHover:    { hoveredTabId = $0 ? tab.id : nil },
                            onSplit:    { axis in onSplit?(tab, axis) },
                            onEqualize: { manager.equalizePanes(in: tab) }
                        )
                        .opacity(draggingId == tab.id ? 0.5 : 1.0)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.accentColor, lineWidth: 1.5)
                                .opacity(dropTargetId == tab.id && draggingId != tab.id ? 1 : 0)
                        )
                        .offset(x: draggingId == tab.id ? dragOffsetX : 0, y: 0)
                        .zIndex(draggingId == tab.id ? 1 : 0)
                        .background(frameReader(for: tab.id))
                        .gesture(
                            DragGesture(minimumDistance: 5, coordinateSpace: .named("tabBar"))
                                .onChanged { value in
                                    if draggingId == nil { draggingId = tab.id }
                                    guard draggingId == tab.id else { return }
                                    dragOffsetX = value.translation.width
                                    updateDropTarget(dragging: tab.id)
                                }
                                .onEnded { _ in commitDrop(from: tab.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .coordinateSpace(name: "tabBar")
            }
            .onPreferenceChange(TabFrameKey.self) { tabFrames = $0 }
        }
        .frame(height: 32)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(NSColor.separatorColor)),
            alignment: .bottom
        )
    }

    // MARK: - Drag helpers

    private func frameReader(for id: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: TabFrameKey.self,
                value: [id: geo.frame(in: .named("tabBar"))]
            )
        }
    }

    private func updateDropTarget(dragging id: UUID) {
        guard let origin = tabFrames[id] else { return }
        let centerX = origin.midX + dragOffsetX
        dropTargetId = manager.tabs.first { tab in
            guard tab.id != id, let frame = tabFrames[tab.id] else { return false }
            return centerX >= frame.minX && centerX <= frame.maxX
        }?.id
    }

    private func commitDrop(from srcId: UUID) {
        defer { draggingId = nil; dragOffsetX = 0; dropTargetId = nil }
        guard let dstId = dropTargetId,
              let from = manager.tabs.firstIndex(where: { $0.id == srcId }),
              let to   = manager.tabs.firstIndex(where: { $0.id == dstId }),
              from != to else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            manager.reorderTabs(from: from, to: to)
        }
    }
}

// MARK: - Tab Frame PreferenceKey

private struct TabFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Tab Item

struct TerminalTabItem: View {
    @AppStorage(AppPreferences.languageKey) private var appLanguageRaw = AppPreferences.languageDefault
    @ObservedObject var tab: TerminalTab  // forwards all session changes via objectWillChange
    let isActive: Bool
    let isHovered: Bool
    let onRename: (String) -> Void
    let onSelect: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void
    let onSplit: (SplitAxis) -> Void
    let onEqualize: () -> Void

    @State private var isHoveringClose = false
    @State private var isEditingTitle = false
    @State private var draftTitle = ""

    /// The tab's focused pane — updates automatically because `tab` forwards
    /// session.objectWillChange to its own objectWillChange.
    private var session: TerminalSession { tab.focusedSession }

    private var language: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .english }
    private func t(_ en: String, _ zh: String) -> String { language == .chinese ? zh : en }

    var body: some View {
        HStack(spacing: 6) {
            statusIndicator
                .allowsHitTesting(false)
            titleView
                .allowsHitTesting(isEditingTitle)
            if tab.isSplit {
                Text("\(tab.paneCount)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .help(t("\(tab.paneCount) panes", "\(tab.paneCount) 个窗格"))
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
            closeButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 120, maxWidth: 200)
        .background(
            // Gestures on the Shape instead of the HStack: RoundedRectangle fills the
            // entire frame, giving a reliable full-area hit target on macOS in ScrollView.
            // Spacer areas in the HStack have no hit area in SwiftUI macOS, so putting
            // gestures on the HStack + contentShape leaves a dead zone near the Spacer.
            // The close button (above this background) still captures its own clicks first.
            // .contentShape is required here: without it, Color.clear fill makes the
            // shape transparent to hit testing on macOS, breaking inactive tab clicks.
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .highPriorityGesture(TapGesture(count: 2).onEnded { beginRenaming() })
                .onTapGesture { onSelect() }
        )
        .cornerRadius(6)
        .contentShape(RoundedRectangle(cornerRadius: 6))  // keeps contextMenu hit area
        .onHover { onHover($0) }
        .contextMenu { contextMenuItems }
        .help(helpText)
        .onAppear { draftTitle = tab.title }
        .onChange(of: tab.title) { _, newValue in
            if !isEditingTitle { draftTitle = newValue }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(t("Rename", "重命名")) { beginRenaming() }
        Divider()
        Button(t("Split Top / Bottom", "上下分屏")) { onSplit(.vertical) }
        Button(t("Split Left / Right", "左右分屏")) { onSplit(.horizontal) }
        if tab.isSplit {
            Button(t("Equalize Panes", "均分窗格")) { onEqualize() }
        }
        Divider()
        Button(t("Close Tab", "关闭标签页")) { onClose() }
    }

    // MARK: - Subviews

    private var statusIndicator: some View {
        Group {
            switch session.state {
            case .idle:
                Circle().fill(Color.gray).frame(width: 8, height: 8)
            case .running:
                Circle().fill(Color.green).frame(width: 8, height: 8)
            case .finished(let code):
                Circle().fill(code == 0 ? Color.gray : Color.red).frame(width: 8, height: 8)
            }
        }
    }

    private var backgroundColor: Color {
        if isEditingTitle { return Color(NSColor.selectedControlColor).opacity(0.6) }
        if isActive       { return Color(NSColor.selectedControlColor) }
        else if isHovered { return Color.primary.opacity(0.08) }
        else              { return Color.clear }
    }

    private var closeButton: some View {
        Button(action: { onClose() }) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isHoveringClose ? .white : (isActive ? .primary : .secondary))
                .frame(width: 16, height: 16)
                .background(isHoveringClose ? Color.red : Color.clear)
                .cornerRadius(3)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHoveringClose = hovering }
        }
    }

    private var titleView: some View {
        Group {
            if isEditingTitle {
                TextField("", text: $draftTitle)
                    .onSubmit { commitRename() }
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    )
                    .onExitCommand { cancelRename() }
            } else {
                Text(tab.title)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(isActive ? .primary : .secondary)
            }
        }
    }

    private var helpText: String {
        let pathLine = session.currentDirectory.map { "\n\($0)" } ?? ""
        switch session.state {
        case .idle:               return "\(tab.title) - \(t("waiting to start", "等待启动"))\(pathLine)"
        case .running:            return "\(tab.title) - \(t("running", "运行中"))\(pathLine)"
        case .finished(let code): return "\(tab.title) - \(t("exited with", "已退出，代码")) \(code)\(pathLine)"
        }
    }

    private func beginRenaming() { draftTitle = tab.title; isEditingTitle = true }
    private func commitRename()  { onRename(draftTitle); isEditingTitle = false; draftTitle = tab.title }
    private func cancelRename()  { draftTitle = tab.title; isEditingTitle = false }
}

// MARK: - Preview

#Preview {
    let manager = TerminalManager()
    manager.createTab(title: "Tab 1")
    manager.createTab(title: "Tab 2")
    manager.createTab(title: "Tab 3 with a very long name")

    return TerminalTabBar(manager: manager)
        .frame(height: 100)
}
