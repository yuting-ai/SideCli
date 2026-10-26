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

    /// Shell process; 0 once it has exited and been reaped. Read and changed on `queue`
    /// after start().
    private var shellPID: pid_t = 0
    private var exitSource: DispatchSourceProcess?
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

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        // Use Apple_Terminal so macOS's built-in zsh precmd emits OSC 7 (cwd notification)
        environment["TERM_PROGRAM"] = "Apple_Terminal"
        environment["TERM_PROGRAM_VERSION"] = "SideCli"
        // Prevent zsh from rendering the default end-of-line marker ("%") when prompt
        // lines are reflowed during early resize events (common when opening split panes).
        environment["PROMPT_EOL_MARK"] = ""

        // Start at the latest known terminal size. Without this, split panes may
        // boot with PTY default 80x24 and only get resized later, which can corrupt
        // first-prompt rendering.
        var size = winsize()
        size.ws_col = UInt16(clamping: lastCols)
        size.ws_row = UInt16(clamping: lastRows)

        guard let (pid, master) = Self.spawnShell(shell, directory: Self.usableDirectory(startingDirectory),
                                                  environment: environment, size: &size) else {
            state = .finished(1)
            return
        }
        // Our own handle on the tty, only for reading its termios / foreground group.
        let slave = open(ptsname(master), O_RDWR | O_NOCTTY | O_CLOEXEC)
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        // Shells started later must not inherit this pane's PTY: it would keep the
        // tty open after the pane closes, so its shell would never get SIGHUP.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        // Nothing has been dispatched to `queue` yet, so this hand-off is safe;
        // from here on the fds belong to `queue`.
        ptyMaster = master
        ptySlave = slave
        shellPID = pid
        state = .running
        Self.live.add(self)

        setupReadSource()
        watchForExit(pid)
    }

    /// Starts `shell` as a login shell in a new session whose controlling terminal is
    /// a new PTY, like Terminal.app does, and returns its pid and the PTY's master.
    /// Foundation's Process can't do that, and without a controlling terminal resizing
    /// the PTY never sends SIGWINCH, so TUIs (pi, opencode, vim…) kept drawing at
    /// their old size after a split, zoom or panel resize. posix_spawn can't either:
    /// it applies its file actions before POSIX_SPAWN_SETSID.
    ///
    /// Everything the child needs is prepared before forkpty, and the child only
    /// makes async-signal-safe calls.
    private static func spawnShell(_ shell: String, directory: String, environment: [String: String],
                                   size: inout winsize) -> (pid: pid_t, master: Int32)? {
        let argv = [shell, "-l"].map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cwd = strdup(directory)
        defer { (argv + envp + [cwd]).forEach { free($0) } }
        guard let cwd, let program = argv[0] else { return nil }

        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        let maxDescriptor = getdtablesize()

        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            // Don't leak the app's descriptors into the shell.
            var fd: Int32 = 3
            while fd < maxDescriptor { _ = close(fd); fd += 1 }
            _ = chdir(cwd)
            // Default signal handling and an empty mask, like a fresh login.
            var signalNumber: Int32 = 1
            while signalNumber < NSIG { _ = signal(signalNumber, SIG_DFL); signalNumber += 1 }
            _ = sigprocmask(SIG_SETMASK, &noSignals, nil)
            _ = execve(program, argv, envp)
            _exit(127)
        }
        return pid > 0 ? (pid, master) : nil
    }

    /// Reaps the shell when it exits and tears the session down.
    private func watchForExit(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.reapShellOnQueue() }
        exitSource = source
        source.resume()
        // The shell may already have exited before the source was armed.
        queue.async { [weak self] in self?.reapShellOnQueue() }
    }

    /// Must run on `queue`.
    private func reapShellOnQueue() {
        guard shellPID > 0 else { return }
        var status: Int32 = 0
        guard waitpid(shellPID, &status, WNOHANG) == shellPID else { return }
        shellPID = 0
        exitSource?.cancel()
        exitSource = nil
        teardownOnQueue()
        // Exit code, or the terminating signal's number (as Process reported it).
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
        DispatchQueue.main.async { [weak self] in
            self?.state = .finished(code)
        }
    }

    /// `path` if it is an existing directory, otherwise home. A restored or
    /// split-from directory may have been deleted, and posix_spawn would
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

    /// Every session that has started a shell (held weakly), across all tabs.
    private static let live = NSHashTable<TerminalSession>.weakObjects()

    /// Programs (not just shells) running in any session: quitting would end them.
    static func runningProgramNames() -> [String] {
        live.allObjects.compactMap { $0.foregroundProcessName() }
    }

    /// Starts a fresh shell in a session whose shell has exited (same pane, same size).
    func restart() {
        guard case .finished = state else { return }
        queue.sync {}   // let the old shell's teardown finish before reusing the fields
        state = .idle
        start()
    }

    /// Name of the program running in the foreground (pi, vim, npm…), or nil when the
    /// shell itself is waiting at its prompt. Closing would end that program.
    func foregroundProcessName() -> String? {
        guard state == .running else { return nil }
        return queue.sync {
            guard shellPID > 0, let group = currentForegroundProcessGroup(), group != shellPID else { return nil }
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(group, &name, UInt32(name.count)) > 0 else { return "?" }
            return String(cString: name)
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
        queue.async { [weak self] in
            guard let self else { return }
            // Hang up like a closed terminal window; an interactive zsh ignores SIGTERM.
            if self.shellPID > 0 { _ = Darwin.kill(self.shellPID, SIGHUP) }
            self.teardownOnQueue()
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

        let shellPid = shellPID
        guard shellPid > 0 else { return }

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
        exitSource?.cancel()
        // Still running: hang it up and reap it off the main thread, so it can't
        // linger as a zombie.
        let pid = shellPID
        if pid > 0 {
            _ = Darwin.kill(pid, SIGHUP)
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
        }
    }
}
