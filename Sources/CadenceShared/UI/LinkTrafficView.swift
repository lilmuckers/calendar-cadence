import CadenceCore
import Charts
import SwiftUI

/// The Advanced part of a paired device's page: how much has gone over the link, data per minute,
/// each message type as its own line over time, totals per type and the last few messages.
/// Sections for a Form; the parent passes in a fresh `LinkTraffic` as it changes.
struct LinkTrafficSections: View {
    let traffic: LinkTraffic
    /// What the other end is called, for the captions ("Sent to Work laptop").
    let peer: String

    @State private var window: Window = .quarter
    @State private var showPings = false

    enum Window: String, CaseIterable, Identifiable {
        case quarter = "15 min", hour = "1 hour", threeHours = "3 hours"
        var id: Self { self }
        var seconds: TimeInterval {
            switch self {
            case .quarter: 15 * 60
            case .hour: 60 * 60
            case .threeHours: 3 * 60 * 60
            }
        }
    }

    var body: some View {
        Section {
            // Four across on the Mac, two by two on a phone.
            #if os(macOS)
            HStack(spacing: 0) {
                totalStat
                Divider().frame(height: 34)
                sentStat
                Divider().frame(height: 34)
                receivedStat
                Divider().frame(height: 34)
                messagesStat
            }
            .padding(.vertical, 4)
            #else
            Grid(horizontalSpacing: 0, verticalSpacing: 14) {
                GridRow { totalStat; messagesStat }
                GridRow { sentStat; receivedStat }
            }
            .padding(.vertical, 6)
            #endif
        } header: {
            Text("Link traffic")
        } footer: {
            if let since = traffic.since {
                Text("Since \(since.formatted(date: .omitted, time: .shortened)), kept while Cadence is open. Sizes are what went over the encrypted link, before TLS overhead.")
            } else {
                Text("Nothing has gone over the link with \(peer) since Cadence opened. Connect the two to see traffic here.")
            }
        }

        if !traffic.isEmpty {
            overTimeSection
            kindsSection
            recentSection
        }
    }

    private var totalStat: some View { Stat(title: "Total", value: Self.megabytes(traffic.totalBytes), emphasis: true) }
    private var sentStat: some View { Stat(title: "Sent", value: Self.megabytes(traffic.bytesSent)) }
    private var receivedStat: some View { Stat(title: "Received", value: Self.megabytes(traffic.bytesReceived)) }
    private var messagesStat: some View { Stat(title: "Messages", value: traffic.totalMessages.formatted()) }

    // MARK: Charts

    /// The section sits outside the TimelineView so the Form still sees it as a section (header and all).
    private var overTimeSection: some View {
        Section {
            Picker("Show", selection: $window) {
                ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Redraw every few seconds so the newest minute keeps scrolling in.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                charts(now: context.date)
            }
        } header: {
            Text("Over time")
        }
    }

    @ViewBuilder private func charts(now: Date) -> some View {
        let timeline = traffic.timeline(window: window.seconds, now: now)
        let domain = (timeline.first?.start ?? now)...(timeline.last?.start ?? now)

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Data per minute").font(.subheadline.weight(.semibold))
                Chart {
                    ForEach(timeline, id: \.start) { bucket in
                        AreaMark(x: .value("Time", bucket.start),
                                 y: .value("KB", Double(bucket.bytesSent) / 1000))
                            .foregroundStyle(by: .value("Direction", "Sent"))
                            .interpolationMethod(.monotone)
                        AreaMark(x: .value("Time", bucket.start),
                                 y: .value("KB", Double(bucket.bytesReceived) / 1000))
                            .foregroundStyle(by: .value("Direction", "Received"))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartForegroundStyleScale(["Sent": Color.orange, "Received": Color.blue])
                .chartXScale(domain: domain)
                .chartYAxisLabel("KB")
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 150)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Messages per minute, by type").font(.subheadline.weight(.semibold))
                    Spacer()
                    Toggle("Pings", isOn: $showPings)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .font(.caption)
                }
                let kinds = LinkTraffic.kinds(in: timeline, excluding: showPings ? [] : ["Ping"])
                if kinds.isEmpty {
                    Text(showPings ? "No messages in this time." : "Only pings in this time.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    Chart {
                        ForEach(kinds, id: \.self) { kind in
                            ForEach(timeline, id: \.start) { bucket in
                                LineMark(x: .value("Time", bucket.start),
                                         y: .value("Count", bucket.counts[kind] ?? 0),
                                         series: .value("Type", kind))
                                    .foregroundStyle(by: .value("Type", kind))
                                    .interpolationMethod(.monotone)
                            }
                        }
                    }
                    .chartXScale(domain: domain)
                    .chartYAxisLabel("Count")
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 190)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Lists

    private var kindsSection: some View {
        Section {
            let rows = traffic.kinds.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            ForEach(rows, id: \.key) { kind, total in
                LabeledContent {
                    Text("\(total.sent.formatted()) ↑  \(total.received.formatted()) ↓  ·  \(Self.size(total.bytes))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } label: {
                    Text(kind)
                }
            }
        } header: {
            Text("By type")
        } footer: {
            Text("↑ sent to \(peer), ↓ received from it.")
        }
    }

    private var recentSection: some View {
        Section {
            let entries = traffic.recent.filter { showPings || $0.kind != "Ping" }
            if entries.isEmpty {
                Text("Only pings lately.").foregroundStyle(.secondary)
            }
            ForEach(entries.suffix(20).reversed()) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.direction == .sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(entry.direction == .sent ? Color.orange : Color.blue)
                        .accessibilityLabel(entry.direction == .sent ? "Sent" : "Received")
                    Text(entry.kind)
                    Spacer()
                    Text(Self.size(entry.bytes)).foregroundStyle(.secondary)
                    Text(entry.at.formatted(date: .omitted, time: .standard))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .monospacedDigit()
            }
        } header: {
            Text("Recent messages")
        } footer: {
            Text(showPings ? "Pings included." : "Pings hidden; turn on Pings above to see them.")
        }
    }

    // MARK: Formatting

    /// Always in MB (decimal), with enough places that a quiet link doesn't read as zero.
    static func megabytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 10 ? String(format: "%.1f MB", mb) : mb >= 0.01 || bytes == 0 ? String(format: "%.2f MB", mb) : String(format: "%.3f MB", mb)
    }

    static func size(_ bytes: Int) -> String {
        bytes < 1000 ? "\(bytes) B" : bytes < 1_000_000 ? String(format: "%.1f KB", Double(bytes) / 1000) : megabytes(bytes)
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var emphasis = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(emphasis ? .title3 : .callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
