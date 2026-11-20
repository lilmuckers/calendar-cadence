import AppKit
import CadenceCore
import SwiftUI

/// Top-right call-to-action shown as soon as overlapping meetings are found:
/// "These clash — which one should I alert you for?"
@MainActor
final class ClashPromptController {
    private let state: AppState
    private var panel: FloatingPanel?
    private var queue: [Clash] = []

    init(state: AppState) { self.state = state }

    func enqueue(_ clash: Clash) {
        guard !queue.contains(where: { $0.key == clash.key }) else { return }
        queue.append(clash)
        if panel == nil { showNext() }
    }

    private func showNext() {
        guard !queue.isEmpty else { return }
        let clash = queue.removeFirst()
        let width: CGFloat = 340
        let height = CGFloat(118 + clash.meetings.count * 54)
        let panel = FloatingPanel(size: NSSize(width: width, height: height))
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        let view = ClashPromptView(clash: clash) { [weak self] choice in
            self?.state.resolveClash(clash, choice: choice)
            self?.close()
        }
        .environment(state)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = host

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        let final = NSRect(x: v.maxX - width - 14, y: v.maxY - height - 14, width: width, height: height)
        panel.setFrame(final.offsetBy(dx: 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }
        NSSound(named: "Funk")?.play()
        self.panel = panel
    }

    private func close() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                self?.showNext()
            }
        })
    }
}

struct ClashPromptView: View {
    let clash: Clash
    let choose: (String?) -> Void

    /// A break the meeting was booked over (Cadence's stand-in), if that's what this is.
    private var breakTime: Meeting? { clash.meetings.first(where: \.isBreak) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: MenuBarIcon.image(.panicking))
                    .renderingMode(.template)
                    .foregroundStyle(.orange)
                    .scaleEffect(1.4)
                    .frame(width: 28, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(breakTime == nil ? "Double-booked!" : "Break at risk!")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(breakTime.map { "Keep your \($0.title) break, or give it up today?" } ?? "Which one should I alert you for?")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { choose(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Decide later (alerts fire for all of them)")
            }

            ForEach(clash.meetings) { m in
                Button { choose(m.id) } label: {
                    HStack(spacing: 10) {
                        Capsule().fill(m.tint.gradient).frame(width: 4, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.isBreak ? "Keep \(m.title)" : m.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(m.isBreak ? "\(Theme.range(m)) · \(clash.meetings.count > 2 ? "these meetings" : "the meeting") won't alert" : "\(Theme.range(m)) · \(m.calendar.title)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: m.isBreak ? "cup.and.saucer.fill" : "bell.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(m.tint)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }

            Button { choose("all") } label: {
                Text("Alert me for all of them")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VisualEffect(material: .hudWindow))
        .background(alignment: .top) {
            LinearGradient(colors: [Color.orange.opacity(0.18), .clear], startPoint: .top, endPoint: .center)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}
