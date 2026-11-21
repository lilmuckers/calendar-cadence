import CadenceCore
import SwiftUI

/// What the strip shows, most urgent first: a clash to settle, a new invite, then a reminder.
enum PromptItem: Equatable {
    case clash(CompanionClash)
    case invite(CompanionInvite)
    case reminder(CompanionReminder)

    var id: String {
        switch self {
        case .clash(let c): "clash:" + c.key
        case .invite(let i): "invite:" + i.meeting.id
        case .reminder(let r): "reminder:" + r.key
        }
    }
}

extension PhoneState {
    var currentPrompt: PromptItem? {
        if let c = clashPrompts.first { return .clash(c) }
        if let i = invitePrompts.first { return .invite(i) }
        if let r = banner { return .reminder(r) }
        return nil
    }

    /// How many more are waiting behind the one on show.
    var queuedPrompts: Int { max(0, clashPrompts.count + invitePrompts.count + (banner == nil ? 0 : 1) - 1) }
}

/// The desk-mode "lower third": the Mac's pop-ups (new invite, double-booking, reminders) in the desk
/// view's own look: black, a glow in the meeting's colour, spaced capitals and solid pills.
/// `.strip` runs along the bottom edge (portrait, and the agenda screen); `.panel` sits in the
/// landscape agenda column so the countdown keeps the whole left side.
struct PromptStrip: View {
    enum Style { case strip, panel }

    @Environment(PhoneState.self) private var state
    var style: Style = .strip
    @State private var drag: CGFloat = 0

    var body: some View {
        Group {
            if let item = state.currentPrompt {
                content(item)
                    .id(item.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: state.currentPrompt?.id)
    }

    private func content(_ item: PromptItem) -> some View {
        let tint = tint(item)
        return VStack(alignment: .leading, spacing: 0) {
            switch item {
            case .clash(let c): ClashStrip(clash: c)
            case .invite(let i): InviteStrip(invite: i)
            case .reminder(let r): ReminderStrip(reminder: r)
            }
        }
        .environment(\.promptQueued, state.queuedPrompts)
        .environment(\.promptTint, tint)
        .padding(.horizontal, style == .strip ? 22 : 18)
        .padding(.top, 16)
        .padding(.bottom, style == .strip ? 22 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(tint))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .offset(y: max(0, drag))
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    if value.translation.height > 60 { later(item) }
                    withAnimation(Theme.spring) { drag = 0 }
                }
        )
    }

    @ViewBuilder private func background(_ tint: Color) -> some View {
        let glow = LinearGradient(colors: [tint.opacity(0.16), .black.opacity(0.0)], startPoint: .top, endPoint: .bottom)
        switch style {
        case .strip:
            ZStack(alignment: .top) {
                Color.black.opacity(0.92)
                glow
                Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .bottom)
        case .panel:
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(glow))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        }
    }

    private func tint(_ item: PromptItem) -> Color {
        switch item {
        case .clash: .orange
        case .invite(let i): i.meeting.tint
        case .reminder: .yellow
        }
    }

    /// Swipe down: "later" for whatever's showing.
    private func later(_ item: PromptItem) {
        switch item {
        case .clash(let c): state.resolve(c, choice: nil)
        case .invite(let i): state.later(i)
        case .reminder: state.banner = nil
        }
    }
}

// MARK: - Pieces

private struct QueuedKey: EnvironmentKey { static let defaultValue = 0 }
private struct TintKey: EnvironmentKey { static let defaultValue = Color.white }
private extension EnvironmentValues {
    var promptQueued: Int { get { self[QueuedKey.self] } set { self[QueuedKey.self] = newValue } }
    var promptTint: Color { get { self[TintKey.self] } set { self[TintKey.self] = newValue } }
}

/// Glowing dot, spaced capitals, "+N" and a quiet close button.
private struct StripHeader: View {
    @Environment(\.promptQueued) private var queued
    @Environment(\.promptTint) private var tint
    let label: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8).shadow(color: tint, radius: 5)
            Text(label).font(.system(size: 12, weight: .heavy)).kerning(1.6).foregroundStyle(tint)
            Spacer(minLength: 8)
            if queued > 0 {
                Text("+\(queued)").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.55))
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26).background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityLabel("Later")
        }
    }
}

/// The desk view's pill: solid gradient when it's the main action, a faint wash otherwise.
private struct Pill: View {
    @Environment(\.promptTint) private var tint
    let title: String
    var symbol: String?
    var primary = false
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background {
                if primary { Capsule().fill(tint.gradient) } else { Capsule().fill(.white.opacity(0.1)) }
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

private struct InviteStrip: View {
    @Environment(PhoneState.self) private var state
    let invite: CompanionInvite
    private var m: Meeting { invite.meeting }

    var body: some View {
        StripHeader(label: "NEW INVITE") { state.later(invite) }
        Text(m.title)
            .font(.system(size: 20, weight: .bold))
            .lineLimit(2).minimumScaleFactor(0.8)
            .padding(.top, 8)
        Text(subtitle)
            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            .padding(.top, 2)
        if let clash = clashesWith {
            Label("Clashes with \(clash.title)", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.orange).lineLimit(1)
                .padding(.top, 4)
        }
        ForEach(invite.conflicts ?? [], id: \.self) { conflict in
            Label(conflict, systemImage: "cup.and.saucer.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.orange).lineLimit(1)
                .padding(.top, 2)
        }
        HStack(spacing: 8) {
            if invite.canRespond {
                Pill(title: "Accept", primary: true) { state.answer(invite, .accept) }
                Pill(title: "Maybe") { state.answer(invite, .tentative) }
                Pill(title: "Decline") { state.answer(invite, .decline) }
            } else {
                Pill(title: "Open on Mac", symbol: "laptopcomputer", primary: true) { state.answer(invite, nil) }
                Pill(title: "Later") { state.later(invite) }
            }
        }
        .padding(.top, 14)
    }

    private var subtitle: String {
        let cal = Calendar.current
        // A series whose next occurrence couldn't be found: its first date would mislead.
        let over = m.recurs && m.end <= Date()
        let day = over ? "Repeats"
            : cal.isDateInToday(m.start) ? "Today"
            : cal.isDateInTomorrow(m.start) ? "Tomorrow"
            : m.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return [day, Theme.range(m), m.recurs && !over ? "repeats" : nil, m.organizer].compactMap { $0 }.joined(separator: " · ")
    }

    /// The first accepted meeting it overlaps, if any.
    private var clashesWith: Meeting? {
        state.meetings.first {
            $0.id != m.id && !$0.isAllDay && !m.isAllDay && $0.participation != .declined
                && $0.start < m.end && m.start < $0.end
        }
    }
}

private struct ClashStrip: View {
    @Environment(PhoneState.self) private var state
    let clash: CompanionClash

    var body: some View {
        let breakTime = clash.meetings.first(where: \.isBreak)
        StripHeader(label: breakTime == nil ? "DOUBLE-BOOKED" : "BREAK AT RISK") { state.resolve(clash, choice: nil) }
        Text(breakTime.map { "Keep your \($0.title) break, or give it up today?" } ?? "Which one should I alert you for?")
            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
            .padding(.top, 6)
        VStack(spacing: 6) {
            ForEach(clash.meetings) { m in
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    state.resolve(clash, choice: m.id)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(m.tint).frame(width: 4, height: 28)
                        Text(Theme.time(m.start)).font(.system(size: 14)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                        Text(m.isBreak ? "Keep \(m.title)" : m.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        Image(systemName: m.isBreak ? "cup.and.saucer.fill" : "bell.fill").font(.system(size: 12)).foregroundStyle(m.tint)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.07), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 10)
        Button { state.resolve(clash, choice: "all") } label: {
            Text("Alert me for all of them").font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity).padding(.top, 10)
        }
        .buttonStyle(.plain)
    }
}

private struct ReminderStrip: View {
    @Environment(PhoneState.self) private var state
    let reminder: CompanionReminder

    var body: some View {
        StripHeader(label: "HEADS UP") { state.banner = nil }
        Text(reminder.title)
            .font(.system(size: 20, weight: .bold)).lineLimit(2)
            .padding(.top, 8)
        if !reminder.body.isEmpty {
            Text(reminder.body)
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                .padding(.top, 2)
        }
        if let id = reminder.joinMeetingID {
            HStack {
                Pill(title: state.meeting(id: id).flatMap(state.joinMacName(for:)).map { "Join on \($0)" } ?? "Join", symbol: "video.fill", primary: true) {
                    state.join(id: id)
                    state.banner = nil
                }
            }
            .padding(.top, 14)
        }
    }
}
