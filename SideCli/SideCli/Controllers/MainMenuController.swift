//
//  MainMenuController.swift
//  SideCli
//
//  The menu bar shown while SideCli is the active app (it is once the panel is a
//  regular window). It lists every command with its shortcut, so they can be found
//  without the quick tour. Rebuilt when the app language changes.
//
//  The shortcuts themselves are handled by ContentView first; these menu items show
//  them and run the same commands when picked with the mouse.
//

import AppKit

final class MainMenuController: NSObject {
    private let panelController: PanelController
    private var builtLanguage: AppLanguage?
    private var defaultsObserver: NSObjectProtocol?

    init(panelController: PanelController) {
        self.panelController = panelController
        super.init()
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    func install() {
        rebuild()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, AppPreferences.language() != self.builtLanguage else { return }
            self.rebuild()
        }
    }

    private func t(_ en: String, _ zh: String) -> String {
        AppPreferences.language() == .chinese ? zh : en
    }

    private func rebuild() {
        builtLanguage = AppPreferences.language()
        let main = NSMenu()

        main.addItem(submenu("SideCli", [
            command(t("Settings…", "设置…"), ",", .showSettings),
            item(t("Check for Updates…", "检查更新…"), action: #selector(checkForUpdates)),
            .separator(),
            item(t("Hide SideCli", "隐藏 SideCli"), "h", action: #selector(hidePanel)),
            .separator(),
            item(t("Quit SideCli", "退出 SideCli"), "q", action: #selector(NSApplication.terminate(_:)), target: NSApp),
        ]))

        main.addItem(submenu(t("Shell", "终端"), [
            command(t("New Tab", "新建标签页"), "t", .newTab),
            .separator(),
            command(t("Split Pane", "分屏"), "d", .split(.auto)),
            command(t("Split the Other Way", "反方向分屏"), "d", [.command, .shift], .split(.opposite)),
            command(t("Split Top / Bottom", "上下分屏"), "", .split(.axis(.vertical))),
            command(t("Split Left / Right", "左右分屏"), "", .split(.axis(.horizontal))),
            .separator(),
            command(t("Clear Screen", "清屏"), "k", .clearScreen),
            .separator(),
            command(t("Close Pane", "关闭窗格"), "w", .closePane),
        ]))

        // Standard selectors: the focused terminal view handles them.
        main.addItem(submenu(t("Edit", "编辑"), [
            item(t("Copy", "拷贝"), "c", action: #selector(NSText.copy(_:)), responderChain: true),
            item(t("Paste", "粘贴"), "v", action: #selector(NSText.paste(_:)), responderChain: true),
            item(t("Select All", "全选"), "a", action: #selector(NSText.selectAll(_:)), responderChain: true),
        ]))

        main.addItem(submenu(t("View", "显示"), [
            command(t("Bigger", "放大字号"), "+", .fontBigger),
            command(t("Smaller", "缩小字号"), "-", .fontSmaller),
            command(t("Default Size", "默认字号"), "0", .fontReset),
            .separator(),
            command(t("Zoom Pane", "放大当前窗格"), "\r", [.command, .shift], .toggleZoom),
            command(t("Equalize Panes", "均分窗格"), "", .equalize),
            .separator(),
            command(t("Toggle Light / Dark Theme", "切换深色 / 浅色主题"), "", .toggleTheme),
        ]))

        let arrow = { (key: Int) in String(Character(UnicodeScalar(key)!)) }
        main.addItem(submenu(t("Window", "窗口"), [
            item(t("Minimize", "最小化"), "m", action: #selector(minimizePanel)),
            item(t("Fill Screen / Restore", "铺满屏幕 / 还原"), action: #selector(toggleFillScreen)),
            .separator(),
            command(t("Show Next Tab", "下一个标签页"), "]", [.command, .shift], .nextTab),
            command(t("Show Previous Tab", "上一个标签页"), "[", [.command, .shift], .previousTab),
            .separator(),
            command(t("Select Pane on the Left", "选择左侧窗格"), arrow(NSLeftArrowFunctionKey), [.command, .option], .moveFocus(.left)),
            command(t("Select Pane on the Right", "选择右侧窗格"), arrow(NSRightArrowFunctionKey), [.command, .option], .moveFocus(.right)),
            command(t("Select Pane Above", "选择上方窗格"), arrow(NSUpArrowFunctionKey), [.command, .option], .moveFocus(.up)),
            command(t("Select Pane Below", "选择下方窗格"), arrow(NSDownArrowFunctionKey), [.command, .option], .moveFocus(.down)),
        ]))

        NSApp.mainMenu = main
    }

    // MARK: Builders

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    /// Targets this controller unless `target` is given; `responderChain` leaves the
    /// target empty so the focused view (the terminal) handles the action.
    private func item(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                      action: Selector, target: AnyObject? = nil, responderChain: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = responderChain ? nil : (target ?? self)
        return item
    }

    private func command(_ title: String, _ key: String, _ command: AppCommand) -> NSMenuItem {
        self.command(title, key, .command, command)
    }

    private func command(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags,
                         _ command: AppCommand) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runCommand(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.representedObject = AppCommand.CommandBox(command)
        return item
    }

    // MARK: Actions

    @objc private func runCommand(_ sender: NSMenuItem) {
        (sender.representedObject as? AppCommand.CommandBox)?.command.post()
    }

    @objc private func checkForUpdates() { UpdateManager.shared.checkForUpdatesInteractive() }
    @objc private func hidePanel() { panelController.hideWindow() }
    @objc private func minimizePanel() { panelController.minimizeToDock() }
    @objc private func toggleFillScreen() { panelController.toggleMaximize() }
}
