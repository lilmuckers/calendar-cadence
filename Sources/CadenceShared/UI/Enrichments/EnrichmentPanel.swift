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

/// Tabs (one chip per enrichment) over the selected one's content.
struct EnrichmentPanel: View {
    let meeting: Meeting
    let enrichments: [Enrichment]
    let state: (Enrichment) -> EnrichmentState
    let now: Date
    var interactive = true
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
