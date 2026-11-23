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

enum ApprovalResult { case allowed, denied, timedOut }

/// Asks the user to allow or deny an AI assistant's action. Each request is its own card in the
/// right-hand `AlertStack`. Unanswered requests are denied after a minute.
@MainActor
final class ApprovalController {
    private let state: AppState
    private final class Pending {
        let request: ApprovalRequest
        let cont: CheckedContinuation<ApprovalResult, Never>
        var card: AlertStack.Card?
        var timeout: DispatchWorkItem?
        init(_ request: ApprovalRequest, _ cont: CheckedContinuation<ApprovalResult, Never>) {
            self.request = request
            self.cont = cont
        }
    }
    private var pending: [UUID: Pending] = [:]

    init(state: AppState) { self.state = state }

    func request(_ r: ApprovalRequest) async -> ApprovalResult {
        await withCheckedContinuation { cont in show(Pending(r, cont)) }
    }

    private func show(_ p: Pending) {
        let request = p.request
        let id = request.id
        pending[id] = p
        let summary = AlertStack.Summary(symbol: "sparkles", tint: .purple,
                                         title: "\(request.client): \(request.summary)",
                                         subtitle: request.meeting.title)
        p.card = AlertStack.shared.add(summary: summary, height: { 164 }) {
            ApprovalCardView(request: request) { [weak self] decision in self?.finish(id, decision) }
                .environment(state)
        }
        NSSound(named: "Tink")?.play()
        let work = DispatchWorkItem { [weak self] in self?.finish(id, .timeout) }
        p.timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    enum Decision { case allow, deny, always, timeout }

    private func finish(_ id: UUID, _ decision: Decision) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.timeout?.cancel()
        if decision == .always { state.prefs.mcpAutoApprove.insert(p.request.tool) }
        switch decision {
        case .allow, .always: p.cont.resume(returning: .allowed)
        case .deny: p.cont.resume(returning: .denied)
        case .timeout: p.cont.resume(returning: .timedOut)
        }
        p.card?.close()
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
