//
//  TerminalTabBar.swift
//  SideCli
//
//  Tab bar component for switching between terminal tabs.
//  Right-click a tab to split it into two side-by-side panes.
//

import SwiftUI

// MARK: - Tab Bar

struct TerminalTabBar: View {
    @ObservedObject var manager: TerminalManager
    var onNewTab: (() -> Void)?

    @State private var hoveredTabId: UUID?
    @State private var isHoveringNewButton = false
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
                            allTabs: manager.tabs,
                            onRename:     { manager.renameTab(tab, to: $0) },
                            onSelect:     { manager.activateTab(tab) },
                            onClose:      { manager.closeTab(tab) },
                            onHover:      { hoveredTabId = $0 ? tab.id : nil },
                            onSplit:      { dir in manager.addSplitPane(to: tab, startingDirectory: dir) },
                            onCloseSplit: { manager.closeSplitPane(of: tab) }
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

            Button(action: { onNewTab?() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isHoveringNewButton ? .white : .secondary)
                    .frame(width: 24, height: 24)
                    .background(isHoveringNewButton ? Color.blue : Color.clear)
                    .cornerRadius(4)
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHoveringNewButton = hovering }
            }
            .padding(.trailing, 8)
            .help("New Terminal (⌘T)")

            Spacer()
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
    @ObservedObject var tab: TerminalTab  // forwards all session changes via objectWillChange
    let isActive: Bool
    let isHovered: Bool
    let allTabs: [TerminalTab]
    let onRename: (String) -> Void
    let onSelect: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void
    let onSplit: (String?) -> Void
    let onCloseSplit: () -> Void

    @State private var isHoveringClose = false
    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @State private var showCloseConfirmation = false
    @AppStorage(AppPreferences.warnOnCloseWithRunningProcessKey)
    private var warnOnCloseWithRunningProcess = AppPreferences.warnOnCloseWithRunningProcessDefault

    /// Always points to the current primary session — updates automatically
    /// because `tab` forwards session.objectWillChange to its own objectWillChange.
    private var session: TerminalSession { tab.primarySession }

    var body: some View {
        HStack(spacing: 6) {
            statusIndicator
            titleView
            if tab.isSplit {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            closeButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 120, maxWidth: 200)
        .background(backgroundColor)
        .cornerRadius(6)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .highPriorityGesture(TapGesture(count: 2).onEnded { beginRenaming() })
        .onTapGesture { onSelect() }
        .onHover { onHover($0) }
        .contextMenu { contextMenuItems }
        .help(helpText)
        .alert("Close Terminal?", isPresented: $showCloseConfirmation) {
            Button("Close", role: .destructive) { onClose() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Close \"\(session.title)\"? Any running process in this terminal will be terminated.")
        }
        .onAppear { draftTitle = session.title }
        .onChange(of: tab.primarySession.title) { _, newValue in
            if !isEditingTitle { draftTitle = newValue }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Rename") { beginRenaming() }
        Divider()

        if tab.isSplit {
            Button("Close Split") { onCloseSplit() }
        } else {
            Menu("Split Right") {
                Button("New Terminal") { onSplit(nil) }
                let tabsWithDir = allTabs.filter { $0.primarySession.currentDirectoryRawPath != nil }
                if !tabsWithDir.isEmpty {
                    Divider()
                    ForEach(tabsWithDir) { t in
                        Button(t.id == tab.id ? "\(t.title) (this tab)" : t.title) {
                            onSplit(t.primarySession.currentDirectoryRawPath)
                        }
                    }
                }
            }
        }
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
        else if isHovered { return Color(NSColor.controlColor).opacity(0.5) }
        else              { return Color.clear }
    }

    private var closeButton: some View {
        Button(action: {
            if warnOnCloseWithRunningProcess && session.hasForegroundTask() {
                showCloseConfirmation = true
            } else {
                onClose()
            }
        }) {
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
                TextField("", text: $draftTitle, onCommit: commitRename)
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
                Text(session.title)
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
        case .idle:               return "\(session.title) - waiting to start\(pathLine)"
        case .running:            return "\(session.title) - running\(pathLine)"
        case .finished(let code): return "\(session.title) - exited with \(code)\(pathLine)"
        }
    }

    private func beginRenaming() { draftTitle = session.title; isEditingTitle = true }
    private func commitRename()  { onRename(draftTitle); isEditingTitle = false; draftTitle = session.title }
    private func cancelRename()  { draftTitle = session.title; isEditingTitle = false }
}

// MARK: - Preview

#Preview {
    let manager = TerminalManager()
    manager.createTab(title: "Tab 1")
    manager.createTab(title: "Tab 2")
    manager.createTab(title: "Tab 3 with a very long name")

    return TerminalTabBar(manager: manager) {
        print("New tab requested")
    }
    .frame(height: 100)
}
