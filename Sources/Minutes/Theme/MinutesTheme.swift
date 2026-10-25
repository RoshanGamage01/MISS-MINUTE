import SwiftUI
import MinutesCore

/// TVA-inspired palette: warm amber light on deep brown-black, with retro monospace accents.
enum MinutesTheme {
    static let amber = Color(red: 1.0, green: 0.56, blue: 0.13)
    static let amberSoft = Color(red: 1.0, green: 0.72, blue: 0.42)
    static let cream = Color(red: 1.0, green: 0.93, blue: 0.84)

    static func panelBackground(for scheme: ColorScheme) -> LinearGradient {
        switch scheme {
        case .dark:
            return LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.07, blue: 0.04),
                    Color(red: 0.06, green: 0.04, blue: 0.03)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        default:
            return LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.97, blue: 0.92),
                    Color(red: 0.97, green: 0.92, blue: 0.84)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? amber : Color(red: 0.85, green: 0.37, blue: 0.05)
    }

    static func userBubble(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.95, green: 0.50, blue: 0.12)
            : Color(red: 0.88, green: 0.42, blue: 0.10)
    }

    static func assistantBubble(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1.0, green: 0.6, blue: 0.2).opacity(0.10)
            : Color.white.opacity(0.9)
    }

    static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? amber.opacity(0.22) : Color.black.opacity(0.08)
    }

    /// Small caps label in the TVA terminal style.
    static func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.6)
    }

    static func preferredColorScheme(for mode: AppearanceMode) -> ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
