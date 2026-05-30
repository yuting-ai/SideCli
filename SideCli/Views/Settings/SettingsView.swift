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
    @State private var pendingWarnOnCloseWithRunningProcess: Bool?
    @State private var pendingLanguageRaw: String?

    private var shortcutManager: GlobalShortcutManager { panelController.shortcutManager }
    private var displayKeyCode: Int { pendingKeyCode ?? shortcutManager.keyCode }
    private var displayModifiers: NSEvent.ModifierFlags { pendingModifiers ?? shortcutManager.modifierFlags }
    private var displayFontSize: Int { pendingFontSize ?? panelController.fontSize }
    private var displayWarnOnCloseWithRunningProcess: Bool {
        pendingWarnOnCloseWithRunningProcess ?? AppPreferences.warnOnCloseWithRunningProcess()
    }
    private var displayLanguageRaw: String { pendingLanguageRaw ?? appLanguageRaw }
    private var language: AppLanguage { AppLanguage(rawValue: displayLanguageRaw) ?? .english }
    private var appVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?): return "Version \(s) (\(b))"
        case let (s?, nil): return "Version \(s)"
        case let (nil, b?): return "Build \(b)"
        default: return "Version unavailable"
        }
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
                        .padding(.bottom, 16)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("General", "通用"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        HStack {
                            Text(t("Language", "语言"))
                                .font(.system(size: 13))
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
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }

                    Divider().padding(.vertical, 14)

                    // Global Shortcut
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("Global Shortcut", "全局快捷键"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

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
                            }
                            .frame(width: 110, height: 26)
                        }
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)

                        Text(t("Click the shortcut field, then press a new key combo (requires ⌘, ⌃, or ⌥)",
                               "点击快捷键区域后按下新的组合键（需要 ⌘、⌃ 或 ⌥）"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Divider().padding(.vertical, 14)

                    // Font Size
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("Terminal", "终端"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        HStack {
                            Text(t("Font Size", "字体大小"))
                                .font(.system(size: 13))
                            Spacer()
                            Stepper("\(displayFontSize) pt",
                                    value: Binding(
                                        get: { displayFontSize },
                                        set: { pendingFontSize = $0 }
                                    ),
                                    in: 10...28)
                            .fixedSize()
                        }
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)

                        HStack {
                            Toggle(t("Always ask before closing a terminal tab", "关闭终端标签页前总是确认"), isOn: Binding(
                                get: { displayWarnOnCloseWithRunningProcess },
                                set: { pendingWarnOnCloseWithRunningProcess = $0 }
                            ))
                            .font(.system(size: 13))
                        }
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }

                    Divider().padding(.vertical, 14)

                    // About
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("About", "关于"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

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
                                Text("SwiftTerm (MIT License)")
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
                .padding(20)
            }

            Divider()

            HStack {
                Button(t("Cancel", "取消")) {
                    pendingKeyCode   = nil
                    pendingModifiers = nil
                    pendingFontSize  = nil
                    pendingWarnOnCloseWithRunningProcess = nil
                    pendingLanguageRaw = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(t("Save", "保存")) {
                    if let kc = pendingKeyCode, let mods = pendingModifiers {
                        shortcutManager.updateShortcut(keyCode: kc, modifiers: mods)
                    }
                    if let fs = pendingFontSize {
                        panelController.updateFontSize(fs)
                    }
                    if let warn = pendingWarnOnCloseWithRunningProcess {
                        UserDefaults.standard.set(
                            warn,
                            forKey: AppPreferences.warnOnCloseWithRunningProcessKey
                        )
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
        .frame(width: 360, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
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
            ? "Press keys…"
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
        guard !mods.isEmpty else { return }    // must have a modifier

        isRecording = false
        onRecordingChanged?(false)
        onRecord?(Int(event.keyCode), mods)
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        if isRecording { needsDisplay = true }
    }
}
