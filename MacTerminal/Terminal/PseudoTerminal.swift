import Foundation

class PseudoTerminal: ObservableObject {
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?

    // UTF-8 remainder bytes from previous read (accessed only from read queue)
    private var utf8Remainder = Data()

    /// Password to auto-send when an SSH password prompt is detected (one-shot).
    var pendingPassword: String?
    /// Buffer accumulating recent output for prompt detection (accessed only from read queue).
    private var passwordBuffer = ""

    var onOutput: ((Data) -> Void)?
    var onProcessExit: (() -> Void)?

    var isRunning: Bool { childPID > 0 }

    func start(shell: String = "/bin/zsh", workingDirectory: String? = nil) {
        if isRunning { stop() }

        var master: Int32 = 0
        var ws = winsize(ws_row: 25, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

        let pid = forkpty(&master, nil, nil, &ws)

        if pid == 0 {
            // Child process
            let dir = workingDirectory ?? NSHomeDirectory()
            chdir(dir)

            setenv("TERM", "xterm-256color", 1)
            setenv("TERM_PROGRAM", "Apple_Terminal", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            setenv("LC_ALL", "en_US.UTF-8", 1)

            var args: [UnsafeMutablePointer<CChar>?] = [
                strdup(shell),
                strdup("--login"),
                nil
            ]
            execv(shell, &args)
            _exit(1)
        } else if pid > 0 {
            // Parent process
            self.masterFD = master
            self.childPID = pid
            startReading()
        } else {
            print("forkpty failed: \(String(cString: strerror(errno)))")
        }
    }

    private func startReading() {
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                var data = Data(buffer[0..<n])

                // Prepend leftover bytes from previous read
                if !self.utf8Remainder.isEmpty {
                    data = self.utf8Remainder + data
                    self.utf8Remainder = Data()
                }

                // Split at the last complete UTF-8 boundary
                let (complete, remainder) = Self.splitUTF8(data)
                self.utf8Remainder = remainder

                // Auto-password: detect SSH password prompt and send stored password
                if let password = self.pendingPassword,
                   let text = String(data: complete, encoding: .utf8) {
                    self.passwordBuffer += text
                    // Keep buffer from growing unbounded (last 256 chars is enough)
                    if self.passwordBuffer.count > 256 {
                        self.passwordBuffer = String(self.passwordBuffer.suffix(256))
                    }
                    if self.passwordBuffer.range(of: "password:", options: .caseInsensitive) != nil {
                        let payload = password + "\r"
                        self.pendingPassword = nil
                        self.passwordBuffer = ""
                        self.writeData(Data(payload.utf8))
                    }
                }

                if !complete.isEmpty {
                    DispatchQueue.main.async {
                        self.onOutput?(complete)
                    }
                }
            } else if n == 0 || (n < 0 && errno != EINTR) {
                // EOF or error — shell exited.
                // Stop on main thread to cancel readSource and prevent re-firing.
                DispatchQueue.main.async {
                    guard self.isRunning else { return }
                    self.stop()
                    self.onProcessExit?()
                }
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.masterFD >= 0 {
                close(self.masterFD)
                self.masterFD = -1
            }
        }
        source.resume()
        self.readSource = source
    }

    /// Splits data at the last complete UTF-8 character boundary.
    /// Returns (complete bytes, incomplete trailing bytes).
    private static func splitUTF8(_ data: Data) -> (complete: Data, remainder: Data) {
        if data.isEmpty { return (data, Data()) }

        let bytes = [UInt8](data)
        var i = bytes.count - 1
        let limit = max(0, bytes.count - 4)

        while i >= limit {
            let b = bytes[i]
            if b & 0x80 == 0 {
                // ASCII byte — everything is complete
                return (data, Data())
            } else if b & 0xC0 != 0x80 {
                // Leading byte found — check if sequence is complete
                let expectedLen: Int
                if b & 0xF8 == 0xF0 { expectedLen = 4 }
                else if b & 0xF0 == 0xE0 { expectedLen = 3 }
                else if b & 0xE0 == 0xC0 { expectedLen = 2 }
                else { return (data, Data()) } // Invalid, pass through

                let actualLen = bytes.count - i
                if actualLen < expectedLen {
                    // Incomplete UTF-8 sequence at end
                    return (Data(bytes[0..<i]), Data(bytes[i...]))
                } else {
                    // Sequence is complete
                    return (data, Data())
                }
            }
            i -= 1
        }

        return (data, Data())
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        writeData(data)
    }

    func writeData(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(masterFD, base + written, data.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    func stop() {
        let source = readSource
        readSource = nil
        utf8Remainder = Data()

        let pid = childPID
        let fd = masterFD
        childPID = -1
        masterFD = -1

        source?.cancel()

        // Close master FD to send EOF to slave side
        if fd >= 0 {
            close(fd)
        }

        if pid > 0 {
            // Kill entire process group (shell + all child processes)
            kill(-pid, SIGHUP)
            kill(-pid, SIGTERM)

            // Reap zombie process on background queue
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == 0 {
                    usleep(100_000) // 100ms grace period
                    kill(-pid, SIGKILL)
                    waitpid(pid, &status, 0)
                }
            }
        }
    }

    deinit {
        stop()
    }
}
