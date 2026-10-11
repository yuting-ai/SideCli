//
//  TerminalTab.swift
//  SideCli
//
//  One tab: a split tree of terminal sessions, which pane has focus, and
//  which pane (if any) is zoomed to fill the tab.
//
//  Why forward session.objectWillChange?
//  TerminalTabItem observes `tab`, not the individual sessions. Without
//  forwarding, a title change from OSC 7 (session.title) would not trigger a
//  tab-bar re-render.
//

import Foundation
import Combine

final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()

    /// Pane layout. Structural changes go through `setRoot` (publishes);
    /// divider drags use `setRatio`, which deliberately does not publish so a
    /// drag doesn't re-render SwiftUI on every mouse move.
    private(set) var root: SplitTree

    @Published var focusedSessionID: UUID
    /// Pane temporarily filling the whole tab (⌘⇧↩). nil = normal layout.
    @Published var zoomedSessionID: UUID?
    /// Set when the user renames the tab; otherwise the title follows the focused pane.
    @Published var customTitle: String?

    // MARK: - Convenience

    var sessions: [TerminalSession] { root.leaves }
    var focusedSession: TerminalSession { sessions.first { $0.id == focusedSessionID } ?? sessions[0] }
    var isSplit: Bool { root.isBranch }
    var paneCount: Int { sessions.count }
    var title: String { customTitle ?? focusedSession.title }
    var currentDirectory: String? { focusedSession.currentDirectory }

    // MARK: - Init

    init(root: SplitTree, focusedSessionID: UUID? = nil) {
        self.root = root
        let leaves = root.leaves
        if let focusedSessionID, leaves.contains(where: { $0.id == focusedSessionID }) {
            self.focusedSessionID = focusedSessionID
        } else {
            self.focusedSessionID = leaves[0].id
        }
        resubscribeToSessions()
    }

    convenience init(session: TerminalSession) {
        self.init(root: .leaf(session))
    }

    // MARK: - Mutation

    func setRoot(_ newRoot: SplitTree, focus: UUID? = nil) {
        objectWillChange.send()
        root = newRoot
        let leaves = newRoot.leaves
        if let focus, leaves.contains(where: { $0.id == focus }) {
            focusedSessionID = focus
        } else if !leaves.contains(where: { $0.id == focusedSessionID }) {
            focusedSessionID = leaves[0].id
        }
        if let zoomed = zoomedSessionID, !newRoot.isBranch || !leaves.contains(where: { $0.id == zoomed }) {
            zoomedSessionID = nil
        }
        resubscribeToSessions()
    }

    func setRatio(_ ratio: CGFloat, forBranch branchID: UUID) {
        root = root.settingRatio(ratio, for: branchID)
    }

    func focus(_ sessionID: UUID) {
        guard focusedSessionID != sessionID, root.contains(sessionID) else { return }
        focusedSessionID = sessionID
    }

    // MARK: - Session change forwarding

    private var sessionCancellables = Set<AnyCancellable>()

    private func resubscribeToSessions() {
        sessionCancellables.removeAll()
        for session in sessions {
            session.objectWillChange
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &sessionCancellables)
        }
    }
}
