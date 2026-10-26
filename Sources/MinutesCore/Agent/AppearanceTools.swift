import Foundation

/// Lets her change her own look when asked ("change into your night look", "go formal", "back to normal").
@MainActor
public enum AppearanceTools {
    /// `current` reads the look she's wearing; `apply` saves a new one (the body animates the change).
    public static func all(
        current: @escaping @MainActor () -> AvatarLook,
        apply: @escaping @MainActor (AvatarLook) async -> Void
    ) -> [AgentTool] {
        let names = AvatarLook.allCases.map(\.rawValue)
        let menu = AvatarLook.allCases.map { "\($0.rawValue) (\($0.summary))" }.joined(separator: "; ")
        return [
            AgentTool(spec: .object(
                "change_look",
                "Change how you look on screen: your colors, glow, and accessory. Use when the user asks you to change " +
                "into a look, outfit, theme, or style (\"your night look\", \"go formal\", \"back to normal\"). The look " +
                "stays until they ask for another; your working glows still show on top of it. Looks: \(menu).",
                properties: ["look": ["type": "string", "enum": .array(names.map { .string($0) })]],
                required: ["look"]
            )) { args in
                let asked = try args.requiredString("look")
                guard let look = AvatarLook.matching(asked) else {
                    throw ToolError("No look called \"\(asked)\". Pick one of: \(names.joined(separator: ", ")).")
                }
                if current() == look {
                    return .ok("You're already wearing the \(look.displayName) look (\(look.summary)).")
                }
                await apply(look)
                return .ok("Changed into the \(look.displayName) look: \(look.summary). It stays on until they ask for another.",
                           summary: "Changed into the \(look.displayName) look")
            }
        ]
    }
}
