import Foundation
import Testing
@testable import CadenceCore

/// A trimmed-down Cadence crash report, shaped like the ones macOS writes to DiagnosticReports.
private let ips = """
{"app_name":"Cadence","timestamp":"2026-11-25 10:53:35.00 +0000","app_version":"0.5.4","slice_uuid":"684e0faa-a6e3-3b3e-89cb-e308fa681a20","build_version":"14","bug_type":"309","os_version":"macOS 26.7.1 (25G241)","name":"Cadence","incident_id":"D5EAC750-762C-4111-B794-C53081824C88"}
{
  "modelCode" : "MacBookPro18,1",
  "procPath" : "/Users/someone/Applications/Cadence.app/Contents/MacOS/Cadence",
  "exception" : {"codes":"0x0, 0x0","type":"EXC_CRASH","signal":"SIGABRT"},
  "termination" : {"flags":0,"code":6,"namespace":"SIGNAL","indicator":"Abort trap: 6"},
  "asi" : {"libsystem_c.dylib":["abort() called"]},
  "lastExceptionBacktrace" : [
    {"imageOffset":100,"symbol":"__exceptionPreprocess","symbolLocation":176,"imageIndex":3},
    {"imageOffset":200,"symbol":"objc_exception_throw","symbolLocation":88,"imageIndex":2},
    {"imageOffset":300,"symbol":"-[NSWindow _layout]","symbolLocation":12,"imageIndex":4},
    {"imageOffset":4660,"imageIndex":0}
  ],
  "faultingThread" : 0,
  "threads" : [
    {"triggered":true,"id":1,"queue":"com.apple.main-thread","frames":[
      {"imageOffset":38376,"symbol":"__pthread_kill","symbolLocation":8,"imageIndex":1},
      {"imageOffset":493944,"symbol":"abort","symbolLocation":148,"imageIndex":5},
      {"imageOffset":904900,"symbol":"__NSWindowGetDisplayCycleObserverForLayout_block_invoke","symbolLocation":464,"imageIndex":4},
      {"imageOffset":4660,"imageIndex":0}
    ]},
    {"id":2,"frames":[]}
  ],
  "usedImages" : [
    {"name":"Cadence","path":"/Users/someone/Applications/Cadence.app/Contents/MacOS/Cadence"},
    {"name":"libsystem_kernel.dylib"},
    {"name":"libobjc.A.dylib"},
    {"name":"CoreFoundation"},
    {"name":"AppKit"},
    {"name":"libsystem_c.dylib"}
  ]
}
"""

private let markerText = """
version=0.5.4
build=14
launched=1795596000
signal=6
time=1795604015
backtrace:
0   Cadence                             0x0000000100a3b2c4 $s7Cadence12CrashSignalsO6handle + 120
1   libsystem_platform.dylib            0x000000018a4b2de4 _sigtramp + 56
2   libsystem_pthread.dylib             0x000000018a4a8f70 pthread_kill + 296
3   libsystem_c.dylib                   0x000000018a3b5908 abort + 148
4   Cadence                             0x0000000100a10000 $s7Cadence8AppStateC7refreshyyF + 40
"""

@Suite struct CrashReportTests {
    @Test func parsesTheMarker() {
        let marker = CrashMarker(parsing: markerText)
        #expect(marker.version == "0.5.4")
        #expect(marker.build == "14")
        #expect(marker.signal == SIGABRT)
        #expect(marker.launched == Date(timeIntervalSince1970: 1_795_596_000))
        #expect(marker.crashed == Date(timeIntervalSince1970: 1_795_604_015))
        #expect(marker.backtrace.count == 5)
        #expect(marker.backtrace.last?.contains("AppStateC7refresh") == true)
    }

    @Test func toleratesAHalfWrittenMarker() {
        let marker = CrashMarker(parsing: "version=0.5.4\nsig")
        #expect(marker.version == "0.5.4")
        #expect(marker.signal == nil)
        #expect(marker.backtrace.isEmpty)
    }

    @Test func parsesTheCrashReport() throws {
        let log = try #require(CrashLog(ips: ips))
        #expect(log.appName == "Cadence")
        #expect(log.appVersion == "0.5.4")
        #expect(log.osVersion == "macOS 26.7.1 (25G241)")
        #expect(log.model == "MacBookPro18,1")
        #expect(log.exceptionType == "EXC_CRASH")
        #expect(log.signal == "SIGABRT")
        #expect(log.termination == "Abort trap: 6")
        #expect(log.messages == ["abort() called"])
        #expect(log.crashedThread == 0)
        #expect(log.crashedQueue == "com.apple.main-thread")
        #expect(log.frames.count == 4)
        #expect(log.frames[0].text == "libsystem_kernel.dylib  __pthread_kill + 8")
        #expect(log.frames[3].text == "Cadence  0x1234")
        #expect(log.exceptionFrames.count == 4)
        #expect(log.timestamp == Date(timeIntervalSince1970: 1_795_604_015))
    }

    @Test func rejectsSomethingThatIsNotACrashReport() {
        #expect(CrashLog(ips: "hello") == nil)
        #expect(CrashLog(ips: "{}\nnot json") == nil)
    }

    @Test func namesWhereItCrashed() throws {
        let log = try #require(CrashLog(ips: ips))
        // The exception's backtrace wins, skipping CoreFoundation and libobjc plumbing.
        let report = CrashReport(marker: CrashMarker(parsing: markerText), log: log, restarted: true)
        #expect(report.issueTitle == "Crash: SIGABRT in -[NSWindow _layout]")

        // Without macOS's report, the handler's own backtrace, after _sigtramp and the abort.
        let bare = CrashReport(marker: CrashMarker(parsing: markerText), restarted: true)
        #expect(bare.issueTitle == "Crash: SIGABRT in $s7Cadence8AppStateC7refreshyyF")
        #expect(bare.reason == "SIGABRT")
    }

    @Test func reasonPrefersTheExceptionThenTheSystemMessage() throws {
        let log = try #require(CrashLog(ips: ips))
        let marker = CrashMarker(parsing: markerText)
        #expect(CrashReport(marker: marker, log: log, restarted: true).reason == "SIGABRT · abort() called")
        #expect(CrashReport(marker: marker, log: log, exception: "NSGenericException: oops", restarted: true).reason
            == "SIGABRT · NSGenericException: oops")
    }

    @Test func detailsCoverEverythingAndHideTheHomeFolder() throws {
        let log = try #require(CrashLog(ips: ips))
        let marker = CrashMarker(parsing: markerText + "\n5   Cadence  0x1 /Users/someone/x + 1")
        let details = CrashReport(marker: marker, log: log, restarted: true).details(home: "/Users/someone")
        #expect(details.contains("Cadence 0.5.4 (14) · macOS 26.7.1 (25G241) · MacBookPro18,1"))
        #expect(details.contains("Crashed: 2026-11-25 10:53:35 UTC (2h 13m after launch)"))
        #expect(details.contains("Exception: EXC_CRASH / SIGABRT — Abort trap: 6"))
        #expect(details.contains("Binary UUID: 684e0faa-a6e3-3b3e-89cb-e308fa681a20"))
        #expect(details.contains("Last exception backtrace:"))
        #expect(details.contains("Crashed thread 0 (com.apple.main-thread):"))
        #expect(details.contains("2   AppKit  __NSWindowGetDisplayCycleObserverForLayout_block_invoke + 464"))
        #expect(!details.contains("someone"))

        let bare = CrashReport(marker: marker, restarted: false).details(home: "/Users/someone")
        #expect(bare.contains("Backtrace:"))
        #expect(bare.contains("~/x"))
        #expect(!bare.contains("someone"))
    }

    @Test func capsFrames() throws {
        let log = try #require(CrashLog(ips: ips))
        let details = CrashReport(marker: CrashMarker(), log: log, restarted: true).details(maxFrames: 2)
        #expect(details.contains("…  2 more"))
    }

    @Test func issueURLPrefillsTheCrashTemplate() throws {
        let log = try #require(CrashLog(ips: ips))
        let report = CrashReport(marker: CrashMarker(parsing: markerText), log: log, restarted: true)
        let url = CrashIssue.url(for: report, note: " Waking the Mac + moving displays ", macOS: "macOS 26.0.0",
                                 repository: "owner/repo", home: "/Users/someone")
        #expect(url.absoluteString.hasPrefix("https://github.com/owner/repo/issues/new?"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(value("template") == "crash_report.yml")
        #expect(value("title") == "Crash: SIGABRT in -[NSWindow _layout]")
        #expect(value("what-happened") == "Waking the Mac + moving displays")
        #expect(value("cadence-version") == "0.5.4")
        #expect(value("macos-version") == "macOS 26.7.1 (25G241)")
        #expect(value("crash-log")?.contains("Crashed thread 0") == true)
        #expect(url.absoluteString.contains("%2B"))
    }

    @Test func issueURLStaysShortEnoughForGitHub() {
        let frames = (0..<500).map { "\($0)   Cadence   0x0000000100a3b2c4 $s7Cadence\(String(repeating: "X", count: 80)) + 1" }
        let marker = CrashMarker(version: "1.0.0", signal: SIGSEGV, backtrace: frames)
        let url = CrashIssue.url(for: CrashReport(marker: marker, restarted: true), note: "", macOS: "macOS 26.0.0",
                                 repository: "owner/repo")
        #expect(url.absoluteString.count <= CrashIssue.maxURLLength)
    }

    @Test func crashLoopGuardStopsAfterThreeQuickCrashes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(CrashLoopGuard.shouldRelaunch(crashes: [now], now: now))
        #expect(CrashLoopGuard.shouldRelaunch(crashes: [now - 60, now], now: now))
        #expect(!CrashLoopGuard.shouldRelaunch(crashes: [now - 120, now - 60, now], now: now))
        // Old crashes don't count.
        #expect(CrashLoopGuard.shouldRelaunch(crashes: [now - 3600, now - 1200, now], now: now))
        #expect(CrashLoopGuard.recent([now - 3600, now - 30, now], now: now) == [now - 30, now])
    }

    @Test func historyRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = CrashFiles(directory: dir)
        #expect(files.readHistory().isEmpty)
        let dates = [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 200)]
        files.writeHistory(dates)
        #expect(files.readHistory() == dates)
    }

    @Test func signalNames() {
        #expect(CrashReport.signalName(SIGSEGV) == "SIGSEGV")
        #expect(CrashReport.signalName(SIGTRAP) == "SIGTRAP")
        #expect(CrashReport.signalName(99) == "signal 99")
    }
}
