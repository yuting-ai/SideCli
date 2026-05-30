//
//  TerminalSession.swift
//  SideCli
//
//  Terminal session model for managing individual terminal instances
//

import Foundation
import Combine

enum TerminalState: Equatable {
    case idle
    case running
    case finished(Int32)  // exit code
}

class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    let createdAt: Date
    @Published var title: String
    @Published var state: TerminalState = .idle
    @Published var isActive: Bool = false
    var lastOutputAt: Date?
    /// 当前工作目录（来自 OSC 7），格式如 ~/Projects/MyApp，用于 tooltip
    @Published var currentDirectory: String?
    /// 当前工作目录的原始绝对路径（来自 OSC 7），用于新建 session 时传入 startingDirectory
    @Published var currentDirectoryRawPath: String?
    /// 新建 session 时的起始目录（绝对路径），nil 表示 home 目录
    var startingDirectory: String?

    private var process: Process?
    private var ptyMaster: Int32 = -1
    private var ptySlave: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.sidecli.terminal.\(UUID().uuidString)", qos: .userInitiated)
    private(set) var userHasRenamedTab = false
    private var lastCols = 80
    private var lastRows = 24

    var onDataReceived: ((Data) -> Void)?

    init(title: String? = nil, startingDirectory: String? = nil) {
        self.id = UUID()
        self.createdAt = Date()
        self.title = title ?? "Terminal \(String(id.uuidString.prefix(8)))"
        self.startingDirectory = startingDirectory
    }

    func start() {
        guard state == .idle else { return }

        var master: Int32 = 0
        var slave: Int32 = 0

        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            state = .finished(1)
            return
        }

        ptyMaster = master
        ptySlave = slave

        let flags = fcntl(ptyMaster, F_GETFL)
        _ = fcntl(ptyMaster, F_SETFL, flags | O_NONBLOCK)
        // Apply the latest known terminal size before launching the shell.
        // Without this, split panes may boot with PTY default 80x24 and only
        // get resized later, which can corrupt first-prompt rendering.
        resize(cols: lastCols, rows: lastRows)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l"]

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        // Use Apple_Terminal so macOS's built-in zsh precmd emits OSC 7 (cwd notification)
        environment["TERM_PROGRAM"] = "Apple_Terminal"
        environment["TERM_PROGRAM_VERSION"] = "SideCli"
        // Prevent zsh from rendering the default end-of-line marker ("%") when prompt
        // lines are reflowed during early resize events (common when opening split panes).
        environment["PROMPT_EOL_MARK"] = ""
        process.environment = environment

        process.currentDirectoryURL = URL(fileURLWithPath: startingDirectory ?? NSHomeDirectory())
        process.standardInput = FileHandle(fileDescriptor: ptySlave)
        process.standardOutput = FileHandle(fileDescriptor: ptySlave)
        process.standardError = FileHandle(fileDescriptor: ptySlave)

        do {
            try process.run()
            self.process = process
            state = .running

            setupReadSource()

            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    self?.cleanup()
                    self?.state = .finished(process.terminationStatus)
                }
            }

        } catch {
            cleanup()
            state = .finished(1)
        }
    }

    func write(_ data: Data) {
        guard state == .running, ptyMaster >= 0 else { return }

        queue.async { [weak self] in
            data.withUnsafeBytes { bytes in
                _ = Darwin.write(self?.ptyMaster ?? -1, bytes.baseAddress, data.count)
            }
        }
    }

    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }

    func resize(cols: Int, rows: Int) {
        lastCols = cols
        lastRows = rows
        guard ptyMaster >= 0 else { return }
        var winsize = winsize()
        winsize.ws_col = UInt16(cols)
        winsize.ws_row = UInt16(rows)
        _ = ioctl(ptyMaster, TIOCSWINSZ, &winsize)
    }

    func terminate() {
        process?.terminate()
        cleanup()
    }

    /// Returns true only when a foreground task (other than the shell itself)
    /// is currently attached to this terminal session.
    func hasForegroundTask() -> Bool {
        guard state == .running,
              let process else { return false }

        let shellPid = pid_t(process.processIdentifier)
        let shellPgid = getpgid(shellPid)
        guard shellPgid > 0 else { return false }

        guard let foregroundPgid = currentForegroundProcessGroup(),
              foregroundPgid > 0 else { return false }

        return foregroundPgid != shellPgid
    }

    @discardableResult
    func handleTerminalControlInput(_ data: String) -> Bool {
        guard data.unicodeScalars.count == 1,
              let scalar = data.unicodeScalars.first,
              scalar.value <= 0xff else {
            return false
        }

        let code = UInt8(scalar.value)
        switch code {
        case 0x03: // Ctrl+C
            sendSignalOrWriteControlChar(signal: SIGINT, controlChar: code, termiosIndex: Int(VINTR))
            return true
        case 0x1a: // Ctrl+Z
            sendSignalOrWriteControlChar(signal: SIGTSTP, controlChar: code, termiosIndex: Int(VSUSP))
            return true
        case 0x1c: // Ctrl+\
            sendSignalOrWriteControlChar(signal: SIGQUIT, controlChar: code, termiosIndex: Int(VQUIT))
            return true
        default:
            return false
        }
    }

    func sendInterrupt() {
        sendSignalToForegroundProcessGroup(SIGINT)
    }

    func sendSuspend() {
        sendSignalToForegroundProcessGroup(SIGTSTP)
    }

    func sendQuit() {
        sendSignalToForegroundProcessGroup(SIGQUIT)
    }

    private func sendSignalOrWriteControlChar(signal: Int32, controlChar: UInt8, termiosIndex: Int) {
        if shouldGenerateSignal(for: controlChar, termiosIndex: termiosIndex) {
            sendSignalToForegroundProcessGroup(signal)
        } else {
            write(Data([controlChar]))
        }
    }

    private func shouldGenerateSignal(for controlChar: UInt8, termiosIndex: Int) -> Bool {
        guard let term = readTerminalAttributes() else { return true }

        let isigEnabled = (term.c_lflag & tcflag_t(ISIG)) != 0
        guard isigEnabled else { return false }

        guard let configuredChar = configuredControlChar(in: term, at: termiosIndex) else {
            return true
        }
        return configuredChar == controlChar
    }

    private func readTerminalAttributes() -> termios? {
        var term = termios()
        for fd in [ptySlave, ptyMaster] where fd >= 0 {
            if tcgetattr(fd, &term) == 0 {
                return term
            }
        }
        return nil
    }

    private func currentForegroundProcessGroup() -> pid_t? {
        for fd in [ptySlave, ptyMaster] where fd >= 0 {
            let pgid = tcgetpgrp(fd)
            if pgid > 0 { return pgid }
        }
        return nil
    }

    private func configuredControlChar(in term: termios, at index: Int) -> UInt8? {
        guard index >= 0, index < Int(NCCS) else { return nil }
        return withUnsafePointer(to: term.c_cc) { ptr in
            ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cPtr in
                UInt8(cPtr[index])
            }
        }
    }

    private func sendSignalToForegroundProcessGroup(_ signal: Int32) {
        guard state == .running else { return }
        queue.async { [weak self] in
            guard let self = self else { return }

            // 1) Best-effort: signal terminal foreground process group from PTY.
            for fd in [self.ptyMaster, self.ptySlave] where fd >= 0 {
                let foregroundPgid = tcgetpgrp(fd)
                if foregroundPgid > 0 {
                    _ = Darwin.kill(-foregroundPgid, signal)
                    return
                }
            }

            guard let process = self.process else { return }
            let shellPid = pid_t(process.processIdentifier)

            // 2) Fallback: signal the shell's process group directly.
            let shellPgid = getpgid(shellPid)
            if shellPgid > 0 {
                _ = Darwin.kill(-shellPgid, signal)
                return
            }

            // 3) Last resort: signal the shell process itself.
            _ = Darwin.kill(shellPid, signal)
        }
    }

    private func cleanup() {
        readSource?.cancel()
        readSource = nil

        if ptyMaster >= 0 {
            close(ptyMaster)
            ptyMaster = -1
        }

        if ptySlave >= 0 {
            close(ptySlave)
            ptySlave = -1
        }
    }

    private func setupReadSource() {
        guard ptyMaster >= 0 else { return }

        readSource = DispatchSource.makeReadSource(fileDescriptor: ptyMaster, queue: queue)
        readSource?.setEventHandler { [weak self] in
            guard let self = self else { return }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(self.ptyMaster, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)
                self.parseOSCSequences(from: [UInt8](data))
                DispatchQueue.main.async {
                    self.lastOutputAt = Date()
                    self.onDataReceived?(data)
                }
            } else if bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN) {
                // EOF or error
                DispatchQueue.main.async {
                    self.cleanup()
                }
            }
        }

        readSource?.setCancelHandler { [weak self] in
            self?.cleanup()
        }

        readSource?.resume()
    }

    // MARK: - OSC Sequence Parsing

    /// Scans raw PTY bytes for OSC sequences:
    ///   OSC 2  – window title  → update tab title (if not user-renamed)
    ///   OSC 7  – cwd URL       → update tab title to last path component + store full path
    private func parseOSCSequences(from bytes: [UInt8]) {
        var i = 0
        while i < bytes.count {
            // ESC ]
            guard bytes[i] == 0x1b, i + 1 < bytes.count, bytes[i + 1] == 0x5d else { i += 1; continue }

            // Scan for BEL (0x07) or ST (ESC \)
            var end = i + 2
            var found = false
            while end < bytes.count {
                if bytes[end] == 0x07 { found = true; break }
                if bytes[end] == 0x1b, end + 1 < bytes.count, bytes[end + 1] == 0x5c { found = true; break }
                end += 1
            }
            guard found else { break }

            let payload = Array(bytes[(i + 2)..<end])

            // OSC 2: "2;title"
            if payload.starts(with: [0x32, 0x3b]) {
                let titleBytes = Array(payload.dropFirst(2))
                if let oscTitle = String(bytes: titleBytes, encoding: .utf8),
                   !oscTitle.isEmpty, !userHasRenamedTab {
                    DispatchQueue.main.async { [weak self] in self?.title = oscTitle }
                }
            }

            // OSC 7: "7;file://hostname/path"
            if payload.starts(with: [0x37, 0x3b]) {
                let urlBytes = Array(payload.dropFirst(2))
                if let urlString = String(bytes: urlBytes, encoding: .utf8),
                   let url = URL(string: urlString) {
                    let path = url.path
                    let home = NSHomeDirectory()

                    // 格式化完整路径用于 tooltip（~/... 形式）
                    let displayPath: String
                    if path == home {
                        displayPath = "~"
                    } else if path.hasPrefix(home + "/") {
                        displayPath = "~" + path.dropFirst(home.count)
                    } else {
                        displayPath = path
                    }

                    // Tab 标题只显示最后一个目录名
                    let lastComponent = URL(fileURLWithPath: path).lastPathComponent
                    let tabTitle = lastComponent.isEmpty ? "~" : lastComponent

                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.currentDirectory = displayPath
                        self.currentDirectoryRawPath = path
                        if !self.userHasRenamedTab {
                            self.title = tabTitle
                        }
                    }
                }
            }

            i = bytes[end] == 0x07 ? end + 1 : end + 2
        }
    }

    /// Call this when the user explicitly renames the tab to stop cwd auto-updates.
    func markUserRenamed() {
        userHasRenamedTab = true
    }

    deinit {
        cleanup()
    }
}

// MARK: - Darwin C Declarations
import Darwin

private let TIOCSWINSZ: UInt = 0x80087467

private struct winsize {
    var ws_row: UInt16 = 0
    var ws_col: UInt16 = 0
    var ws_xpixel: UInt16 = 0
    var ws_ypixel: UInt16 = 0
}
