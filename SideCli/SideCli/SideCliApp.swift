//
//  SideCliApp.swift
//  SideCli
//

import SwiftUI
import AppKit

@main
struct SideCliApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar icon — the only UI surface other than the sliding panel.
        MenuBarExtra {
            MenuBarView(panelController: appDelegate.panelController)
        } label: {
            // Drawn at its native 18 pt (the standard status-item size); scaling it
            // down blurs the cut-out prompt. Template: macOS tints it to the menu bar.
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let panelController = PanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.bootstrapLanguageIfNeeded()
        panelController.setup()
        UpdateManager.shared.startPeriodicChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController.saveSessionState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Clicking the Dock icon brings the panel back, whether it was hidden with the
    /// shortcut or parked off-screen by auto-hide.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController.showWindow()
        return true
    }
}

// MARK: - Menu Bar Popover Content

struct MenuBarView: View {
    @ObservedObject var panelController: PanelController
    @AppStorage(AppPreferences.languageKey) private var appLanguageRaw = AppPreferences.languageDefault
    private func t(_ en: String, _ zh: String) -> String {
        (AppLanguage(rawValue: appLanguageRaw) ?? .english) == .chinese ? zh : en
    }

    var body: some View {
        Group {
            Button(t("Check for Updates…", "检查更新…")) {
                UpdateManager.shared.checkForUpdatesInteractive()
            }

            Divider()

            Button(t("Quit SideCli", "退出 SideCli")) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }
}

// MARK: - Notifications (kept for compatibility with ContentView)

extension Notification.Name {
    static let createNewTerminal  = Notification.Name("createNewTerminal")
    static let closeActiveTerminal = Notification.Name("closeActiveTerminal")
    static let saveSessionState   = Notification.Name("saveSessionState")
}
