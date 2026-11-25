import AppKit
import CadenceCore
import Darwin

/// Notices when Cadence crashes, gets it reopened, and says what happened on the next launch.
///
/// - A signal handler writes a small marker file as the app goes down (only async-signal-safe calls:
///   open/write/close and backtrace_symbols_fd), then lets the crash carry on so macOS still writes
///   its own crash report.
/// - `cadence-watchdog`, a tiny helper started at launch, waits for the app to exit. A marker means it
///   crashed, so the watchdog opens it again (with `--after-crash`), unless it keeps crashing.
/// - On launch a marker means the last run crashed: it's read together with macOS's crash report from
///   ~/Library/Logs/DiagnosticReports and shown in a panel that can open a pre-filled GitHub issue.
@MainActor
final class CrashReporter {
    nonisolated static let files = CrashFiles.standard
    private var watchdog: Process?

    /// The last run's crash, if it crashed. Clears the marker so it's reported once.
    func takePreviousCrash() -> CrashReport? {
        let files = Self.files
        let fm = FileManager.default
        defer {
            try? fm.removeItem(at: files.marker)
            try? fm.removeItem(at: files.exception)
        }
        guard let text = try? String(contentsOf: files.marker, encoding: .utf8) else { return nil }
        let marker = CrashMarker(parsing: text)
        let exception = (try? String(contentsOf: files.exception, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let when = marker.crashed ?? Date()
        let recent = CrashLoopGuard.recent(files.readHistory(), now: when.addingTimeInterval(5)).count
        return CrashReport(marker: marker, exception: exception?.isEmpty == false ? exception : nil,
                           restarted: CommandLine.arguments.contains("--after-crash"),
                           recentCrashes: max(1, recent))
    }

    /// Catches crashes from now on.
    func install() {
        CrashSignals.install(files: Self.files)
        NSSetUncaughtExceptionHandler { exception in
            // Not in a signal handler yet, so Foundation is fine here. The abort that follows writes the marker.
            let text = "\(exception.name.rawValue): \(exception.reason ?? "no reason given")"
            try? text.write(to: CrashReporter.files.exception, atomically: false, encoding: .utf8)
        }
    }

    /// Starts or stops the helper that reopens Cadence after a crash.
    func setRestartsAfterCrash(_ on: Bool) {
        if on, watchdog?.isRunning != true {
            startWatchdog()
        } else if !on, let watchdog {
            if watchdog.isRunning { watchdog.terminate() }
            self.watchdog = nil
        }
    }

    private func startWatchdog() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cadence-watchdog")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }
        let process = Process()
        process.executableURL = helper
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), Self.files.directory.path,
                             Bundle.main.bundleURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            watchdog = process
        } catch {
            NSLog("Cadence: couldn't start the crash watchdog: \(error.localizedDescription)")
        }
    }

    // MARK: - macOS's crash report

    nonisolated static var diagnosticReports: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// The crash report macOS wrote for this crash: a Cadence-*.ips from around when it happened.
    nonisolated static func findLog(near date: Date, in folder: URL = diagnosticReports) -> CrashLog? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return nil }
        let candidates = files.compactMap { url -> (URL, Date)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("Cadence-"), name.hasSuffix(".ips"),
                  let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  modified > date.addingTimeInterval(-60), modified < date.addingTimeInterval(300) else { return nil }
            return (url, modified)
        }
        .sorted { abs($0.1.timeIntervalSince(date)) < abs($1.1.timeIntervalSince(date)) }
        for (url, _) in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8), let log = CrashLog(ips: text),
                  log.appName == "Cadence" else { continue }
            return log
        }
        return nil
    }

    /// "macOS 26.1.0"
    nonisolated static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// The signal handler. Everything it touches is set up before it's installed and never changed, and
/// it calls nothing that allocates or takes a lock.
private enum CrashSignals {
    static let signals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGSYS]

    nonisolated(unsafe) static var path: UnsafeMutablePointer<CChar>?
    /// "version=…\nbuild=…\nlaunched=…\n", written ahead of what's only known at crash time.
    nonisolated(unsafe) static var prefix: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) static var prefixLength = 0
    nonisolated(unsafe) static var digits = UnsafeMutablePointer<CChar>.allocate(capacity: 24)
    nonisolated(unsafe) static var frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
    nonisolated(unsafe) static var altStack: UnsafeMutableRawPointer?

    static func install(files: CrashFiles) {
        try? FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let head = "version=\(version)\nbuild=\(build)\nlaunched=\(Int(Date().timeIntervalSince1970))\n"
        path = strdup(files.marker.path)
        prefix = strdup(head)
        prefixLength = strlen(prefix!)
        _ = digits
        _ = frames

        // Its own stack, so a stack overflow can still be recorded.
        let size = Int(SIGSTKSZ) * 4
        altStack = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        var stack = stack_t(ss_sp: altStack, ss_size: size, ss_flags: 0)
        sigaltstack(&stack, nil)

        for sig in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = handle
            action.sa_flags = SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
    }

    static let handle: @convention(c) (Int32) -> Void = { sig in
        // Back to the default, so returning (or a second fault) crashes as normal and macOS reports it.
        signal(sig, SIG_DFL)
        guard let path = CrashSignals.path else { return }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        if let prefix = CrashSignals.prefix { _ = write(fd, prefix, CrashSignals.prefixLength) }
        put(fd, "signal=")
        number(fd, Int(sig))
        put(fd, "\ntime=")
        number(fd, Int(time(nil)))
        put(fd, "\nbacktrace:\n")
        let count = backtrace(CrashSignals.frames, 128)
        backtrace_symbols_fd(CrashSignals.frames, count, fd)
        close(fd)
    }

    /// Writes a string literal (static storage, so no allocation).
    private static func put(_ fd: Int32, _ text: StaticString) {
        _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
    }

    private static func number(_ fd: Int32, _ value: Int) {
        var n = value < 0 ? 0 : value
        var i = 23
        repeat {
            CrashSignals.digits[i] = CChar(48 + n % 10)
            n /= 10
            i -= 1
        } while n > 0 && i >= 0
        _ = write(fd, CrashSignals.digits + i + 1, 23 - i)
    }
}
