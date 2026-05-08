//
//  SideCliApp.swift
//  SideCli
//

import SwiftUI

@main
struct SideCliApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar icon — the only UI surface other than the sliding panel.
        MenuBarExtra {
            MenuBarView(panelController: appDelegate.panelController)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let panelController = PanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.bootstrapLanguageIfNeeded()
        panelController.setup()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController.saveSessionState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - Menu Bar Popover Content

struct MenuBarView: View {
    @ObservedObject var panelController: PanelController

    var body: some View {
        Button("Quit SideCli") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}

// MARK: - Notifications (kept for compatibility with ContentView)

extension Notification.Name {
    static let createNewTerminal  = Notification.Name("createNewTerminal")
    static let closeActiveTerminal = Notification.Name("closeActiveTerminal")
    static let saveSessionState   = Notification.Name("saveSessionState")
}
