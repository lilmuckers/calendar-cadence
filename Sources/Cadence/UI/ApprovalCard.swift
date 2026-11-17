import AppKit
import CadenceCore
import SwiftUI

struct ApprovalRequest: Identifiable {
    let id = UUID()
    var client: String
    var tool: String
    var summary: String
    var meeting: Meeting
}

/// Asks the user to allow or deny an AI assistant's action, one card at a time (top right).
/// Unanswered requests are denied after a minute.
@MainActor
final class ApprovalController {
    private let state: AppState
    private var panel: FloatingPanel?
    private var queue: [(ApprovalRequest, CheckedContinuation<Bool, Never>)] = []
    private var current: (ApprovalRequest, CheckedContinuation<Bool, Never>)?
    private var timeout: DispatchWorkItem?

    init(state: AppState) { self.state = state }

    func request(_ r: ApprovalRequest) async -> Bool {
        await withCheckedContinuation { cont in
            queue.append((r, cont))
            if current == nil { showNext() }
        }
    }

    private func showNext() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        current = next
        let request = next.0
        let size = NSSize(width: 360, height: 164)
        let panel = FloatingPanel(size: size)
        panel.level = .statusBar
        let view = ApprovalCardView(request: request) { [weak self] decision in self?.finish(decision) }
            .environment(state)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { finish(.deny); return }
        let v = screen.visibleFrame
        let final = NSRect(x: v.maxX - size.width - 14, y: v.maxY - size.height - 14, width: size.width, height: size.height)
        panel.setFrame(final.offsetBy(dx: 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }
        NSSound(named: "Tink")?.play()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.finish(.deny) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    enum Decision { case allow, deny, always }

    private func finish(_ decision: Decision) {
        guard let (request, cont) = current else { return }
        current = nil
        timeout?.cancel()
        if decision == .always { state.prefs.mcpAutoApprove.insert(request.tool) }
        cont.resume(returning: decision != .deny)
        if let panel {
            self.panel = nil
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 }, completionHandler: {
                MainActor.assumeIsolated { panel.orderOut(nil) }
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.showNext() }
    }
}

struct ApprovalCardView: View {
    let request: ApprovalRequest
    let decide: (ApprovalController.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.purple)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.purple.opacity(0.15)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(request.client) wants to…").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(request.summary).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Capsule().fill(request.meeting.tint.gradient).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.meeting.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(Theme.dayTime(request.meeting.start).capitalizedFirst) · \(request.meeting.calendar.title)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06)))
            HStack(spacing: 8) {
                Button("Always allow") { decide(.always) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Let assistants do this without asking (change in Settings → Assistants)")
                Spacer()
                Button { decide(.deny) } label: {
                    Text("Deny").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(.primary.opacity(0.1)))
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut(.cancelAction)
                Button { decide(.allow) } label: {
                    Text("Allow").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Color.purple.gradient))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VisualEffect(material: .hudWindow))
        .background(alignment: .top) {
            LinearGradient(colors: [Color.purple.opacity(0.18), .clear], startPoint: .top, endPoint: .center)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
