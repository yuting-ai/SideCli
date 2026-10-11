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
    // PTY fds. After start() hands them over, they are only read / changed on
    // `queue`, and only closed by the read source's cancel handler, so a pending
    // write can never hit a closed (or already reused) descriptor.
    private var ptyMaster: Int32 = -1
    private var ptySlave: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.sidecli.terminal.\(UUID().uuidString)", qos: .userInitiated)
    private(set) var userHasRenamedTab = false
    private var lastCols = 80
    private var lastRows = 24

    private(set) var onDataReceived: ((Data) -> Void)?
    /// Who installed onDataReceived. Lets a stale terminal view clear only its own
    /// handler, never one installed by a newer view for the same session.
    private var dataReceiverOwner: ObjectIdentifier?

    /// Main thread only.
    func setDataReceiver(owner: AnyObject, _ handler: @escaping (Data) -> Void) {
        dataReceiverOwner = ObjectIdentifier(owner)
        onDataReceived = handler
    }

    /// Main thread only. No-op if another owner has taken over since.
    func clearDataReceiver(owner: AnyObject) {
        guard dataReceiverOwner == ObjectIdentifier(owner) else { return }
        dataReceiverOwner = nil
        onDataReceived = nil
    }

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

        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        // Apply the latest known terminal size before launching the shell.
        // Without this, split panes may boot with PTY default 80x24 and only
        // get resized later, which can corrupt first-prompt rendering.
        Self.setWindowSize(fd: master, cols: lastCols, rows: lastRows)

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

        process.currentDirectoryURL = URL(fileURLWithPath: Self.usableDirectory(startingDirectory))
        process.standardInput = FileHandle(fileDescriptor: slave)
        process.standardOutput = FileHandle(fileDescriptor: slave)
        process.standardError = FileHandle(fileDescriptor: slave)

        do {
            try process.run()
        } catch {
            close(master)
            close(slave)
            state = .finished(1)
            return
        }

        // Nothing has been dispatched to `queue` yet, so this hand-off is safe;
        // from here on the fds belong to `queue`.
        ptyMaster = master
        ptySlave = slave
        self.process = process
        state = .running

        setupReadSource()

        process.terminationHandler = { [weak self] process in
            self?.queue.async { self?.teardownOnQueue() }
            DispatchQueue.main.async {
                self?.state = .finished(process.terminationStatus)
            }
        }
    }

    /// `path` if it is an existing directory, otherwise home. A restored or
    /// split-from directory may have been deleted, and Process.run() would
    /// then fail and the tab would die immediately with exit code 1.
    private static func usableDirectory(_ path: String?) -> String {
        var isDirectory: ObjCBool = false
        if let path, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return path
        }
        return NSHomeDirectory()
    }

    func write(_ data: Data) {
        guard state == .running else { return }
        queue.async { [weak self] in
            self?.writeOnQueue(data)
        }
    }

    /// Must run on `queue`.
    private func writeOnQueue(_ data: Data) {
        let fd = ptyMaster
        guard fd >= 0 else { return }   // already torn down
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            var totalWritten = 0
            var retries = 0
            while totalWritten < data.count {
                let chunkSize = min(data.count - totalWritten, 1024)
                let ptr = baseAddress.advanced(by: totalWritten)
                let written = Darwin.write(fd, ptr, chunkSize)

                if written > 0 {
                    totalWritten += written
                    retries = 0
                } else if written < 0 {
                    // Give up after ~2s of a full buffer (e.g. the foreground job is
                    // stopped) instead of blocking this queue — and teardown — forever.
                    if (errno == EAGAIN || errno == EINTR) && retries < 2000 {
                        retries += 1
                        usleep(1000) // Sleep for 1ms and retry
                    } else {
                        break // Unrecoverable error
                    }
                } else {
                    break
                }
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
        queue.async { [weak self] in
            guard let self, self.ptyMaster >= 0 else { return }
            Self.setWindowSize(fd: self.ptyMaster, cols: cols, rows: rows)
        }
    }

    private static func setWindowSize(fd: Int32, cols: Int, rows: Int) {
        var winsize = winsize()
        winsize.ws_col = UInt16(clamping: cols)
        winsize.ws_row = UInt16(clamping: rows)
        _ = ioctl(fd, TIOCSWINSZ, &winsize)
    }

    func terminate() {
        process?.terminate()
        queue.async { [weak self] in
            self?.teardownOnQueue()
        }
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
        guard state == .running else { return }
        // termios lives on the fds, so decide on `queue` like every other fd access.
        queue.async { [weak self] in
            guard let self else { return }
            if self.shouldGenerateSignal(for: controlChar, termiosIndex: termiosIndex) {
                self.signalForegroundProcessGroupOnQueue(signal)
            } else {
                self.writeOnQueue(Data([controlChar]))
            }
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
            self?.signalForegroundProcessGroupOnQueue(signal)
        }
    }

    /// Must run on `queue`.
    private func signalForegroundProcessGroupOnQueue(_ signal: Int32) {
        // 1) Best-effort: signal terminal foreground process group from PTY.
        for fd in [ptyMaster, ptySlave] where fd >= 0 {
            let foregroundPgid = tcgetpgrp(fd)
            if foregroundPgid > 0 {
                _ = Darwin.kill(-foregroundPgid, signal)
                return
            }
        }

        guard let process = process, process.isRunning else { return }
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

    /// Must run on `queue`. Idempotent. Marks the fds unusable immediately; the
    /// actual close() happens in the read source's cancel handler, which is the
    /// only point where GCD guarantees it no longer touches the descriptor.
    private func teardownOnQueue() {
        let master = ptyMaster, slave = ptySlave
        ptyMaster = -1
        ptySlave = -1
        if let source = readSource {
            readSource = nil
            source.cancel()
        } else {
            Self.closeDescriptors(master: master, slave: slave)
        }
    }

    private static func closeDescriptors(master: Int32, slave: Int32) {
        if master >= 0 { close(master) }
        if slave >= 0 { close(slave) }
    }

    private func setupReadSource() {
        guard ptyMaster >= 0 else { return }

        let master = ptyMaster, slave = ptySlave
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self, self.ptyMaster >= 0 else { return }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(self.ptyMaster, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)
                DispatchQueue.main.async {
                    self.lastOutputAt = Date()
                    self.onDataReceived?(data)
                }
            } else if bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN && errno != EINTR) {
                // EOF or error: tear down right here on `queue` so the level-triggered
                // source stops firing instead of spinning until the main thread catches up.
                self.teardownOnQueue()
            }
        }

        // Captures the fd values, not self, so it also works when fired from deinit.
        source.setCancelHandler {
            Self.closeDescriptors(master: master, slave: slave)
        }

        readSource = source
        source.resume()
    }

    // MARK: - Title / cwd updates (fed by SwiftTerm's OSC parser)

    /// OSC 0 / 2 window title. Called on the main thread by the terminal view.
    func applyTerminalTitle(_ oscTitle: String) {
        guard !oscTitle.isEmpty, !userHasRenamedTab else { return }
        title = oscTitle
    }

    /// OSC 7 payload, e.g. "file://hostname/Users/me/Projects".
    /// Called on the main thread by the terminal view.
    func applyWorkingDirectory(oscURL urlString: String) {
        guard let url = URL(string: urlString), url.isFileURL || url.scheme == nil else { return }
        let path = url.path
        guard !path.isEmpty else { return }
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

        currentDirectory = displayPath
        currentDirectoryRawPath = path
        if !userHasRenamedTab {
            title = tabTitle
        }
    }

    /// Call this when the user explicitly renames the tab to stop cwd auto-updates.
    func markUserRenamed() {
        userHasRenamedTab = true
    }

    deinit {
        // No other references exist now, so touching the fields directly is safe.
        if let source = readSource {
            source.cancel()   // cancel handler closes the fds
        } else {
            Self.closeDescriptors(master: ptyMaster, slave: ptySlave)
        }
    }
}
