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
    private lazy var mainMenu = MainMenuController(panelController: panelController)

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.bootstrapLanguageIfNeeded()
        panelController.setup()
        mainMenu.install()
        UpdateManager.shared.startPeriodicChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController.saveSessionState()
        panelController.saveWindowState()
    }

    /// ⌘Q (or Quit in a menu) while a program runs in some pane: quitting would end
    /// it, so ask first — like closing a pane does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = TerminalSession.runningProgramNames()
        guard !running.isEmpty else { return .terminateNow }

        let zh = AppPreferences.language() == .chinese
        let t = { (en: String, cn: String) in zh ? cn : en }
        let names = running.map { "“\($0)”" }.joined(separator: zh ? "、" : ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Quit SideCli?", "退出 SideCli？")
        alert.informativeText = running.count == 1
            ? t("\(names) is still running. Quitting will end it.", "\(names) 还在运行，退出后它会被结束。")
            : t("\(running.count) programs are still running (\(names)). Quitting will end them.",
                "有 \(running.count) 个程序还在运行（\(names)），退出后它们会被结束。")
        alert.addButton(withTitle: t("Quit", "退出")).hasDestructiveAction = true
        alert.addButton(withTitle: t("Cancel", "取消"))   // Esc
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
            Button(t("Show SideCli", "显示 SideCli")) {
                panelController.showWindow()
            }
            Button(t("New Tab", "新建标签页")) {
                panelController.showWindow()
                AppCommand.newTab.post()
            }
            Button(t("Settings…", "设置…")) {
                panelController.showWindow()
                AppCommand.showSettings.post()
            }

            Divider()

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
    static let saveSessionState   = Notification.Name("saveSessionState")
}
