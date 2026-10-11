//
//  SideCliApp.swift
//  SideCli
//

import SwiftUI
import AppKit
import TelemetryDeck

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
                .frame(width: 12, height: 12)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let panelController = PanelController()
    private var launchTime = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.bootstrapLanguageIfNeeded()
        TelemetryDeck.initialize(config: .init(appID: "CBD09DBE-EAD7-4AEA-8A51-A8BE33D29B08"))
        TelemetryDeck.signal("app.launched", parameters: [
            "macOSVersion": ProcessInfo.processInfo.operatingSystemVersionString
        ])
        launchTime = Date()
        panelController.setup()
        UpdateManager.shared.startPeriodicChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let seconds = Int(Date().timeIntervalSince(launchTime))
        TelemetryDeck.signal("app.terminated", parameters: [
            "sessionDurationSeconds": "\(seconds)"
        ])
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
        Group {
            Button("Check for Updates...") {
                UpdateManager.shared.checkForUpdatesInteractive()
            }

            Divider()

            Button("Quit SideCli") {
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
