//
//  TerminalTab.swift
//  SideCli
//
//  Represents one tab, which owns up to two sessions arranged left / right.
//
//  Why forward session.objectWillChange?
//  TerminalTabItem observes `tab`, not the individual sessions. Without
//  forwarding, a title change from OSC 7 (session.title) or a session swap
//  after closing a pane would not trigger a tab-bar re-render.
//

import Foundation
import Combine

class TerminalTab: ObservableObject, Identifiable {
    let id: UUID

    /// Ordered list of sessions: [0] = left pane, [1] = right pane (max 2).
    @Published var sessions: [TerminalSession] {
        didSet { resubscribeToSessions() }
    }

    /// Left pane width as a fraction of total width. Range [0.2, 0.8].
    @Published var splitRatio: CGFloat = 0.5

    // MARK: - Convenience

    var primarySession: TerminalSession  { sessions[0] }
    var secondarySession: TerminalSession? { sessions.count > 1 ? sessions[1] : nil }
    var isSplit: Bool   { sessions.count > 1 }
    var title: String   { primarySession.title }
    var currentDirectory: String? { primarySession.currentDirectory }

    // MARK: - Init

    init(session: TerminalSession) {
        self.id = UUID()
        self.sessions = [session]
        resubscribeToSessions()
    }

    // MARK: - Session change forwarding

    /// Cancellables for individual session → tab forwarding.
    private var sessionCancellables = Set<AnyCancellable>()

    /// Subscribe to every session's `objectWillChange` so that when any
    /// session publishes (e.g. title change from OSC 7), the tab also
    /// publishes, and views observing `tab` (TerminalTabItem) re-render.
    private func resubscribeToSessions() {
        sessionCancellables.removeAll()
        for session in sessions {
            session.objectWillChange
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &sessionCancellables)
        }
    }
}
