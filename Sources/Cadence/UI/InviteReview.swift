import AppKit
import CadenceCore
import SwiftUI

/// Card listing invitations that still need a reply, with Accept / Maybe / Decline and (for
/// calendars that ask for it) a colour picker. One card in the right-hand `AlertStack`.
@MainActor
final class InviteReviewController {
    private let state: AppState
    private var card: AlertStack.Card?
    private let model = InviteReviewModel()

    init(state: AppState) { self.state = state }

    func show(_ invites: [Meeting], reason: InvitePromptReason) {
        guard !invites.isEmpty else { return }
        // New arrivals join whatever is already on screen.
        if let card {
            for m in invites where !model.items.contains(where: { $0.id == m.id }) { model.items.append(m) }
            model.reason = reason == .new && model.reason == .new ? .new : model.reason
            card.setSummary(summary)
            card.relayout()
            return
        }
        model.items = invites
        model.reason = reason
        model.errors = [:]
        present()
    }

    private func height() -> CGFloat {
        let rows = model.items.prefix(4).reduce(CGFloat(0)) { $0 + (state.wantsColorPrompt($1) ? 134 : 88) }
        return 76 + max(rows, 84) + (model.items.count > 4 ? 18 : 0)
    }

    private var summary: AlertStack.Summary {
        let n = model.items.count
        return AlertStack.Summary(
            symbol: model.reason == .new ? "envelope.badge.fill" : "envelope.open.fill", tint: .accentColor,
            title: n == 1 ? "Invite to answer" : "\(n) invites to answer",
            subtitle: model.items.prefix(3).map(\.title).joined(separator: ", "))
    }

    private func present() {
        card = AlertStack.shared.add(summary: summary, height: { [weak self] in self?.height() ?? 160 }) {
            InviteReviewView(model: model, close: { [weak self] in self?.close() },
                             changed: { [weak self] in self?.itemsChanged() })
                .environment(state)
        }
        NSSound(named: "Glass")?.play()
    }

    /// Drops an invite answered elsewhere (on the phone).
    func remove(_ id: String) {
        guard card != nil, model.items.contains(where: { $0.id == id }) else { return }
        model.items.removeAll { $0.id == id }
        itemsChanged()
    }

    private func itemsChanged() {
        if model.items.isEmpty { close() } else { card?.setSummary(summary); card?.relayout() }
    }

    private func close() {
        card?.close()
        card = nil
    }
}

@MainActor
@Observable
final class InviteReviewModel {
    var items: [Meeting] = []
    var reason: InvitePromptReason = .manual
    /// Meeting id → the button or swatch the user pressed, highlighted while it saves.
    var pressed: [String: Pressed] = [:]
    var errors: [String: String] = [:]

    enum Pressed: Equatable {
        case reply(RSVP)
        /// A colour choice id, or nil for the calendar colour.
        case color(String?)
    }
}

struct InviteReviewView: View {
    @Environment(AppState.self) private var state
    let model: InviteReviewModel
    let close: () -> Void
    let changed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if MenuBarView.screenshotMode {
                list  // ImageRenderer can't draw ScrollView contents.
            } else {
                ScrollView { list }.scrollIndicators(.never)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VisualEffect(material: .hudWindow))
        .background(alignment: .top) {
            LinearGradient(colors: [Color.accentColor.opacity(0.2), .clear], startPoint: .top, endPoint: .center)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private var list: some View {
        VStack(spacing: 8) {
            ForEach(model.items) { m in row(m) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.reason == .new ? "envelope.badge.fill" : "envelope.open.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: close) {
                Text("Later").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch model.reason {
        case .new: model.items.count == 1 ? "New invite" : "\(model.items.count) new invites"
        case .daily: "Good morning! RSVP time"
        case .manual: model.items.count == 1 ? "1 invite to answer" : "\(model.items.count) invites to answer"
        }
    }

    private var subtitle: String {
        model.reason == .daily ? "\(model.items.count) waiting for a reply · \(state.prefs.inviteHorizon.label.lowercased())"
            : "Accept, maybe or decline — the organiser is told."
    }

    private func row(_ m: Meeting) -> some View {
        let save = state.saveStates[m.id]
        let busy = save != nil
        let pressed = model.pressed[m.id]
        let canReply = state.canRespond(m)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(m.tint.gradient).frame(width: 4, height: 32)
                    .animation(.easeOut(duration: 0.25), value: m.eventColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(when(m) + (m.organizer.map { " · \($0)" } ?? ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ForEach(state.workConflicts(m), id: \.self) { conflict in
                        Label(conflict, systemImage: "cup.and.saucer.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if canReply {
                    ForEach(RSVP.allCases, id: \.self) { reply in
                        replyButton(m, reply, pressed: pressed, save: save)
                    }
                } else {
                    Button { state.openInCalendar(m) } label: {
                        Label("Respond in Calendar", systemImage: "calendar")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.primary.opacity(0.08)))
                    }
                    .buttonStyle(PressableStyle())
                    .help("macOS Calendar doesn't let other apps reply to invites. Sign in to Google or Microsoft in Settings → Accounts to reply from here.")
                }
                Spacer(minLength: 0)
            }
            .allowsHitTesting(!busy)
            if state.wantsColorPrompt(m) {
                let choices = state.colorChoices(for: m)
                ColorSwatches(meeting: m, choices: choices, selected: selectedColor(m, choices),
                              saving: save == .saving) { choice in paint(m, choice) }
                    .allowsHitTesting(!busy)
            }
            if let error = model.errors[m.id] {
                Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
            }
            SaveIndicator(state: save, tint: m.tint)
        }
        .padding(10)
        .padding(.bottom, -4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05)))
        .saveFlash(save, tint: m.tint, cornerRadius: 12)
        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
    }

    /// The swatch to highlight: the one just pressed while it saves, else the event's colour.
    private func selectedColor(_ m: Meeting, _ choices: [EventColorChoice]) -> String? {
        if case .color(let id)? = model.pressed[m.id] { return id }
        return state.currentColor(of: m, in: choices)?.id
    }

    /// Accept / Maybe / Decline. The pressed one lights up and the others step back while it saves.
    private func replyButton(_ m: Meeting, _ reply: RSVP, pressed: InviteReviewModel.Pressed?, save: AppState.SaveState?) -> some View {
        let isPressed = pressed == .reply(reply) && save != nil
        let filled = isPressed || (reply == .accept && save == nil)
        return Button { send(m, reply) } label: {
            Label(reply.label, systemImage: isPressed && save == .saved ? "checkmark.circle.fill" : symbol(reply))
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(filled ? .white : .primary)
                .background(Capsule().fill(filled ? AnyShapeStyle(m.tint.gradient) : AnyShapeStyle(.primary.opacity(0.08))))
                .overlay(Capsule().strokeBorder(.white.opacity(isPressed ? 0.6 : 0), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .opacity(save != nil && !isPressed ? 0.35 : 1)
        .animation(.easeOut(duration: 0.2), value: save)
    }

    private func when(_ m: Meeting) -> String {
        let day = Calendar.current.isDateInToday(m.start) ? "Today"
            : Calendar.current.isDateInTomorrow(m.start) ? "Tomorrow"
            : m.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        // Only when the next occurrence couldn't be found: the series' first date would mislead.
        if m.recurs && m.end <= Date() { return "Repeats · \(Theme.range(m))" }
        return (m.isAllDay ? "\(day) · all day" : "\(day) · \(Theme.range(m))") + (m.recurs ? " · repeats" : "")
    }

    private func symbol(_ r: RSVP) -> String {
        switch r {
        case .accept: "checkmark"
        case .tentative: "questionmark"
        case .decline: "xmark"
        }
    }

    private func send(_ m: Meeting, _ reply: RSVP) {
        model.pressed[m.id] = .reply(reply)
        model.errors[m.id] = nil
        Task {
            do {
                try await state.respond(m, reply)
                // Let the "saved" flash land before the row slides away.
                try? await Task.sleep(for: .seconds(0.6))
                withAnimation(.spring(duration: 0.35)) { model.items.removeAll { $0.id == m.id } }
                changed()
            } catch {
                model.errors[m.id] = error.localizedDescription
            }
            model.pressed[m.id] = nil
        }
    }

    private func paint(_ m: Meeting, _ choice: EventColorChoice?) {
        model.pressed[m.id] = .color(choice?.id)
        model.errors[m.id] = nil
        let before = model.items.first { $0.id == m.id }?.eventColor
        setItemColor(m.id, choice?.color)
        Task {
            do {
                try await state.setColor(m, choice)
            } catch {
                setItemColor(m.id, before)
                model.errors[m.id] = error.localizedDescription
            }
            model.pressed[m.id] = nil
        }
    }

    private func setItemColor(_ id: String, _ color: RGBAColor?) {
        guard let i = model.items.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.25)) { model.items[i].eventColor = color }
    }
}

/// The calendar's event colours (named as it labels them in Google Calendar) plus "calendar colour".
struct ColorSwatches: View {
    let meeting: Meeting
    let choices: [EventColorChoice]
    /// Id of the highlighted swatch; nil = the calendar colour.
    let selected: String?
    var saving = false
    let pick: (EventColorChoice?) -> Void
    /// The swatch under the pointer: .some(nil) is the calendar-colour swatch.
    @State private var hovered: EventColorChoice??

    /// Fits the invite card; swatches shrink a little when a calendar has extra custom labels.
    private var size: CGFloat { min(16, (306 - CGFloat(choices.count) * 4) / CGFloat(choices.count + 1) - 4) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Colour").foregroundStyle(.tertiary)
                Text(caption).foregroundStyle(.secondary).lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: caption)
            }
            .font(.system(size: 10, weight: .medium))
            HStack(spacing: 4) {
                swatch(nil)
                ForEach(choices) { c in swatch(c) }
            }
        }
    }

    private var caption: String {
        if let hovered { return hovered?.detail ?? "Calendar colour" }
        return selected.flatMap { id in choices.first { $0.id == id } }?.name ?? "Calendar colour"
    }

    private func swatch(_ c: EventColorChoice?) -> some View {
        let on = c?.id == selected
        let ring = Color(c?.color ?? meeting.calendar.color)
        return Button { pick(c) } label: {
            ZStack {
                if let c {
                    Circle().fill(Color(c.color))
                } else {
                    Circle().strokeBorder(Color(meeting.calendar.color), lineWidth: 2)
                }
                if on && saving {
                    SwatchSpinner(color: c == nil ? ring : .white).padding(size * 0.2)
                } else if on && c != nil {
                    Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .padding(2)
            .overlay(Circle().strokeBorder(ring.opacity(on ? 0.9 : 0), lineWidth: 1.5))
            .scaleEffect(on && saving ? 1.12 : 1)
            .animation(.spring(duration: 0.25), value: on)
            .animation(.spring(duration: 0.25), value: saving)
        }
        .buttonStyle(PressableStyle())
        .help(c?.detail ?? "Calendar colour")
        .onHover { inside in
            if inside { hovered = .some(c) } else if hovered == .some(c) { hovered = nil }
        }
    }
}

/// A small arc that spins inside the pressed swatch while it saves.
private struct SwatchSpinner: View {
    let color: Color
    @State private var spin = false

    var body: some View {
        Circle().trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

/// "Accept / Maybe / Decline" and "Colour ▸" context-menu items for any event.
struct EventActionsMenu: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting

    var body: some View {
        if meeting.participation == .pending || meeting.participation == .tentative {
            if state.canRespond(meeting) {
                ForEach(RSVP.allCases, id: \.self) { reply in
                    Button(reply.label) { Task { try? await state.respond(meeting, reply) } }
                }
            } else {
                Button("Respond in Calendar…") { state.openInCalendar(meeting) }
            }
            Divider()
        }
        let choices = state.colorChoices(for: meeting)
        let current = state.currentColor(of: meeting, in: choices)
        Menu("Colour") {
            Button("Calendar Colour") { Task { try? await state.setColor(meeting, nil) } }
            Divider()
            ForEach(choices) { c in
                Button { Task { try? await state.setColor(meeting, c) } } label: {
                    Label { Text(c.id == current?.id ? "\(c.detail) ✓" : c.detail) } icon: { Image(nsImage: Self.dot(c.color)) }
                }
            }
        }
    }

    /// Menus render SF Symbols monochrome, so draw the swatch as an image.
    static func dot(_ c: RGBAColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
