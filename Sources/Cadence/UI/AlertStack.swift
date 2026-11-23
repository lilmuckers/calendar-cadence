import AppKit
import SwiftUI

/// The column of Cadence's own cards down the right of the screen (clashes, invites, assistant
/// approvals). One card is open at a time — the top one unless another was clicked — and the rest
/// sit folded under it as one-line drawers saying what they are. Resolving the open card closes
/// it, the rest move up, and the top one opens.
@MainActor
final class AlertStack {
    static let shared = AlertStack()

    /// What a folded card says about itself.
    struct Summary {
        var symbol: String
        var tint: Color
        var title: String
        var subtitle: String
    }

    static let width: CGFloat = 360
    static let drawerHeight: CGFloat = 50
    private static let margin: CGFloat = 14
    private static let gap: CGFloat = 8

    @MainActor private final class Entry {
        let id: UUID
        let panel: FloatingPanel
        let host: NSView
        let model: StackCardModel
        var height: () -> CGFloat

        init(id: UUID, panel: FloatingPanel, host: NSView, model: StackCardModel, height: @escaping () -> CGFloat) {
            self.id = id
            self.panel = panel
            self.host = host
            self.model = model
            self.height = height
        }
    }

    private var entries: [Entry] = []
    private var openID: UUID?
    private var screen: NSScreen?

    /// A handle a card's owner keeps to update or close it.
    struct Card {
        fileprivate let id: UUID
        fileprivate weak var stack: AlertStack?

        @MainActor func close() { stack?.remove(id) }
        /// The open height changed (the invite list grew or shrank).
        @MainActor func relayout() { stack?.layout(animated: true) }
        @MainActor func setSummary(_ summary: Summary) { stack?.entry(id)?.model.summary = summary }
    }

    /// Adds a card at the bottom of the column (open straight away if it's the only one).
    /// `height` is the open card's height, asked again on every `relayout()`.
    func add<Content: View>(summary: Summary, height: @escaping () -> CGFloat, @ViewBuilder content: () -> Content) -> Card {
        let model = StackCardModel(summary: summary)
        let full = NSSize(width: Self.width, height: height())
        let panel = FloatingPanel(size: full)
        panel.level = .statusBar
        panel.isMovableByWindowBackground = false

        // The card's SwiftUI view is pinned to the top of a clipping container, so the panel can
        // grow and shrink around it without the content being squashed mid-animation.
        let container = TopAnchoredView(frame: NSRect(origin: .zero, size: full))
        container.autoresizingMask = [.width, .height]
        let id = UUID()
        let root = StackCardView(model: model, open: { [weak self] in self?.open(id) }, content: content())
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: full)
        container.addSubview(host)
        panel.contentView = container

        let entry = Entry(id: id, panel: panel, host: host, model: model, height: height)
        entries.append(entry)
        if openID == nil { openID = id }
        if screen == nil { screen = NSScreen.main ?? NSScreen.screens.first }

        // Slide in from the right at its place in the column.
        model.expanded = openID == id
        let target = frames()[id] ?? NSRect(origin: .zero, size: full)
        if !model.expanded { host.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.drawerHeight) }
        panel.setFrame(target.offsetBy(dx: 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        layout(animated: true)
        return Card(id: id, stack: self)
    }

    // MARK: Internals

    private func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }

    private func open(_ id: UUID) {
        guard openID != id, entry(id) != nil else { return }
        openID = id
        layout(animated: true)
    }

    private func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        let panel = entry.panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 30, dy: 0), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        if openID == id { openID = entries.first?.id }
        if entries.isEmpty { screen = nil }
        layout(animated: true)
    }

    /// Where each card goes: top-right down, the open one at full height, the others as drawers.
    private func frames() -> [UUID: NSRect] {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return [:] }
        let v = screen.visibleFrame
        var top = v.maxY - Self.margin
        var out: [UUID: NSRect] = [:]
        for entry in entries {
            let id = entry.id
            let h = id == openID ? entry.height() : Self.drawerHeight
            out[id] = NSRect(x: v.maxX - Self.width - Self.margin, y: top - h, width: Self.width, height: h)
            top -= h + Self.gap
        }
        return out
    }

    func layout(animated: Bool) {
        let targets = frames()
        for entry in entries {
            let id = entry.id
            guard let target = targets[id] else { continue }
            let open = id == openID
            if open != entry.model.expanded || open {
                // Opening: give the content its full height first, then let the panel grow round it.
                if open { entry.host.frame = NSRect(x: 0, y: 0, width: Self.width, height: target.height) }
                withAnimation(.easeOut(duration: 0.2)) { entry.model.expanded = open }
            }
            let panel = entry.panel
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = animated ? 0.28 : 0
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.entries.contains(where: { $0 === entry }) else { return }
                    // An interrupted or dropped window animation can leave a card short of its
                    // place (part off the edge of the screen): snap it to where it belongs now.
                    if let now = self.frames()[entry.id], entry.panel.frame != now {
                        entry.panel.setFrame(now, display: true)
                        entry.panel.alphaValue = 1
                    }
                    // Closed down to a drawer: trim the content to match.
                    if entry.id != self.openID {
                        entry.host.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.drawerHeight)
                    }
                }
            })
        }
    }
}

/// Keeps its subviews' origin at the top-left and clips them, so a panel shrinking around a card
/// cuts off the bottom rather than pushing the content down.
private final class TopAnchoredView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
@Observable
final class StackCardModel {
    var summary: AlertStack.Summary
    var expanded = false
    init(summary: AlertStack.Summary) { self.summary = summary }
}

/// One card in the stack: its full content when open, a one-line drawer otherwise.
private struct StackCardView<Content: View>: View {
    let model: StackCardModel
    let open: () -> Void
    let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            content
                .opacity(model.expanded ? 1 : 0)
                .allowsHitTesting(model.expanded)
            if !model.expanded {
                drawer.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var drawer: some View {
        let s = model.summary
        return Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: s.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(s.tint)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(s.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: AlertStack.drawerHeight)
            .frame(maxWidth: .infinity)
            .background(VisualEffect(material: .hudWindow))
            .background(LinearGradient(colors: [s.tint.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this")
    }
}
