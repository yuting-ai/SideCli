//
//  AppCommand.swift
//  SideCli
//
//  Everything the menu bar, the status-bar menu and the keyboard shortcuts can ask
//  the panel to do. Menus post a command; ContentView, which owns the terminals,
//  performs it.
//

import Foundation

enum AppCommand {
    case newTab
    case closePane
    case split(SplitMode)
    case toggleZoom
    case equalize
    case moveFocus(FocusDirection)
    case selectTab(Int)        // 1-based; 9 = last tab, like browsers
    case nextTab
    case previousTab
    case fontBigger
    case fontSmaller
    case fontReset
    case clearScreen
    case toggleTheme
    case showSettings

    func post() {
        NotificationCenter.default.post(name: .appCommand, object: CommandBox(self))
    }

    /// Wraps the enum so it can travel as a notification's object.
    final class CommandBox {
        let command: AppCommand
        init(_ command: AppCommand) { self.command = command }
    }
}

extension Notification.Name {
    static let appCommand = Notification.Name("com.sidecli.appCommand")
}
