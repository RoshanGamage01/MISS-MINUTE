import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MinutesCore

/// Synthesized mouse and keyboard input (requires Accessibility permission).
enum InputController {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt if not yet trusted.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func requireAccessibility() throws {
        guard hasAccessibility else {
            requestAccessibility()
            throw ToolError("I need Accessibility permission to use the mouse and keyboard. Turn on Miss Minute in System Settings → Privacy & Security → Accessibility, then ask again.")
        }
    }

    // MARK: Mouse

    static func move(to point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func click(at point: CGPoint, right: Bool = false, count: Int = 1) {
        move(to: point)
        usleep(60_000)
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = right ? .right : .left
        for n in 1...max(1, count) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                event?.post(tap: .cghidEventTap)
                usleep(20_000)
            }
        }
    }

    static func drag(from start: CGPoint, to end: CGPoint) {
        move(to: start)
        usleep(50_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        let steps = 20
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Scrolls by "notches" (positive = down/right).
    static func scroll(dy: Int, dx: Int, at point: CGPoint?) {
        if let point { move(to: point); usleep(40_000) }
        for _ in 0..<max(abs(dy), abs(dx)) {
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                wheel1: Int32(dy == 0 ? 0 : (dy > 0 ? -3 : 3)),
                wheel2: Int32(dx == 0 ? 0 : (dx > 0 ? -3 : 3)),
                wheel3: 0
            )
            event?.post(tap: .cghidEventTap)
            usleep(25_000)
        }
    }

    // MARK: Keyboard

    /// Types text as Unicode keystrokes (works for any language). Newlines press Return.
    static func type(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let units = Array(line.utf16)
            var start = 0
            while start < units.count {
                let chunk = Array(units[start..<min(start + 16, units.count)])
                for keyDown in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
                    event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event?.post(tap: .cghidEventTap)
                }
                usleep(8_000)
                start += 16
            }
            if index < lines.count - 1 { tap(CGKeyCode(kVK_Return)) }
        }
    }

    /// Presses a combination like "cmd+shift+t", "enter", "esc", "down".
    static func press(_ combo: String) throws {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for raw in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch raw {
            case "cmd", "command", "⌘", "meta", "super": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default:
                guard let code = keyCodes[raw] else { throw ToolError("Unknown key '\(raw)'.") }
                key = code
            }
        }
        guard let key else { throw ToolError("No key in '\(combo)'.") }
        tap(key, flags: flags)
    }

    private static func tap(_ key: CGKeyCode, flags: CGEventFlags = []) {
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }

    static let keyCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
            "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
            "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
            "esc": kVK_Escape, "escape": kVK_Escape,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown
        ].mapValues { CGKeyCode($0) }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() {
            map["f\(index + 1)"] = CGKeyCode(code)
        }
        return map
    }()
}
