//
//  WelcomeView.swift
//  SideCli
//

import SwiftUI
import AppKit

struct WelcomeView: View {
    let onDismiss: () -> Void
    @AppStorage(AppPreferences.languageKey) private var appLanguageRaw = AppPreferences.languageDefault

    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    private func t(_ en: String, _ zh: String) -> String {
        language == .chinese ? zh : en
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(t("Welcome to SideCli", "欢迎使用 SideCli"))
                    .font(.system(size: 22, weight: .bold))

                Text(t("A lightweight terminal that lives on the side of your screen.",
                       "一个驻留在屏幕侧边的轻量终端。"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.horizontal, 32)

            Divider()
                .padding(.vertical, 24)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(t("Language", "语言"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Picker("", selection: $appLanguageRaw) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }

                Text(t("Choose your preferred language for SideCli.",
                       "选择你希望 SideCli 使用的语言。"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            // First-run essentials + privacy note
            VStack(alignment: .leading, spacing: 16) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t("Menu bar app behavior", "菜单栏应用说明"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(t("SideCli runs as a menu bar app (not in Dock). You can quit it from the menu bar.",
                               "SideCli 作为菜单栏应用运行（不会出现在 Dock 中）。你可以通过菜单栏退出。"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                        .frame(width: 28)
                }

                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t("Show / hide with shortcut", "通过快捷键显示/隐藏"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(t("Use your configured global shortcut to quickly show or hide SideCli while staying in your current app. You can configure this shortcut in Settings.",
                               "使用你配置的全局快捷键可在当前应用内快速显示或隐藏 SideCli。你可以在设置中配置这个快捷键。"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 20))
                        .foregroundColor(.green)
                        .frame(width: 28)
                }

                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t("About folder access permission", "关于文件夹访问权限"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(t("macOS may ask if SideCli can access folders on your Mac. This prompt comes from the shell (zsh) that SideCli launches — the same shell you use in Terminal.app. SideCli itself does not read, store, or transmit any of your files.",
                               "macOS 可能会询问是否允许 SideCli 访问你 Mac 上的文件夹。该提示来自 SideCli 启动的 shell（zsh），与 Terminal.app 使用的是同一个 shell。SideCli 本身不会读取、存储或传输你的文件。"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 20))
                        .foregroundColor(.orange)
                        .frame(width: 28)
                }

            }
            .padding(.horizontal, 32)

            Spacer(minLength: 24)

            // Button
            Button(action: onDismiss) {
                Text(t("Start Quick Tour", "开始快速引导"))
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .frame(width: 400)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color(NSColor.controlColor))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(12)
            .help(t("Close", "关闭"))
        }
        .onExitCommand { onDismiss() }
    }
}
