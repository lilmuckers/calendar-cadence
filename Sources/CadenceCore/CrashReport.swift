import Foundation

/// Where crash detection keeps its files, shared by the app and its watchdog.
/// `marker` is written by the app's signal handler as it crashes; the watchdog sees it, notes the
/// crash in `history` and reopens the app; the reopened app reads the marker, shows what happened and
/// deletes it.
public struct CrashFiles: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Application Support/Cadence/Crashes.
    public static var standard: CrashFiles {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CrashFiles(directory: base.appendingPathComponent("Cadence/Crashes", isDirectory: true))
    }

    public var marker: URL { directory.appendingPathComponent("crashed.txt") }
    /// The uncaught Objective-C exception, if that's what brought it down.
    public var exception: URL { directory.appendingPathComponent("exception.txt") }
    /// When recent crashes happened (one Unix time per line), for the crash-loop guard.
    public var history: URL { directory.appendingPathComponent("history.txt") }

    public func readHistory() -> [Date] {
        guard let text = try? String(contentsOf: history, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { Double($0).map(Date.init(timeIntervalSince1970:)) }
    }

    public func writeHistory(_ dates: [Date]) {
        let text = dates.map { String(Int($0.timeIntervalSince1970)) }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.write(to: history, atomically: true, encoding: .utf8)
    }
}

/// Stops Cadence restarting itself over and over when it crashes as soon as it opens.
public enum CrashLoopGuard {
    public static let window: TimeInterval = 10 * 60
    /// Crashes within `window` (counting this one) after which it stops restarting.
    public static let limit = 3

    /// Crashes recent enough to count.
    public static func recent(_ crashes: [Date], now: Date) -> [Date] {
        crashes.filter { now.timeIntervalSince($0) < window && $0 <= now.addingTimeInterval(1) }
    }

    /// Whether to restart after a crash at `now`, given the recent ones (including this one).
    public static func shouldRelaunch(crashes: [Date], now: Date) -> Bool {
        recent(crashes, now: now).count < limit
    }
}

/// What the signal handler wrote as the app went down: `key=value` lines, then the raw backtrace.
public struct CrashMarker: Equatable, Sendable {
    public var version: String?
    public var build: String?
    public var launched: Date?
    public var crashed: Date?
    public var signal: Int32?
    public var backtrace: [String] = []

    public init(version: String? = nil, build: String? = nil, launched: Date? = nil, crashed: Date? = nil,
                signal: Int32? = nil, backtrace: [String] = []) {
        self.version = version
        self.build = build
        self.launched = launched
        self.crashed = crashed
        self.signal = signal
        self.backtrace = backtrace
    }

    public init(parsing text: String) {
        var inBacktrace = false
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if inBacktrace {
                let frame = line.trimmingCharacters(in: .whitespaces)
                if !frame.isEmpty { backtrace.append(frame) }
                continue
            }
            if line == "backtrace:" { inBacktrace = true; continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq], value = String(line[line.index(after: eq)...])
            switch key {
            case "version": version = value
            case "build": build = value
            case "launched": launched = Double(value).map(Date.init(timeIntervalSince1970:))
            case "time": crashed = Double(value).map(Date.init(timeIntervalSince1970:))
            case "signal": signal = Int32(value)
            default: break
            }
        }
    }
}

/// The useful parts of a macOS crash report (`~/Library/Logs/DiagnosticReports/Cadence-*.ips`):
/// a one-line JSON header followed by a JSON body.
public struct CrashLog: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public var image: String
        public var symbol: String?
        /// Offset into the symbol when there is one, else into the image.
        public var offset: Int

        public var text: String {
            if let symbol { return "\(image)  \(symbol) + \(offset)" }
            return "\(image)  0x\(String(offset, radix: 16))"
        }
    }

    public var appName: String?
    public var appVersion: String?
    public var build: String?
    public var osVersion: String?
    public var model: String?
    public var timestamp: Date?
    public var incident: String?
    /// e.g. EXC_BAD_ACCESS, EXC_CRASH, EXC_BREAKPOINT.
    public var exceptionType: String?
    /// e.g. SIGSEGV.
    public var signal: String?
    /// e.g. "Abort trap: 6".
    public var termination: String?
    /// Messages the system attached, like "abort() called" or a Swift fatal error.
    public var messages: [String] = []
    /// The UUID of the app's own binary, to symbolicate its frames.
    public var binaryUUID: String?
    public var crashedThread: Int?
    public var crashedQueue: String?
    public var frames: [Frame] = []
    /// Where an uncaught Objective-C exception was thrown from.
    public var exceptionFrames: [Frame] = []

    public init?(ips text: String) {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any]
        else { return nil }

        appName = header["app_name"] as? String ?? header["name"] as? String
        appVersion = header["app_version"] as? String
        build = header["build_version"] as? String
        osVersion = header["os_version"] as? String
        incident = header["incident_id"] as? String
        if let stamp = header["timestamp"] as? String { timestamp = Self.parseTimestamp(stamp) }
        model = body["modelCode"] as? String
        binaryUUID = header["slice_uuid"] as? String

        if let exception = body["exception"] as? [String: Any] {
            exceptionType = exception["type"] as? String
            signal = exception["signal"] as? String
        }
        if let term = body["termination"] as? [String: Any] { termination = term["indicator"] as? String }
        if let asi = body["asi"] as? [String: [String]] {
            messages = asi.keys.sorted().flatMap { asi[$0] ?? [] }
        }

        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        func frames(_ list: Any?) -> [Frame] {
            ((list as? [[String: Any]]) ?? []).map { f in
                let index = f["imageIndex"] as? Int ?? -1
                let image = images.indices.contains(index) ? (images[index]["name"] as? String ?? "???") : "???"
                let symbol = f["symbol"] as? String
                let offset = symbol != nil ? (f["symbolLocation"] as? Int ?? 0) : (f["imageOffset"] as? Int ?? 0)
                return Frame(image: image, symbol: symbol, offset: offset)
            }
        }
        if let faulting = body["faultingThread"] as? Int, let threads = body["threads"] as? [[String: Any]],
           threads.indices.contains(faulting) {
            crashedThread = faulting
            crashedQueue = threads[faulting]["queue"] as? String ?? threads[faulting]["name"] as? String
            self.frames = frames(threads[faulting]["frames"])
        }
        exceptionFrames = frames(body["lastExceptionBacktrace"])
    }

    /// "2026-11-25 10:53:35.00 +0000"
    static func parseTimestamp(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            f.dateFormat = format
            if let date = f.date(from: text) { return date }
        }
        return nil
    }
}

/// One crash, from the marker the app left and (when macOS wrote one) its crash report.
public struct CrashReport: Equatable, Sendable {
    public var marker: CrashMarker
    public var log: CrashLog?
    /// "NSInternalInconsistencyException: …" when an uncaught exception brought it down.
    public var exception: String?
    /// Reopened by the watchdog (rather than by hand, or not at all because of the crash-loop guard).
    public var restarted: Bool
    /// Crashes in the last few minutes, this one included.
    public var recentCrashes: Int

    public init(marker: CrashMarker, log: CrashLog? = nil, exception: String? = nil,
                restarted: Bool, recentCrashes: Int = 1) {
        self.marker = marker
        self.log = log
        self.exception = exception
        self.restarted = restarted
        self.recentCrashes = recentCrashes
    }

    public var date: Date? { log?.timestamp ?? marker.crashed }
    public var version: String? { marker.version ?? log?.appVersion }

    /// Signal name for the marker's signal number.
    public static func signalName(_ number: Int32) -> String {
        switch number {
        case SIGILL: "SIGILL"
        case SIGTRAP: "SIGTRAP"
        case SIGABRT: "SIGABRT"
        case SIGFPE: "SIGFPE"
        case SIGBUS: "SIGBUS"
        case SIGSEGV: "SIGSEGV"
        case SIGSYS: "SIGSYS"
        default: "signal \(number)"
        }
    }

    /// A short "what went wrong": the signal, plus the system's message when there is one.
    public var reason: String {
        let signal = log?.signal ?? marker.signal.map(Self.signalName) ?? "Unknown"
        if let exception { return "\(signal) · \(exception)" }
        if let message = log?.messages.first { return "\(signal) · \(message)" }
        if let termination = log?.termination { return "\(signal) · \(termination)" }
        return signal
    }

    /// Libraries that only pass a crash along (abort, signals, exception plumbing), skipped when
    /// naming where it happened.
    static let plumbing: Set<String> = [
        "libsystem_kernel.dylib", "libsystem_pthread.dylib", "libsystem_c.dylib", "libsystem_platform.dylib",
        "libc++abi.dylib", "libobjc.A.dylib", "libswiftCore.dylib", "libdispatch.dylib", "CoreFoundation",
    ]

    /// The first frame that isn't crash plumbing, for the issue title.
    public var culprit: String? {
        let frames = (log?.exceptionFrames.isEmpty == false ? log!.exceptionFrames : log?.frames) ?? []
        if let frame = frames.first(where: { !Self.plumbing.contains($0.image) }) {
            return frame.symbol ?? "\(frame.image) 0x\(String(frame.offset, radix: 16))"
        }
        // The handler's own backtrace: "3   Cadence   0x0000000100a3b2c4 $s7Cadence… + 12". The frames
        // up to _sigtramp are the handler itself.
        let trace = marker.backtrace
        let start = trace.firstIndex { $0.contains("_sigtramp") }.map { $0 + 1 } ?? 0
        return trace[start...].lazy.compactMap { line -> String? in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 4, !Self.plumbing.contains(String(cols[1])) else { return nil }
            return String(cols[3])
        }.first
    }

    public var issueTitle: String {
        let signal = log?.signal ?? marker.signal.map(Self.signalName) ?? "crash"
        if let culprit { return "Crash: \(signal) in \(culprit.prefix(90))" }
        return "Crash: \(signal)"
    }

    /// Everything a maintainer needs, as plain text. `home` is replaced with ~ so it doesn't give away
    /// the account name.
    public func details(home: String = NSHomeDirectory(), maxFrames: Int = 40) -> String {
        var lines: [String] = []
        let version = [version.map { "Cadence \($0)" }, (marker.build ?? log?.build).map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        lines.append([version.isEmpty ? "Cadence" : version, log?.osVersion, log?.model]
            .compactMap { $0 }.joined(separator: " · "))
        if let date {
            var when = "Crashed: " + Self.stamp(date)
            if let launched = marker.launched {
                when += " (\(Self.duration(date.timeIntervalSince(launched))) after launch)"
            }
            lines.append(when)
        }
        var what = "Exception: " + [log?.exceptionType, log?.signal ?? marker.signal.map(Self.signalName)]
            .compactMap { $0 }.joined(separator: " / ")
        if let termination = log?.termination { what += " — \(termination)" }
        lines.append(what)
        if let exception { lines.append("Uncaught exception: \(exception)") }
        lines.append(contentsOf: log?.messages ?? [])
        if let uuid = log?.binaryUUID { lines.append("Binary UUID: \(uuid)") }
        if let incident = log?.incident { lines.append("Incident: \(incident)") }

        if let log, !log.exceptionFrames.isEmpty {
            lines.append("")
            lines.append("Last exception backtrace:")
            lines.append(contentsOf: Self.numbered(log.exceptionFrames.map(\.text), max: maxFrames))
        }
        if let log, !log.frames.isEmpty {
            lines.append("")
            let queue = log.crashedQueue.map { " (\($0))" } ?? ""
            lines.append("Crashed thread \(log.crashedThread ?? 0)\(queue):")
            lines.append(contentsOf: Self.numbered(log.frames.map(\.text), max: maxFrames))
        } else if !marker.backtrace.isEmpty {
            lines.append("")
            lines.append("Backtrace:")
            lines.append(contentsOf: marker.backtrace.prefix(maxFrames))
        }
        return Self.scrub(lines.joined(separator: "\n"), home: home)
    }

    static func numbered(_ frames: [String], max: Int) -> [String] {
        var out = frames.prefix(max).enumerated().map { i, f in "\(String(i).padding(toLength: 3, withPad: " ", startingAt: 0)) \(f)" }
        if frames.count > max { out.append("…  \(frames.count - max) more") }
        return out
    }

    /// Takes the home folder (and so the account name) out of paths.
    public static func scrub(_ text: String, home: String) -> String {
        guard home.count > 1 else { return text }
        var out = text.replacingOccurrences(of: home, with: "~")
        let user = (home as NSString).lastPathComponent
        if user.count >= 3 { out = out.replacingOccurrences(of: "/Users/\(user)", with: "~") }
        return out
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return f.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}

/// Opens a pre-filled GitHub issue from the crash template. Nothing is sent until the user submits
/// the form on GitHub, where they can edit it first.
public enum CrashIssue {
    public static let template = "crash_report.yml"
    /// GitHub rejects very long URLs; the crash details are cut to keep it well under its ~8 KB limit.
    public static let maxURLLength = 7500

    public static func url(for report: CrashReport, note: String, macOS: String,
                           repository: String, home: String = NSHomeDirectory()) -> URL {
        var maxFrames = 40
        while true {
            var components = URLComponents(string: "https://github.com/\(repository)/issues/new")!
            var details = report.details(home: home, maxFrames: maxFrames)
            if maxFrames == 0 { details = String(details.prefix(3000)) }
            components.queryItems = [
                URLQueryItem(name: "template", value: template),
                URLQueryItem(name: "title", value: report.issueTitle),
                URLQueryItem(name: "what-happened", value: note.trimmingCharacters(in: .whitespacesAndNewlines)),
                URLQueryItem(name: "crash-log", value: details),
                URLQueryItem(name: "cadence-version", value: report.version ?? ""),
                URLQueryItem(name: "macos-version", value: report.log?.osVersion ?? macOS),
            ]
            // `+` isn't escaped by URLComponents but GitHub reads it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            let url = components.url!
            if url.absoluteString.count <= maxURLLength || maxFrames == 0 { return url }
            maxFrames = maxFrames > 10 ? maxFrames - 10 : 0
        }
    }
}
