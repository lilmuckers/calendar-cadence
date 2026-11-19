import CadenceCore
import SwiftUI

// MARK: - Markdown

struct MarkdownView: View {
    let text: String
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        let body: CGFloat = compact ? 12 : 14
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(size: [0, 20, 17, 15][level] - (compact ? 3 : 0), weight: level == 3 ? .semibold : .bold, design: .rounded))
                .padding(.top, compact ? 2 : 4)
        case .paragraph(let text):
            Text(Self.inline(text)).font(.system(size: body)).foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if let task = item.task {
                                Image(systemName: task ? "checkmark.square.fill" : "square")
                            } else if let n = item.ordinal {
                                Text("\(n).").monospacedDigit()
                            } else {
                                Text(item.depth == 0 ? "•" : "◦")
                            }
                        }
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(minWidth: 12, alignment: .trailing)
                        Text(Self.inline(item.text)).fixedSize(horizontal: false, vertical: true)
                            .strikethrough(item.task == true, color: .white.opacity(0.4))
                    }
                    .font(.system(size: body))
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let text):
            HStack(spacing: 8) {
                Capsule().fill(.tint).frame(width: 3)
                Text(Self.inline(text)).font(.system(size: body).italic()).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(size: body - 2, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
        case .rule:
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
        }
    }
}

// MARK: - Links

struct LinksView: View {
    let links: [EnrichmentLink]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(links) { link in
                Link(destination: link.url) {
                    EnrichmentCard {
                        HStack(spacing: 10) {
                            Image(systemName: Self.symbol(link.url))
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(.tint.opacity(0.25)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                Text(link.note ?? link.host).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    static func symbol(_ url: URL) -> String {
        let s = url.absoluteString.lowercased()
        if url.scheme == "mailto" { return "envelope" }
        if s.contains("docs.google.com/spreadsheets") || s.contains(".xlsx") || s.contains("sheet") { return "tablecells" }
        if s.contains("docs.google.com/presentation") || s.contains(".pptx") || s.contains("slides") || s.contains("figma") { return "rectangle.on.rectangle" }
        if s.contains("github") || s.contains("gitlab") { return "chevron.left.forwardslash.chevron.right" }
        if s.contains("jira") || s.contains("linear.app") || s.contains("asana") { return "checklist" }
        if s.contains("docs.google.com") || s.contains("notion") || s.contains("confluence") || s.contains(".pdf") || s.contains(".docx") { return "doc.text" }
        return "link"
    }
}

// MARK: - Checklist

struct ChecklistView: View {
    let enrichmentID: String
    let items: [ChecklistItem]
    let checked: Set<String>
    let ctx: EnrichmentContext

    var body: some View {
        let done = items.filter { checked.contains($0.id) }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                EnrichmentCaption(text: "\(done) of \(items.count) done")
                Spacer()
            }
            ProgressBar(value: items.isEmpty ? 0 : Double(done) / Double(items.count))
            VStack(spacing: 4) {
                ForEach(items) { item in
                    let on = checked.contains(item.id)
                    Button { ctx.onAction(.toggle(enrichmentID: enrichmentID, itemID: item.id)) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17))
                                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.4)))
                                .contentTransition(.symbolEffect(.replace))
                            Text(MarkdownView.inline(item.text))
                                .font(.system(size: 14))
                                .strikethrough(on, color: .white.opacity(0.4))
                                .foregroundStyle(.white.opacity(on ? 0.5 : 0.95))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!ctx.interactive)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: checked)
        .animation(Theme.spring, value: checked)
    }
}

struct ProgressBar: View {
    var value: Double
    var color: Color?
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint)).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Bingo

struct BingoView: View {
    let enrichmentID: String
    let card: BingoCard
    let marked: Set<String>
    let ctx: EnrichmentContext

    @State private var celebrate = false

    var body: some View {
        let lines = card.lines(marked: marked)
        let lit = Set(lines.flatMap { $0 })
        let cells = card.cells
        VStack(spacing: 10) {
            HStack {
                EnrichmentCaption(text: lines.isEmpty ? "Tap when you hear it" : (lines.count == 1 ? "Bingo!" : "\(lines.count) lines"))
                Spacer()
                Text("\(marked.count)/\(card.squares.count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: card.size), spacing: 5) {
                ForEach(0..<cells.count, id: \.self) { i in
                    cell(cells[i], index: i, inLine: lit.contains(i))
                }
            }
        }
        .overlay {
            if celebrate {
                Text("BINGO!")
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .foregroundStyle(ctx.tint.gradient)
                    .shadow(color: ctx.tint.opacity(0.8), radius: 20)
                    .rotationEffect(.degrees(-8))
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .sensoryFeedback(.success, trigger: lines.count) { old, new in new > old }
        .onChange(of: lines.count) { old, new in
            guard new > old else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { celebrate = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeOut(duration: 0.3)) { celebrate = false }
            }
        }
    }

    @ViewBuilder private func cell(_ square: BingoSquare?, index: Int, inLine: Bool) -> some View {
        let on = square.map { marked.contains($0.id) } ?? true
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button {
            if let square { ctx.onAction(.toggle(enrichmentID: enrichmentID, itemID: square.id)) }
        } label: {
            ZStack {
                shape.fill(on ? AnyShapeStyle(ctx.tint.opacity(inLine ? 0.9 : 0.45)) : AnyShapeStyle(Color.white.opacity(0.06)))
                shape.strokeBorder(inLine ? .white.opacity(0.8) : .white.opacity(0.1), lineWidth: inLine ? 1.5 : 1)
                if let square {
                    Text(square.text)
                        .font(.system(size: card.size >= 5 ? 10.5 : 12.5, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                        .lineLimit(4)
                        .padding(3)
                        .foregroundStyle(.white.opacity(on ? 1 : 0.85))
                } else {
                    Image(systemName: "star.fill").font(.system(size: 16)).foregroundStyle(.white)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(on && square != nil ? 0.96 : 1)
        }
        .buttonStyle(.plain)
        .disabled(square == nil || !ctx.interactive)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: on)
    }
}

// MARK: - Agenda

struct AgendaView: View {
    let enrichmentID: String
    let items: [AgendaItem]
    let done: Set<String>
    let ctx: EnrichmentContext

    var body: some View {
        let started = ctx.now >= ctx.meeting.start
        let slots = AgendaTimeline.slots(items, start: ctx.meeting.start, done: done, now: ctx.now)
        let total = AgendaTimeline.totalMinutes(items)
        let length = Int(ctx.meeting.end.timeIntervalSince(ctx.meeting.start) / 60)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                EnrichmentCaption(text: "\(total) min planned")
                if total > length { Text("· \(total - length) over the slot").font(.system(size: 10, weight: .heavy)).foregroundStyle(.orange) }
                Spacer()
            }
            ForEach(slots, id: \.item.id) { slot in
                let current = started && slot.status == .current
                Button { ctx.onAction(.toggle(enrichmentID: enrichmentID, itemID: slot.item.id)) } label: {
                    EnrichmentCard(highlight: current ? (slot.overrun > 0 ? .red : ctx.tint) : nil) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: slot.status == .done ? "checkmark.circle.fill" : (current ? "play.circle.fill" : "circle"))
                                    .foregroundStyle(slot.status == .done ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(current ? 1 : 0.4)))
                                Text(slot.item.title).font(.system(size: 14, weight: current ? .semibold : .regular))
                                    .strikethrough(slot.status == .done, color: .white.opacity(0.4))
                                    .foregroundStyle(.white.opacity(slot.status == .done ? 0.5 : 0.95))
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 4)
                                Text(slot.start.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                                Text("\(slot.item.minutes)m").font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            if let owner = slot.item.owner {
                                Text(owner).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(.leading, 24)
                            }
                            if current {
                                HStack(spacing: 8) {
                                    ProgressBar(value: slot.progress, color: slot.overrun > 0 ? .red : nil)
                                    if slot.overrun > 0 {
                                        Text("+\(CountdownFormatter.clock(slot.overrun))").font(.system(size: 11, weight: .bold).monospacedDigit())
                                            .foregroundStyle(.red)
                                    } else {
                                        Text(CountdownFormatter.clock(slot.end.timeIntervalSince(ctx.now)) + " left")
                                            .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                                    }
                                }
                                .padding(.leading, 24)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!ctx.interactive)
            }
        }
        .animation(Theme.spring, value: done)
    }
}

// MARK: - People

struct PeopleView: View {
    let people: [PersonBrief]
    let tint: Color

    var body: some View {
        VStack(spacing: 8) {
            ForEach(people) { p in
                EnrichmentCard {
                    HStack(alignment: .top, spacing: 10) {
                        Text(Self.initials(p.name))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(tint.gradient))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name).font(.system(size: 14, weight: .semibold))
                            if let role = p.role { Text(role).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)) }
                            if let email = p.email { Text(email).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).textSelection(.enabled) }
                            if let notes = p.notes { MarkdownView(text: notes, compact: true).padding(.top, 3) }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

// MARK: - Decisions & actions log

struct LogView: View {
    let enrichmentID: String
    let prefilled: [LogEntry]
    let entries: [LogEntry]
    let ctx: EnrichmentContext

    @State private var draft = ""
    @State private var type: LogEntry.EntryType = .action
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ctx.interactive { composer }
            let all = prefilled + entries
            if all.isEmpty {
                Text("Log decisions and action items as they happen. Your assistant can pick them up afterwards.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            ForEach(LogEntry.EntryType.allCases, id: \.self) { kind in
                let group = all.filter { $0.type == kind }
                if !group.isEmpty {
                    EnrichmentCaption(text: kind == .note ? "Notes" : kind.label + "s").padding(.top, 2)
                    ForEach(group) { e in row(e) }
                }
            }
        }
        .animation(Theme.spring, value: entries)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Type", selection: $type) {
                ForEach(LogEntry.EntryType.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 6) {
                TextField(type == .decision ? "We decided…" : (type == .action ? "Who does what…" : "Note…"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(add)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                Button(action: add) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.tint))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ctx.onAction(.addEntry(enrichmentID: enrichmentID, entry: LogEntry(type: type, text: text, at: ctx.now)))
        draft = ""
        focused = true
    }

    private func row(_ e: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: e.type == .decision ? "checkmark.seal.fill" : (e.type == .action ? "arrow.right.circle.fill" : "text.bubble.fill"))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(MarkdownView.inline(e.text)).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                let meta = [e.owner, e.due.map { "due \($0)" }, e.by == .assistant ? "from assistant" : e.at?.formatted(date: .omitted, time: .shortened)]
                    .compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)) }
            }
            Spacer(minLength: 0)
            if e.by == .user && ctx.interactive {
                Button { ctx.onAction(.removeEntry(enrichmentID: enrichmentID, entryID: e.id)) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Key numbers

struct StatsView: View {
    let tiles: [StatTile]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
            ForEach(tiles) { t in
                EnrichmentCard {
                    VStack(alignment: .leading, spacing: 4) {
                        EnrichmentCaption(text: t.label).lineLimit(1)
                        Text(t.value).font(.system(size: 24, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
                        if t.delta != nil || t.trend != nil {
                            HStack(spacing: 3) {
                                if let trend = t.trend {
                                    Image(systemName: trend == .up ? "arrow.up.right" : (trend == .down ? "arrow.down.right" : "arrow.right"))
                                }
                                if let d = t.delta { Text(d) }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Self.color(t))
                        }
                    }
                }
            }
        }
    }

    static func color(_ t: StatTile) -> Color {
        switch t.trend {
        case .up?: return t.upIsGood ? .green : .red
        case .down?: return t.upIsGood ? .red : .green
        default: return .white.opacity(0.6)
        }
    }
}
