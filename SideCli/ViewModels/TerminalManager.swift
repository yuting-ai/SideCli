//
//  TerminalManager.swift
//  SideCli
//
//  Manager for multiple terminal tabs (each tab owns 1–2 sessions).
//

import Foundation
import Combine
import SwiftUI

class TerminalManager: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var activeTabId: UUID?

    private var cancellables: Set<AnyCancellable> = []
    private var tabCounter: Int = 0
    /// Forwards the active tab's objectWillChange to manager, so views
    /// observing manager (e.g. ContentView) re-render when isSplit changes.
    private var activeTabCancellable: AnyCancellable?

    // Keep the same UserDefaults key so existing saved state is preserved.
    private static let savedTabsKey = "sidecli.savedSessions"

    struct SavedTab: Codable {
        let title: String
        let userRenamed: Bool
    }

    // MARK: - Convenience

    var activeTab: TerminalTab? {
        guard let id = activeTabId else { return nil }
        return tabs.first { $0.id == id }
    }

    var activeSession: TerminalSession? { activeTab?.primarySession }
    var hasActiveSession: Bool { activeTabId != nil }
    var sessionCountText: String { "\(tabs.count) tab\(tabs.count == 1 ? "" : "s")" }

    var runningCount: Int {
        allSessions.filter { if case .running = $0.state { return true }; return false }.count
    }

    var finishedCount: Int {
        allSessions.filter { if case .finished = $0.state { return true }; return false }.count
    }

    private var allSessions: [TerminalSession] {
        tabs.flatMap { [$0.primarySession] + ($0.secondarySession.map { [$0] } ?? []) }
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

        session.$state.sink { _ in }.store(in: &cancellables)

        tabs.append(tab)
        activateTab(tab)
        return tab
    }

    func activateTab(_ tab: TerminalTab) {
        activeTabId = tab.id
        // Re-subscribe so any change inside the active tab (sessions, isSplit, title…)
        // also triggers a manager publish → ContentView re-renders.
        activeTabCancellable = tab.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    func activateTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activateTab(tab)
    }

    func closeTab(_ tab: TerminalTab) {
        tab.primarySession.terminate()
        tab.secondarySession?.terminate()
        tabs.removeAll { $0.id == tab.id }

        if tab.id == activeTabId {
            activeTabId = tabs.last?.id
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
        tabs.forEach { $0.primarySession.terminate(); $0.secondarySession?.terminate() }
        tabs.removeAll()
        activeTabId = nil
        createTab()
    }

    func renameTab(_ tab: TerminalTab, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tab.primarySession.markUserRenamed()
        tab.primarySession.title = trimmed
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

    // MARK: - Split Pane

    /// Add a right-side pane to the given tab.
    /// - Parameter startingDirectory: absolute path for the new shell's cwd. nil = home.
    func addSplitPane(to tab: TerminalTab, startingDirectory: String?) {
        guard !tab.isSplit else { return }
        tabCounter += 1
        let session = TerminalSession(
            title: tab.primarySession.title,
            startingDirectory: startingDirectory
        )
        session.$state.sink { _ in }.store(in: &cancellables)
        tab.sessions.append(session)
        activateTab(tab)
    }

    /// Close the pane at the given index (0 = left, 1 = right), terminating its session.
    /// Only valid when the tab is split; no-op otherwise.
    func closePane(at index: Int, of tab: TerminalTab) {
        guard tab.sessions.count > 1, tab.sessions.indices.contains(index) else { return }
        tab.sessions[index].terminate()
        tab.sessions.remove(at: index)
    }

    /// Convenience: close the right pane.
    func closeSplitPane(of tab: TerminalTab) { closePane(at: 1, of: tab) }

    /// Convenience: close the left pane (right pane becomes primary).
    func closePrimaryPane(of tab: TerminalTab) { closePane(at: 0, of: tab) }

    // MARK: - Persistence

    func saveSessionState() {
        let saved = tabs.map { SavedTab(title: $0.primarySession.title,
                                        userRenamed: $0.primarySession.userHasRenamedTab) }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.savedTabsKey)
        }
    }

    @discardableResult
    private func restoreTabs() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.savedTabsKey),
              let saved = try? JSONDecoder().decode([SavedTab].self, from: data),
              !saved.isEmpty else { return false }

        for item in saved {
            tabCounter += 1
            let session = TerminalSession(title: item.title)
            if item.userRenamed { session.markUserRenamed() }
            session.$state.sink { _ in }.store(in: &cancellables)
            tabs.append(TerminalTab(session: session))
        }
        if let first = tabs.first {
            activateTab(first)
        }
        return true
    }
}
