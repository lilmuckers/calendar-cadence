import CadenceCore
import SwiftUI

// Shared by the Mac's drawer and the iPhone's desk overlay. Always drawn on a dark background.

/// Everything an enrichment view needs about where it's shown.
struct EnrichmentContext {
    var meeting: Meeting
    var now: Date
    var tint: Color
    /// False while the phone is disconnected from the Mac (it can look, not tick).
    var interactive: Bool
    var onAction: (EnrichmentAction) -> Void
}

/// How an enrichment's sources show under its content.
enum EnrichmentSourcesStyle {
    /// Numbered citation marks; hover for what came from where, click to open (Mac drawer).
    case citations
    /// Just a note that there are some (the phone, where space is short).
    case indicator
}

/// Tabs (one chip per enrichment) over the selected one's content.
struct EnrichmentPanel: View {
    let meeting: Meeting
    let enrichments: [Enrichment]
    let state: (Enrichment) -> EnrichmentState
    let now: Date
    var interactive = true
    var sourcesStyle: EnrichmentSourcesStyle = .citations
    let onAction: (EnrichmentAction) -> Void

    @State private var selectedID: String?

    private var selected: Enrichment? {
        enrichments.first { $0.id == selectedID } ?? enrichments.first
    }

    var body: some View {
        let ctx = EnrichmentContext(meeting: meeting, now: now, tint: meeting.tint, interactive: interactive, onAction: onAction)
        VStack(alignment: .leading, spacing: 12) {
            if enrichments.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(enrichments) { e in
                            EnrichmentChip(enrichment: e, selected: e.id == selected?.id, tint: ctx.tint) {
                                withAnimation(Theme.spring) { selectedID = e.id }
                            }
                        }
                    }
                }
            }
            if let e = selected {
                ScrollView {
                    EnrichmentContentView(enrichment: e, state: state(e), ctx: ctx)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)
                        .id(e.id)
                }
                .scrollIndicators(.never)
                if !e.sources.isEmpty {
                    switch sourcesStyle {
                    case .citations: EnrichmentCitations(sources: e.sources).id("src-" + e.id)
                    case .indicator: EnrichmentSourcesIndicator(count: e.sources.count)
                    }
                }
            } else {
                Text("Nothing attached yet")
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
        .tint(ctx.tint)
        .environment(\.colorScheme, .dark)
    }
}

struct EnrichmentChip: View {
    let enrichment: Enrichment
    let selected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: enrichment.content.knownKind?.symbol ?? "questionmark.square.dashed")
                    .font(.system(size: 11, weight: .semibold))
                Text(enrichment.title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(selected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(0.08))))
            .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0 : 0.12)))
            .foregroundStyle(selected ? .white : .white.opacity(0.75))
        }
        .buttonStyle(.plain)
    }
}

/// One enrichment's content, by kind.
struct EnrichmentContentView: View {
    let enrichment: Enrichment
    let state: EnrichmentState
    let ctx: EnrichmentContext

    var body: some View {
        switch enrichment.content {
        case .markdown(let text): MarkdownView(text: text)
        case .links(let links): LinksView(links: links)
        case .checklist(let items): ChecklistView(enrichmentID: enrichment.id, items: items, checked: state.checked, ctx: ctx)
        case .bingo(let card): BingoView(enrichmentID: enrichment.id, card: card, marked: state.checked, ctx: ctx)
        case .agenda(let items): AgendaView(enrichmentID: enrichment.id, items: items, done: state.checked, ctx: ctx)
        case .people(let people): PeopleView(people: people, tint: ctx.tint)
        case .log(let entries): LogView(enrichmentID: enrichment.id, prefilled: entries, entries: state.entries, ctx: ctx)
        case .stats(let tiles): StatsView(tiles: tiles)
        case .unsupported(let kind, _):
            Label("This is a “\(kind)” attachment. Update Cadence to see it.", systemImage: "arrow.down.app")
                .font(.callout).foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// A row of little numbered citation marks at the foot of the drawer.
struct EnrichmentCitations: View {
    let sources: [EnrichmentSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            FlowLayout(spacing: 5) {
                EnrichmentCaption(text: "Sources")
                    .padding(.trailing, 2)
                    .frame(height: 20)
                ForEach(sources) { CitationMark(source: $0) }
            }
        }
    }
}

private struct CitationMark: View {
    let source: EnrichmentSource
    @State private var hovering = false

    var body: some View {
        let label = HStack(spacing: 4) {
            Text(source.id)
                .font(.system(size: 9, weight: .heavy).monospacedDigit())
                .frame(minWidth: 13, minHeight: 13)
                .background(Circle().fill(.tint.opacity(0.45)))
            Text(source.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            if source.url != nil {
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.leading, 3).padding(.trailing, 7)
        .frame(height: 20)
        .background(Capsule().fill(.white.opacity(hovering ? 0.14 : 0.06)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        .foregroundStyle(.white.opacity(0.8))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .help(tooltip)

        if let url = source.url {
            Link(destination: url) { label }.buttonStyle(.plain)
        } else {
            label
        }
    }

    private var tooltip: String {
        var lines = [source.name]
        if let d = source.detail { lines.append(d) }
        if let u = source.url { lines.append(u.absoluteString) }
        return lines.joined(separator: "\n")
    }
}

/// "3 sources": the phone only says there are some.
struct EnrichmentSourcesIndicator: View {
    let count: Int
    var body: some View {
        Label(count == 1 ? "1 source" : "\(count) sources", systemImage: "quote.opening")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .accessibilityLabel(count == 1 ? "Cites 1 source" : "Cites \(count) sources")
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            var r = rows[rows.count - 1]
            r.width += (r.indices.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.indices.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

/// Small heavy caps label, as elsewhere in Cadence ("UP NEXT").
struct EnrichmentCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .heavy)).kerning(1.2)
            .foregroundStyle(.white.opacity(0.5))
    }
}

/// Rounded card used by rows and tiles.
struct EnrichmentCard<Content: View>: View {
    var highlight: Color?
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(highlight.map { $0.opacity(0.22) } ?? .white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(highlight?.opacity(0.6) ?? .white.opacity(0.1)))
    }
}
