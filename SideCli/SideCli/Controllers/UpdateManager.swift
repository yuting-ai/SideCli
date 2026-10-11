import Foundation
import AppKit

/// Localized string for the language chosen in Settings (read at display time).
private func t(_ en: String, _ zh: String) -> String {
    AppPreferences.language() == .chinese ? zh : en
}

final class UpdateManager {
    static let shared = UpdateManager()

    private let latestReleaseAPI = URL(string: "https://api.github.com/repos/yuting-ai/SideCli/releases/latest")!
    private let releasePageURL = URL(string: "https://github.com/yuting-ai/SideCli/releases/latest")!

    private let checkInterval: TimeInterval = 48 * 3600
    /// How often to ask "is a check due?". Short relative to checkInterval so the
    /// effective period stays ~48h instead of drifting up to ~2x after a launch.
    private let duePollInterval: TimeInterval = 6 * 3600
    private let lastCheckKey = "sidecli.lastUpdateCheck"
    private var periodicTimer: Timer?
    /// Main-actor only. Prevents a background and an interactive check from
    /// stacking two alerts / two downloads.
    private var isUpdateFlowActive = false

    private init() {}

    func startPeriodicChecks() {
        checkIfDue()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: duePollInterval, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) >= checkInterval else { return }
        checkForUpdatesBackground()
    }

    private func checkForUpdatesBackground() {
        Task { @MainActor in
            // Claimed before the first await so two checks can't both get through.
            guard !isUpdateFlowActive else { return }
            isUpdateFlowActive = true
            defer { isUpdateFlowActive = false }
            // Only a successful fetch counts as "checked"; a network failure is retried
            // on the next poll instead of silently waiting another 48h.
            guard let release = try? await fetchLatestRelease() else { return }
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            guard isVersion(release.version, newerThan: appVersion()) else { return }
            await runUpdateFlow(release: release)
        }
    }

    func checkForUpdatesInteractive() {
        Task { @MainActor in
            // Claimed before the first await so two checks can't both get through.
            guard !isUpdateFlowActive else { return }
            isUpdateFlowActive = true
            defer { isUpdateFlowActive = false }
            do {
                let release = try await fetchLatestRelease()
                UserDefaults.standard.set(Date(), forKey: lastCheckKey)
                let currentVersion = appVersion()

                guard isVersion(release.version, newerThan: currentVersion) else {
                    await showInfoAlert(
                        title: t("You're up to date", "已是最新版本"),
                        message: t("Current version: \(currentVersion)\nLatest version: \(release.version)",
                                   "当前版本：\(currentVersion)\n最新版本：\(release.version)")
                    )
                    return
                }

                await runUpdateFlow(release: release)
            } catch {
                await showErrorAlert(
                    title: t("Update check failed", "检查更新失败"),
                    message: t("Unable to check for updates.\n\n\(error.localizedDescription)",
                               "无法检查更新。\n\n\(error.localizedDescription)"),
                    fallbackURL: releasePageURL
                )
            }
        }
    }

    /// Asks, downloads and opens; any download failure is reported to the user
    /// (the user already chose "Download", so silence would look like a hang).
    @MainActor
    private func runUpdateFlow(release: GitHubRelease) async {
        do {
            try await presentUpdateFlow(release: release)
        } catch {
            // The user pressed Cancel in the progress window — not an error.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            await showErrorAlert(
                title: t("Update download failed", "更新下载失败"),
                message: t("Version \(release.version) could not be downloaded.\n\n\(error.localizedDescription)",
                           "版本 \(release.version) 下载失败。\n\n\(error.localizedDescription)"),
                fallbackURL: release.htmlURL
            )
        }
    }

    @MainActor
    private func presentUpdateFlow(release: GitHubRelease) async throws {
        let shouldDownload = await askToDownload(version: release.version)
        guard shouldDownload else { return }

        if let asset = release.preferredDownloadAsset {
            let downloadTask = Task { try await self.download(asset: asset) }
            // Without feedback a multi-MB download looks like nothing happened.
            let progressWindow = DownloadProgressWindow(version: release.version) {
                downloadTask.cancel()
            }
            progressWindow.show()
            defer { progressWindow.close() }
            let localFile = try await downloadTask.value
            NSWorkspace.shared.open(localFile)
        } else {
            await showInfoAlert(
                title: t("New version available", "有新版本"),
                message: t("Version \(release.version) is available.\nNo direct install asset was found, opening release page.",
                           "版本 \(release.version) 已发布。\n没有找到可直接安装的文件，将打开发布页面。")
            )
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    // MARK: - Network

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: latestReleaseAPI)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SideCli", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.invalidResponse
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func download(asset: GitHubAsset) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.downloadFailed
        }

        let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        let destination = uniqueDestinationURL(in: downloadsDirectory, fileName: asset.name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private func uniqueDestinationURL(in directory: URL, fileName: String) -> URL {
        let baseURL = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return baseURL }

        let ext = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970)
        let deduped = "\(stem)-\(stamp)"
        if ext.isEmpty {
            return directory.appendingPathComponent(deduped)
        }
        return directory.appendingPathComponent(deduped).appendingPathExtension(ext)
    }

    // MARK: - Version

    private func appVersion() -> String {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !v.isEmpty {
            return v
        }
        if let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !b.isEmpty {
            return b
        }
        return "0.0.0"
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let l = normalizeVersion(lhs)
        let r = normalizeVersion(rhs)
        let count = max(l.count, r.count)
        for i in 0..<count {
            let lv = i < l.count ? l[i] : 0
            let rv = i < r.count ? r[i] : 0
            if lv != rv { return lv > rv }
        }
        return false
    }

    private func normalizeVersion(_ raw: String) -> [Int] {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: .caseInsensitive)
        return cleaned
            .split(separator: ".")
            .map { chunk in
                let digits = chunk.filter(\.isNumber)
                return Int(digits) ?? 0
            }
    }

    // MARK: - UI

    @MainActor
    private func askToDownload(version: String) async -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = t("Update available", "有可用更新")
        alert.informativeText = t("A newer version (\(version)) is available.\nDo you want to download it now?",
                                  "新版本（\(version)）已发布。\n要现在下载吗？")
        alert.addButton(withTitle: t("Download", "下载"))
        alert.addButton(withTitle: t("Not Now", "以后再说"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showInfoAlert(title: String, message: String) async {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: t("OK", "好"))
        alert.runModal()
    }

    @MainActor
    private func showErrorAlert(title: String, message: String, fallbackURL: URL) async {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: t("Open Release Page", "打开发布页面"))
        alert.addButton(withTitle: t("Cancel", "取消"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(fallbackURL)
        }
    }
}

// MARK: - Download Progress Window

/// Small floating window with an indeterminate bar and a Cancel button,
/// shown while an update is downloading.
@MainActor
private final class DownloadProgressWindow: NSObject {
    private let panel: NSPanel
    private let onCancel: () -> Void

    init(version: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
                        styleMask: [.titled],
                        backing: .buffered,
                        defer: false)
        super.init()

        panel.title = t("Downloading Update", "正在下载更新")
        panel.level = .floating
        panel.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: t("Downloading SideCli \(version)…", "正在下载 SideCli \(version)…"))
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let cancel = NSButton(title: t("Cancel", "取消"), target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    func show() {
        NSApp.activate()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    @objc private func cancelPressed() {
        onCancel()
    }
}

// MARK: - Models

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let assets: [GitHubAsset]

    var version: String { tagName }

    var preferredDownloadAsset: GitHubAsset? {
        if let dmg = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) {
            return dmg
        }
        if let zip = assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) {
            return zip
        }
        return assets.first
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private enum UpdateError: LocalizedError {
    case invalidResponse
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return t("GitHub returned an unexpected response.", "GitHub 返回了无法识别的响应。")
        case .downloadFailed:
            return t("The update file could not be downloaded.", "无法下载更新文件。")
        }
    }
}
