import SwiftUI
import MinutesCore

enum MinutesTheme {
    static func panelBackground(for scheme: ColorScheme) -> LinearGradient {
        switch scheme {
        case .dark:
            return LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.11, blue: 0.14),
                    Color(red: 0.08, green: 0.09, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.98, blue: 0.92),
                    Color(red: 0.96, green: 0.93, blue: 0.84)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    static func userBubble(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.95, green: 0.55, blue: 0.22)
            : Color(red: 0.85, green: 0.45, blue: 0.18)
    }

    static func assistantBubble(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.85)
    }

    static func preferredColorScheme(for mode: AppearanceMode) -> ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
