import AppKit
import SwiftUI

/// The column of Cadence's own cards down the right of the screen (clashes, invites, assistant
/// approvals). The open card is always the top one; the rest sit under it as one-line drawers
/// saying what they are. Clicking a drawer moves it to the top and opens it (the card that was
/// open folds into a drawer under it). Resolving the open card closes it, the rest move up, and
/// the new top one opens.
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
        let model: StackCardModel
        var height: () -> CGFloat

        init(id: UUID, panel: FloatingPanel, model: StackCardModel, height: @escaping () -> CGFloat) {
            self.id = id
            self.panel = panel
            self.model = model
            self.height = height
        }
    }

    /// Top to bottom; the first is the open one.
    private var entries: [Entry] = []
    private var screen: NSScreen?
    /// Bumped on every layout, so a finished animation from an older layout leaves things alone.
    private var generation = 0

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
        let id = UUID()
        let model = StackCardModel(summary: summary, fullHeight: height())
        let panel = FloatingPanel(size: NSSize(width: Self.width, height: Self.drawerHeight))
        panel.level = .statusBar
        panel.isMovableByWindowBackground = false
        let root = StackCardView(model: model, open: { [weak self] in self?.open(id) }, content: content())
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        let entry = Entry(id: id, panel: panel, model: model, height: height)
        entries.append(entry)
        if screen == nil { screen = NSScreen.main ?? NSScreen.screens.first }

        // Slide in from the right at its place in the column.
        model.expanded = entries.first === entry
        if let target = frames()[id] {
            panel.setFrame(target.offsetBy(dx: 40, dy: 0), display: false)
            host.frame = NSRect(origin: .zero, size: target.size)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        layout(animated: true)
        return Card(id: id, stack: self)
    }

    // MARK: Internals

    private func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }

    /// A drawer was clicked: it moves to the top and opens.
    private func open(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), index > 0 else { return }
        entries.insert(entries.remove(at: index), at: 0)
        layout(animated: true)
    }

    private func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let panel = entries.remove(at: index).panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 30, dy: 0), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        if entries.isEmpty { screen = nil }
        layout(animated: true)
    }

    /// Where each card goes: top-right down, the open (first) one at full height, the others as drawers.
    private func frames() -> [UUID: NSRect] {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return [:] }
        let v = screen.visibleFrame
        var top = v.maxY - Self.margin
        var out: [UUID: NSRect] = [:]
        for (i, entry) in entries.enumerated() {
            let h = i == 0 ? entry.height() : Self.drawerHeight
            out[entry.id] = NSRect(x: v.maxX - Self.width - Self.margin, y: top - h, width: Self.width, height: h)
            top -= h + Self.gap
        }
        return out
    }

    func layout(animated: Bool) {
        generation += 1
        let pass = generation
        let targets = frames()
        for (i, entry) in entries.enumerated() {
            guard let target = targets[entry.id] else { continue }
            let open = i == 0
            entry.model.fullHeight = entry.height()
            if entry.model.expanded != open {
                withAnimation(.easeOut(duration: 0.22)) { entry.model.expanded = open }
            }
            let panel = entry.panel
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = animated ? 0.28 : 0
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, pass == self.generation, self.entries.contains(where: { $0 === entry }) else { return }
                    // A dropped window animation can leave a card short of its place (part off
                    // the edge of the screen): snap it there.
                    if entry.panel.frame != target {
                        entry.panel.setFrame(target, display: true)
                        entry.panel.alphaValue = 1
                    }
                    // The window's shadow follows the shape it had when first drawn: redo it for
                    // the new size, or a drawer keeps the open card's outline.
                    entry.panel.invalidateShadow()
                }
            })
        }
    }
}

@MainActor
@Observable
final class StackCardModel {
    var summary: AlertStack.Summary
    var expanded = false
    /// The open card's height: its content is laid out at this size and clipped while the
    /// window is smaller, so it doesn't squash as the window grows or shrinks.
    var fullHeight: CGFloat
    init(summary: AlertStack.Summary, fullHeight: CGFloat) {
        self.summary = summary
        self.fullHeight = fullHeight
    }
}

/// One card in the stack: its full content when open, a one-line drawer otherwise. Both are
/// pinned to the top of the window and clipped to it.
private struct StackCardView<Content: View>: View {
    let model: StackCardModel
    let open: () -> Void
    let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            content
                .frame(height: model.fullHeight)
                .opacity(model.expanded ? 1 : 0)
                .allowsHitTesting(model.expanded)
            drawer
                .opacity(model.expanded ? 0 : 1)
                .allowsHitTesting(!model.expanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .ignoresSafeArea()
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
            .frame(maxWidth: .infinity)
            .frame(height: AlertStack.drawerHeight)
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
