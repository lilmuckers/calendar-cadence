import CadenceCore
import Foundation

// cadence-watchdog <app pid> <crash folder> <Cadence.app path>
//
// Started by Cadence at launch. Waits (without polling) for the app to exit. If it went down in a
// crash — its signal handler left a marker — this notes the crash and opens the app again, unless it
// has crashed too often in the last few minutes. A normal quit leaves no marker, so this just exits.

let args = CommandLine.arguments
guard args.count == 4, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: cadence-watchdog <pid> <crash folder> <app path>\n".utf8))
    exit(64)
}
let files = CrashFiles(directory: URL(fileURLWithPath: args[2], isDirectory: true))
let app = args[3]

// Outlive the app's session ending; the app stops us with SIGTERM when restarts are turned off.
signal(SIGHUP, SIG_IGN)
signal(SIGPIPE, SIG_IGN)

let kq = kqueue()
var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                    fflags: NOTE_EXIT, data: 0, udata: nil)
// ESRCH: it's already gone, so go straight to checking how it ended.
if kevent(kq, &change, 1, nil, 0, nil) == 0 {
    var event = kevent()
    while kevent(kq, nil, 0, &event, 1, nil) == -1 && errno == EINTR {}
}

guard FileManager.default.fileExists(atPath: files.marker.path) else { exit(0) }

let now = Date()
let crashes = CrashLoopGuard.recent(files.readHistory(), now: now) + [now]
files.writeHistory(crashes)
guard CrashLoopGuard.shouldRelaunch(crashes: crashes, now: now) else { exit(0) }

// Give ReportCrash a moment to finish with the old process before the new one starts.
Thread.sleep(forTimeInterval: 1)
let open = Process()
open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
open.arguments = [app, "--args", "--after-crash"]
try? open.run()
open.waitUntilExit()
