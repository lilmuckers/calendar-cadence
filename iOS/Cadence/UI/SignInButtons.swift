import SwiftUI

/// "Sign in with Google" and "Sign in with Microsoft", drawn to each company's branding guidelines
/// (Google checks its button during OAuth verification): the standard logo, unaltered, on a neutral
/// light or dark button with the exact wording. Each sits in its own Form row.
struct ProviderSignInButton: View {
    enum Provider { case google, microsoft }

    let provider: Provider
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                logo.frame(width: 18, height: 18)
                Text(provider == .google ? "Sign in with Google" : "Sign in with Microsoft")
                    .font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(text)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder private var logo: some View {
        switch provider {
        case .google:
            Image("GoogleG").resizable().scaledToFit()
        case .microsoft:
            // Microsoft's four-square logo, in its own colours.
            Grid(horizontalSpacing: 1.5, verticalSpacing: 1.5) {
                GridRow { square(0xF25022); square(0x7FBA00) }
                GridRow { square(0x00A4EF); square(0xFFB900) }
            }
        }
    }

    private func square(_ hex: UInt32) -> some View {
        Rectangle().fill(Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                               blue: Double(hex & 0xFF) / 255))
    }

    private var shape: RoundedRectangle {
        // Google: rounded or pill. Microsoft: square corners.
        RoundedRectangle(cornerRadius: provider == .google ? 22 : 2, style: .continuous)
    }

    private var dark: Bool { scheme == .dark }

    // Google's light (#FFFFFF / #747775 / #1F1F1F) and dark (#131314 / #8E918F / #E3E3E3) themes;
    // Microsoft's light (#FFFFFF / #8C8C8C / #5E5E5E) and dark (#2F2F2F / #2F2F2F / #FFFFFF).
    private var fill: Color {
        switch provider {
        case .google: dark ? Color(white: 0x13 / 255) : .white
        case .microsoft: dark ? Color(white: 0x2F / 255) : .white
        }
    }

    private var stroke: Color {
        switch provider {
        case .google: dark ? Color(white: 0x8F / 255) : Color(white: 0x75 / 255)
        case .microsoft: dark ? Color(white: 0x2F / 255) : Color(white: 0x8C / 255)
        }
    }

    private var text: Color {
        switch provider {
        case .google: dark ? Color(white: 0xE3 / 255) : Color(white: 0x1F / 255)
        case .microsoft: dark ? .white : Color(white: 0x5E / 255)
        }
    }
}
