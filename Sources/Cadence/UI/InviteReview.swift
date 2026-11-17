import AppKit
import CadenceCore
import SwiftUI

/// Top-right card listing invitations that still need a reply, with Accept / Maybe / Decline
/// and (for calendars that ask for it) a colour picker.
@MainActor
final class InviteReviewController {
    private let state: AppState
    private var panel: FloatingPanel?
    private let model = InviteReviewModel()

    init(state: AppState) { self.state = state }

    func show(_ invites: [Meeting], reason: InvitePromptReason) {
        guard !invites.isEmpty else { return }
        // New arrivals join whatever is already on screen.
        if panel != nil {
            for m in invites where !model.items.contains(where: { $0.id == m.id }) { model.items.append(m) }
            model.reason = reason == .new && model.reason == .new ? .new : model.reason
            resize(animated: true)
            return
        }
        model.items = invites
        model.reason = reason
        model.errors = [:]
        present()
    }

    private func size() -> NSSize {
        let rows = model.items.prefix(4).reduce(CGFloat(0)) { $0 + (state.wantsColorPrompt($1) ? 116 : 84) }
        return NSSize(width: 360, height: 76 + max(rows, 84) + (model.items.count > 4 ? 18 : 0))
    }

    private func present() {
        let size = size()
        let panel = FloatingPanel(size: size)
        panel.level = .statusBar
        let view = InviteReviewView(model: model, close: { [weak self] in self?.close() },
                                    changed: { [weak self] in self?.itemsChanged() })
            .environment(state)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        let final = NSRect(x: v.maxX - size.width - 14, y: v.maxY - size.height - 14, width: size.width, height: size.height)
        panel.setFrame(final.offsetBy(dx: 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }
        NSSound(named: "Glass")?.play()
        self.panel = panel
    }

    private func itemsChanged() {
        if model.items.isEmpty { close() } else { resize(animated: true) }
    }

    private func resize(animated: Bool) {
        guard let panel else { return }
        let size = size()
        var f = panel.frame
        f = NSRect(x: f.maxX - size.width, y: f.maxY - size.height, width: size.width, height: size.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.25 : 0
            panel.animator().setFrame(f, display: true)
        }
    }

    private func close() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }
}

@MainActor
@Observable
final class InviteReviewModel {
    var items: [Meeting] = []
    var reason: InvitePromptReason = .manual
    var busy: Set<String> = []
    var errors: [String: String] = [:]
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
        let busy = model.busy.contains(m.id)
        let canReply = state.canRespond(m)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(m.tint.gradient).frame(width: 4, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(when(m) + (m.organizer.map { " · \($0)" } ?? ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 6) {
                if canReply {
                    ForEach(RSVP.allCases, id: \.self) { reply in
                        Button { send(m, reply) } label: {
                            Label(reply.label, systemImage: symbol(reply))
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .foregroundStyle(reply == .accept ? .white : .primary)
                                .background(Capsule().fill(reply == .accept ? AnyShapeStyle(m.tint.gradient) : AnyShapeStyle(.primary.opacity(0.08))))
                        }
                        .buttonStyle(PressableStyle())
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
            .disabled(busy)
            if state.wantsColorPrompt(m) {
                ColorSwatches(meeting: m) { choice in paint(m, choice) }
            }
            if let error = model.errors[m.id] {
                Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05)))
        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
    }

    private func when(_ m: Meeting) -> String {
        let day = Calendar.current.isDateInToday(m.start) ? "Today"
            : Calendar.current.isDateInTomorrow(m.start) ? "Tomorrow"
            : m.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        if m.recurs && m.start < Calendar.current.startOfDay(for: Date()) { return "Repeats · \(Theme.range(m))" }
        return m.isAllDay ? "\(day) · all day" : "\(day) · \(Theme.range(m))" + (m.recurs ? " · repeats" : "")
    }

    private func symbol(_ r: RSVP) -> String {
        switch r {
        case .accept: "checkmark"
        case .tentative: "questionmark"
        case .decline: "xmark"
        }
    }

    private func send(_ m: Meeting, _ reply: RSVP) {
        model.busy.insert(m.id)
        model.errors[m.id] = nil
        Task {
            do {
                try await state.respond(m, reply)
                withAnimation(.spring(duration: 0.35)) { model.items.removeAll { $0.id == m.id } }
                changed()
            } catch {
                model.errors[m.id] = error.localizedDescription
            }
            model.busy.remove(m.id)
        }
    }

    private func paint(_ m: Meeting, _ choice: EventColorChoice?) {
        Task {
            do {
                try await state.setColor(m, choice)
                if let i = model.items.firstIndex(where: { $0.id == m.id }) { model.items[i].eventColor = choice?.color }
            } catch {
                model.errors[m.id] = error.localizedDescription
            }
        }
    }
}

/// Google's eleven event colours plus "calendar colour".
struct ColorSwatches: View {
    let meeting: Meeting
    let pick: (EventColorChoice?) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button { pick(nil) } label: {
                Circle().strokeBorder(Color(meeting.calendar.color), lineWidth: 2)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(PressableStyle())
            .help("Calendar colour")
            ForEach(EventColorChoice.palette) { c in
                Button { pick(c) } label: {
                    Circle().fill(Color(c.color))
                        .frame(width: 16, height: 16)
                        .overlay {
                            if meeting.eventColor == c.color {
                                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(PressableStyle())
                .help(c.name)
            }
        }
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
        Menu("Colour") {
            Button("Calendar Colour") { Task { try? await state.setColor(meeting, nil) } }
            Divider()
            ForEach(EventColorChoice.palette) { c in
                Button { Task { try? await state.setColor(meeting, c) } } label: {
                    Label { Text(c.name) } icon: { Image(nsImage: Self.dot(c.color)) }
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
