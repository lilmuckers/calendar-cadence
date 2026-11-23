import AppKit
import CadenceCore
import SwiftUI

/// Call-to-action shown as soon as overlapping meetings are found:
/// "These clash — which one should I alert you for?" Each clash is its own card in the
/// right-hand `AlertStack`.
@MainActor
final class ClashPromptController {
    private let state: AppState
    private var cards: [String: AlertStack.Card] = [:]

    init(state: AppState) { self.state = state }

    func enqueue(_ clash: Clash) {
        guard cards[clash.key] == nil else { return }
        let height = CGFloat(118 + clash.meetings.count * 54)
        let isBreak = clash.meetings.contains(where: \.isBreak)
        let titles = clash.meetings.filter { !$0.isBreak }.map(\.title)
        let summary = AlertStack.Summary(
            symbol: isBreak ? "cup.and.saucer.fill" : "exclamationmark.triangle.fill", tint: .orange,
            title: isBreak ? "Break at risk" : "Double-booked: \(clash.meetings.count) meetings",
            subtitle: (clash.meetings.first.map { Theme.range($0) + " · " } ?? "") + titles.joined(separator: " vs "))
        let card = AlertStack.shared.add(summary: summary, height: { height }) {
            ClashPromptView(clash: clash) { [weak self] choice in
                self?.state.resolveClash(clash, choice: choice)
                self?.close(clash.key)
            }
            .environment(state)
        }
        cards[clash.key] = card
        NSSound(named: "Funk")?.play()
    }

    private func close(_ key: String) {
        cards.removeValue(forKey: key)?.close()
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
