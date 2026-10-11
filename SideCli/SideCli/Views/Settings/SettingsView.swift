//
//  SettingsView.swift
//  SideCli
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var panelController: PanelController
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppPreferences.languageKey) private var appLanguageRaw = AppPreferences.languageDefault

    @State private var pendingKeyCode: Int?
    @State private var pendingModifiers: NSEvent.ModifierFlags?
    @State private var isRecording = false
    @State private var pendingFontSize: Int?
    @State private var pendingLanguageRaw: String?
    @State private var shortcutUnavailable = false

    private var shortcutManager: GlobalShortcutManager { panelController.shortcutManager }
    private var displayKeyCode: Int { pendingKeyCode ?? shortcutManager.keyCode }
    private var displayModifiers: NSEvent.ModifierFlags { pendingModifiers ?? shortcutManager.modifierFlags }
    private var displayFontSize: Int { pendingFontSize ?? panelController.fontSize }
    private var displayLanguageRaw: String { pendingLanguageRaw ?? appLanguageRaw }
    private var language: AppLanguage { AppLanguage(rawValue: displayLanguageRaw) ?? .english }
    private var appVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short.map { t("Version \($0)", "版本 \($0)") } ?? t("Version unavailable", "版本未知")
    }

    private func t(_ en: String, _ zh: String) -> String {
        language == .chinese ? zh : en
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    Text(t("Settings", "设置"))
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.bottom, 10)

                    // MARK: General
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(t("General", "通用"))
                        HStack {
                            Text(t("Language", "语言")).font(.system(size: 13))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { displayLanguageRaw },
                                set: { pendingLanguageRaw = $0 }
                            )) {
                                ForEach(AppLanguage.allCases) { lang in
                                    Text(lang.displayName).tag(lang.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 130)
                        }
                        .padding(.vertical, 7).padding(.horizontal, 10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }

                    Divider().padding(.vertical, 10)

                    // MARK: Global Shortcut
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(t("Global Shortcut", "全局快捷键"))
                        HStack {
                            Text(t("Show / Hide Terminal", "显示/隐藏终端"))
                                .font(.system(size: 13))
                            Spacer()
                            ShortcutRecorderView(
                                isRecording: $isRecording,
                                keyCode: displayKeyCode,
                                modifiers: displayModifiers
                            ) { kc, mods in
                                pendingKeyCode   = kc
                                pendingModifiers = mods
                                isRecording      = false
                                shortcutUnavailable = false
                            }
                            .frame(width: 110, height: 26)
                        }
                        .padding(.vertical, 7).padding(.horizontal, 10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)

                        Text(t("Click the shortcut field, then press a new key combo (requires ⌘, ⌃, or ⌥)",
                               "点击快捷键区域后按下新的组合键（需要 ⌘、⌃ 或 ⌥）"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        if shortcutUnavailable {
                            Text(t("This shortcut is unavailable (it may be used by another app). Please choose another one.",
                                   "该快捷键不可用（可能已被其他应用占用），请换一个。"))
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }
                    }

                    Divider().padding(.vertical, 10)

                    // MARK: Terminal
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(t("Terminal", "终端"))
                        HStack {
                            Text(t("Font Size", "字体大小")).font(.system(size: 13))
                            Spacer()
                            Stepper("\(displayFontSize) pt",
                                    value: Binding(
                                        get: { displayFontSize },
                                        set: { pendingFontSize = $0 }
                                    ),
                                    in: 10...28)
                            .fixedSize()
                        }
                        .padding(.vertical, 7).padding(.horizontal, 10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }

                    Divider().padding(.vertical, 10)

                    // MARK: Keyboard Shortcuts
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(t("Keyboard Shortcuts", "快捷键"))
                        VStack(spacing: 0) {
                            shortcutRow(t("New Tab",       "新建标签页"), "⌘T")
                            Divider()
                            shortcutRow(t("Close Pane / Tab", "关闭窗格 / 标签页"), "⌘W")
                            Divider()
                            shortcutRow(t("Split Pane (auto direction)", "分屏（自动选方向）"), "⌘D")
                            Divider()
                            shortcutRow(t("Split the Other Way", "反方向分屏"), "⌘⇧D")
                            Divider()
                            shortcutRow(t("Zoom / Restore Pane", "放大 / 还原窗格"), "⌘⇧↩")
                            Divider()
                            shortcutRow(t("Move Between Panes", "切换窗格"), "⌘⌥←→↑↓")
                            Divider()
                            shortcutRow(t("Increase Font", "增大字体"),   "⌘+")
                            Divider()
                            shortcutRow(t("Decrease Font", "缩小字体"),   "⌘-")
                            Divider()
                            shortcutRow(t("Quit",          "退出"),       "⌘Q")
                        }
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }

                    Divider().padding(.vertical, 10)

                    // MARK: About
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(t("About", "关于"))
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("SideCli").font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(appVersionText).font(.system(size: 12)).foregroundColor(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text(t("Website:", "官网："))
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Link("sidecli.com", destination: URL(string: "https://sidecli.com")!)
                                    .font(.system(size: 12))
                            }
                            Divider()
                            HStack {
                                Text(t("SwiftTerm (MIT License)", "SwiftTerm（MIT 许可证）"))
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                Link(t("View License", "查看许可"),
                                     destination: URL(string: "https://github.com/migueldeicaza/SwiftTerm/blob/master/LICENSE")!)
                                    .font(.system(size: 12))
                            }
                            Text(t("Terminal rendering powered by SwiftTerm.\nThanks to all contributors.",
                                   "终端渲染由 SwiftTerm 驱动。\n感谢所有贡献者。"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 7).padding(.horizontal, 10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Button(t("Cancel", "取消")) {
                    pendingKeyCode   = nil
                    pendingModifiers = nil
                    pendingFontSize  = nil
                    pendingLanguageRaw = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(t("Save", "保存")) {
                    if let kc = pendingKeyCode, let mods = pendingModifiers,
                       !shortcutManager.updateShortcut(keyCode: kc, modifiers: mods) {
                        // Keep the sheet open so the user can pick another combo.
                        shortcutUnavailable = true
                        return
                    }
                    if let fs = pendingFontSize {
                        panelController.updateFontSize(fs)
                    }
                    if let lang = pendingLanguageRaw {
                        appLanguageRaw = lang
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: max(300, min(panelController.panelWidth, 420)), height: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }

    private func shortcutRow(_ label: String, _ combo: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Text(combo)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(NSColor.controlColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
    }
}

// MARK: - Shortcut Recorder

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let keyCode: Int
    let modifiers: NSEvent.ModifierFlags
    let onRecord: (Int, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let v = ShortcutRecorderNSView()
        v.onRecord = onRecord
        v.onRecordingChanged = { recording in
            DispatchQueue.main.async { isRecording = recording }
        }
        return v
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.keyCode    = keyCode
        nsView.modifiers  = modifiers
        nsView.isRecording = isRecording
        nsView.needsDisplay = true
    }
}

class ShortcutRecorderNSView: NSView {
    var keyCode: Int = 50
    var modifiers: NSEvent.ModifierFlags = .command
    var isRecording = false
    var onRecord: ((Int, NSEvent.ModifierFlags) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let label = isRecording
            ? (AppPreferences.language() == .chinese ? "请按下组合键…" : "Press keys…")
            : shortcutDisplayString(keyCode: keyCode, modifiers: modifiers)

        let bg = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.controlColor
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()

        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            border.lineWidth = 1
            border.stroke()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let sz  = str.size()
        str.draw(at: NSPoint(x: (bounds.width  - sz.width)  / 2,
                             y: (bounds.height - sz.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        guard !isRecording else { return }
        isRecording = true
        onRecordingChanged?(true)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        // Must include ⌘, ⌥ or ⌃; Shift-only would hijack normal typing system-wide.
        guard GlobalShortcutManager.isValidModifierSet(mods) else {
            if !mods.isEmpty { NSSound.beep() }
            return
        }

        isRecording = false
        onRecordingChanged?(false)
        onRecord?(Int(event.keyCode), mods)
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        if isRecording { needsDisplay = true }
    }
}
