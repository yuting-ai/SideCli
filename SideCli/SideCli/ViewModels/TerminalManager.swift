//
//  TerminalManager.swift
//  SideCli
//
//  Manager for terminal tabs. Each tab owns a split tree of sessions.
//  Geometry-dependent decisions (which way to split, whether a split fits)
//  live in SplitWorkspaceNSView; this type only edits the model.
//

import Foundation
import Combine
import SwiftUI
import TelemetryDeck

class TerminalManager: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var activeTabId: UUID?

    private var cancellables: Set<AnyCancellable> = []
    private var tabCounter: Int = 0
    /// Forwards the active tab's objectWillChange to manager, so views
    /// observing manager (e.g. ContentView) re-render when its panes change.
    private var activeTabCancellable: AnyCancellable?

    // Keep the same UserDefaults key so existing saved state is preserved.
    private static let savedTabsKey = "sidecli.savedSessions"

    indirect enum SavedPane: Codable {
        case pane(directory: String?, title: String)
        case split(axis: SplitAxis, ratio: Double, first: SavedPane, second: SavedPane)
    }

    struct SavedTab: Codable {
        let title: String
        let userRenamed: Bool
        // Added later — optional so state saved by older versions still decodes.
        var directory: String?
        var isSplit: Bool?
        var splitDirectory: String?
        var splitRatio: Double?
        var isActive: Bool?
        /// Full split tree (current format). When absent, the legacy fields above apply.
        var layout: SavedPane?
        var focusedPaneIndex: Int?
    }

    // MARK: - Convenience

    var activeTab: TerminalTab? {
        guard let id = activeTabId else { return nil }
        return tabs.first { $0.id == id }
    }

    var activeSession: TerminalSession? { activeTab?.focusedSession }
    var hasActiveSession: Bool { activeTabId != nil }
    var sessionCountText: String { "\(tabs.count) tab\(tabs.count == 1 ? "" : "s")" }

    var runningCount: Int {
        allSessions.filter { if case .running = $0.state { return true }; return false }.count
    }

    var finishedCount: Int {
        allSessions.filter { if case .finished = $0.state { return true }; return false }.count
    }

    private var allSessions: [TerminalSession] {
        tabs.flatMap(\.sessions)
    }

    // MARK: - Init

    init() {
        if !restoreTabs() {
            createTab()
        }
    }

    // MARK: - Tab Lifecycle

    @discardableResult
    func createTab(title: String? = nil, startingDirectory: String? = nil) -> TerminalTab {
        tabCounter += 1
        let defaultTitle = title ?? "Terminal \(tabCounter)"
        let session = TerminalSession(title: defaultTitle, startingDirectory: startingDirectory)
        let tab = TerminalTab(session: session)

        tabs.append(tab)
        activateTab(tab)

        TelemetryDeck.signal("tab.created", parameters: ["totalTabs": "\(tabs.count)"])
        return tab
    }

    func activateTab(_ tab: TerminalTab) {
        activeTabId = tab.id
        // Re-subscribe so any change inside the active tab (panes, focus, title…)
        // also triggers a manager publish → ContentView re-renders.
        activeTabCancellable = tab.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    func activateTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activateTab(tab)
    }

    func closeTab(_ tab: TerminalTab) {
        tab.sessions.forEach { $0.terminate() }
        tabs.removeAll { $0.id == tab.id }

        // Go through activateTab so activeTabCancellable follows the new tab;
        // otherwise it keeps forwarding the closed tab and the toolbar goes stale.
        if tab.id == activeTabId, let last = tabs.last {
            activateTab(last)
        }

        if tabs.isEmpty { createTab() }
    }

    func closeTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        closeTab(tab)
    }

    func closeActiveTab() {
        guard let tab = activeTab else { return }
        closeTab(tab)
    }

    func closeAllTabs() {
        tabs.forEach { $0.sessions.forEach { $0.terminate() } }
        tabs.removeAll()
        activeTabId = nil
        createTab()
    }

    func renameTab(_ tab: TerminalTab, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tab.customTitle = trimmed
    }

    // MARK: - Navigation

    func nextTab() {
        guard let currentId = activeTabId,
              let idx = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        activateTab(tabs[(idx + 1) % tabs.count])
    }

    func previousTab() {
        guard let currentId = activeTabId,
              let idx = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        activateTab(tabs[(idx - 1 + tabs.count) % tabs.count])
    }

    func reorderTabs(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              (0..<tabs.count).contains(fromIndex),
              (0..<tabs.count).contains(toIndex) else { return }
        tabs.move(fromOffsets: IndexSet(integer: fromIndex),
                  toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
    }

    // MARK: - Panes

    /// Splits the given pane; the new shell starts in that pane's directory and gets focus.
    /// Callers check first that the result fits (SplitWorkspaceNSView.split).
    @discardableResult
    func splitPane(_ sessionID: UUID, in tab: TerminalTab, axis: SplitAxis) -> TerminalSession? {
        guard let target = tab.sessions.first(where: { $0.id == sessionID }) else { return nil }
        let session = TerminalSession(
            title: target.title,
            startingDirectory: target.currentDirectoryRawPath ?? target.startingDirectory
        )
        let branch = SplitTree.branch(id: UUID(), axis: axis, ratio: 0.5,
                                      first: .leaf(target), second: .leaf(session))
        tab.zoomedSessionID = nil
        tab.setRoot(tab.root.replacingLeaf(sessionID, with: branch), focus: session.id)
        return session
    }

    /// Closes one pane; closing the last pane of a tab closes the tab.
    func closePane(_ sessionID: UUID, in tab: TerminalTab) {
        guard tab.isSplit else { closeTab(tab); return }
        guard let session = tab.sessions.first(where: { $0.id == sessionID }) else { return }
        let result = tab.root.removingLeaf(sessionID)
        guard let newRoot = result.tree else { closeTab(tab); return }
        session.terminate()
        // Focus moves to the pane that took the closed one's place.
        let nextFocus = tab.focusedSessionID == sessionID ? result.sibling?.leaves.first?.id : nil
        tab.setRoot(newRoot, focus: nextFocus)
    }

    func closeFocusedPane() {
        guard let tab = activeTab else { return }
        closePane(tab.focusedSessionID, in: tab)
    }

    func equalizePanes(in tab: TerminalTab) {
        guard tab.isSplit else { return }
        tab.setRoot(tab.root.equalized())
    }

    func toggleZoom(in tab: TerminalTab) {
        guard tab.isSplit else { return }
        tab.zoomedSessionID = tab.zoomedSessionID == nil ? tab.focusedSessionID : nil
    }

    // MARK: - Persistence

    func saveSessionState() {
        let saved = tabs.map { tab in
            SavedTab(title: tab.title,
                     userRenamed: tab.customTitle != nil,
                     // Legacy field, so an older build still reopens the first pane's directory.
                     directory: Self.workingDirectory(of: tab.sessions[0]),
                     isActive: tab.id == activeTabId,
                     layout: Self.savedPane(from: tab.root),
                     focusedPaneIndex: tab.sessions.firstIndex { $0.id == tab.focusedSessionID })
        }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.savedTabsKey)
        }
    }

    @discardableResult
    private func restoreTabs() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.savedTabsKey),
              let saved = try? JSONDecoder().decode([SavedTab].self, from: data),
              !saved.isEmpty else { return false }

        var activeTab: TerminalTab?
        for item in saved {
            tabCounter += 1
            // Directories that no longer exist fall back to ~ inside TerminalSession.start().
            let root: SplitTree
            if let layout = item.layout {
                root = Self.splitTree(from: layout)
            } else {
                let first = TerminalSession(title: item.title, startingDirectory: item.directory)
                if item.isSplit == true {
                    let second = TerminalSession(title: item.title, startingDirectory: item.splitDirectory)
                    let ratio = CGFloat(item.splitRatio ?? 0.5)
                    root = .branch(id: UUID(), axis: .horizontal, ratio: min(max(ratio, 0.2), 0.8),
                                   first: .leaf(first), second: .leaf(second))
                } else {
                    root = .leaf(first)
                }
            }
            let leaves = root.leaves
            let focus = item.focusedPaneIndex.flatMap { leaves.indices.contains($0) ? leaves[$0].id : nil }
            let tab = TerminalTab(root: root, focusedSessionID: focus)
            if item.userRenamed { tab.customTitle = item.title }
            tabs.append(tab)
            if item.isActive == true { activeTab = tab }
        }
        if let tab = activeTab ?? tabs.first {
            activateTab(tab)
        }
        return true
    }

    private static func savedPane(from tree: SplitTree) -> SavedPane {
        switch tree {
        case .leaf(let session):
            return .pane(directory: workingDirectory(of: session), title: session.title)
        case let .branch(_, axis, ratio, first, second):
            return .split(axis: axis, ratio: Double(ratio), first: savedPane(from: first), second: savedPane(from: second))
        }
    }

    private static func splitTree(from saved: SavedPane) -> SplitTree {
        switch saved {
        case let .pane(directory, title):
            return .leaf(TerminalSession(title: title, startingDirectory: directory))
        case let .split(axis, ratio, first, second):
            return .branch(id: UUID(), axis: axis, ratio: min(max(CGFloat(ratio), 0.1), 0.9),
                           first: splitTree(from: first), second: splitTree(from: second))
        }
    }

    private static func workingDirectory(of session: TerminalSession) -> String? {
        session.currentDirectoryRawPath ?? session.startingDirectory
    }
}
