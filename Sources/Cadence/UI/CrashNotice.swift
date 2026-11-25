import AppKit
import CadenceCore
import SwiftUI

/// The last run's crash, shown on the next launch. Starts with what the signal handler recorded and
/// fills in macOS's crash report once it turns up (ReportCrash can take a few seconds to write it).
@MainActor @Observable
final class CrashNotice {
    var report: CrashReport
    var note = ""
    private(set) var lookingForLog = true

    init(report: CrashReport) { self.report = report }

    func findLog() async {
        let date = report.marker.crashed ?? Date()
        for attempt in 0..<15 {
            if let log = await Task.detached(operation: { CrashReporter.findLog(near: date) }).value {
                report.log = log
                break
            }
            if attempt < 14 { try? await Task.sleep(for: .seconds(2)) }
        }
        lookingForLog = false
    }

    var issueURL: URL {
        CrashIssue.url(for: report, note: note, macOS: CrashReporter.macOSVersion, repository: Updater.repository)
    }
}

struct CrashNoticeView: View {
    @Bindable var notice: CrashNotice
    let done: () -> Void
    @State private var showDetails = false
    @State private var copied = false

    static let width: CGFloat = 500

    var body: some View {
        VStack(spacing: 0) {
            MascotHeader(mood: .panicking, height: 120)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.report.restarted ? "Cadence crashed — and restarted" : "Cadence crashed")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [AboutMascot.pink, AboutMascot.orange],
                                                        startPoint: .leading, endPoint: .trailing))
                    Text(subtitle)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AboutMascot.orange)
                    Text(summary)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Help get it fixed").font(.headline)
                    Text("Report it on GitHub with the crash details. Nothing is sent until you submit the issue there, and you can edit it first. Your home folder is replaced with ~, but check for anything private before submitting.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("What were you doing when it crashed? (optional)", text: $notice.note, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }

                DisclosureGroup(isExpanded: $showDetails) {
                    ScrollView {
                        Text(notice.report.details())
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 200)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                } label: {
                    HStack(spacing: 6) {
                        Text("Crash details")
                        if notice.lookingForLog {
                            ProgressView().controlSize(.mini)
                            Text("Waiting for macOS's crash report…").font(.caption).foregroundStyle(.secondary)
                        } else if notice.report.log == nil {
                            Text("macOS didn't write a crash report; using Cadence's own.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button(copied ? "Copied" : "Copy Details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(notice.report.details(), forType: .string)
                        copied = true
                    }
                    Spacer()
                    Button("Close", action: done)
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                    Button("Report on GitHub…") {
                        NSWorkspace.shared.open(notice.issueURL)
                        done()
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                }
            }
            .padding(22)
        }
        .background(.background)
        .task { await notice.findLog() }
    }

    private var subtitle: String {
        let report = notice.report
        if report.restarted {
            return "Sorry about that. It's back up and watching your calendars again."
        }
        if report.recentCrashes >= CrashLoopGuard.limit {
            return "It crashed \(report.recentCrashes) times in a few minutes, so it didn't restart itself. Sorry about that."
        }
        return "It quit unexpectedly last time it was open. Sorry about that."
    }

    private var summary: String {
        var text = notice.report.reason
        if let date = notice.report.date {
            text = date.formatted(date: .abbreviated, time: .shortened) + " · " + text
        }
        return text
    }
}
