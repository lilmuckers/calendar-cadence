import AppKit
import CadenceCore
import Observation
import SwiftUI

/// The account's photo (or initial) in a circle, with a small badge for the account type
/// in the bottom-right corner.
struct AccountAvatar: View {
    let key: String
    let label: String
    let kind: CalendarKind
    var size: CGFloat = 30

    var body: some View {
        let image = AvatarStore.shared.image(for: key)
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(Color.secondary.opacity(0.35).gradient)
                        Text(initial)
                            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.1)))

            badge
                .frame(width: size * 0.46, height: size * 0.46)
                .background(Circle().fill(kind == .google ? Color.white : Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: size * 0.05))
                .offset(x: size * 0.1, y: size * 0.1)
        }
        .frame(width: size + size * 0.1, height: size + size * 0.1, alignment: .topLeading)
        .help("\(label) · \(kind.label)")
    }

    @ViewBuilder private var badge: some View {
        if kind == .google {
            CalendarKindBadge(kind: kind, size: size * 0.46, circular: true)
        } else {
            CalendarKindBadge(kind: kind, size: size * 0.3)
        }
    }

    private var initial: String {
        String(label.first { $0.isLetter } ?? "?").uppercased()
    }
}
