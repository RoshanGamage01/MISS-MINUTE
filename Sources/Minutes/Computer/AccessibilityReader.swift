import AppKit
import ApplicationServices
import MinutesCore

/// Reads an app's UI through the Accessibility API and acts on elements by id.
@MainActor
final class AccessibilityReader {
    private var elements: [Int: AXUIElement] = [:]

    struct Snapshot {
        var app: String
        var windowTitle: String?
        var text: String
        var elementCount: Int
    }

    /// Roles worth listing; everything else is just traversed.
    private static let interesting: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXSearchField", "AXStaticText", "AXLink", "AXMenuItem",
        "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXTab", "AXHeading",
        "AXImage", "AXSlider", "AXDisclosureTriangle", "AXCell", "AXRow", "AXTabGroup"
    ]

    private static let actionable: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXSearchField", "AXLink", "AXMenuItem", "AXMenuButton",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXTab", "AXSlider", "AXDisclosureTriangle",
        "AXCell", "AXRow"
    ]

    /// Lists the front window of `app` as text with [id]s for actionable elements.
    func snapshot(of app: NSRunningApplication, maxNodes: Int = 450, maxChars: Int = 10_000) -> Snapshot {
        elements.removeAll()
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium/Electron apps only expose web content once an assistive client asks for it.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let window = Self.attribute(root, kAXFocusedWindowAttribute) as AXUIElement?
            ?? Self.attribute(root, kAXMainWindowAttribute) as AXUIElement?
        let title = window.flatMap { Self.string($0, kAXTitleAttribute) }
        guard let window else {
            return Snapshot(app: app.localizedName ?? "App", windowTitle: nil, text: "(No accessible window.)", elementCount: 0)
        }

        var lines: [String] = []
        var chars = 0
        var nextID = 1
        var seenText = Set<String>()
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        let deadline = Date().addingTimeInterval(1.5)

        while !queue.isEmpty, visited < 4_000, chars < maxChars, nextID <= maxNodes, Date() < deadline {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = Self.string(element, kAXRoleAttribute) ?? ""

            if Self.interesting.contains(role) {
                let label = Self.label(of: element, role: role)
                let value = Self.string(element, kAXValueAttribute).map { String($0.prefix(160)) }
                let short = role.replacingOccurrences(of: "AX", with: "").lowercased()
                var line: String?
                if Self.actionable.contains(role) {
                    if !(label ?? "").isEmpty || !(value ?? "").isEmpty || role == "AXTextField" || role == "AXTextArea" {
                        elements[nextID] = element
                        var parts = ["[\(nextID)] \(short)"]
                        if let label, !label.isEmpty { parts.append("\"\(label)\"") }
                        if let value, !value.isEmpty, value != label { parts.append("value: \"\(value)\"") }
                        if Self.bool(element, kAXFocusedAttribute) == true { parts.append("(focused)") }
                        if Self.bool(element, kAXEnabledAttribute) == false { parts.append("(disabled)") }
                        line = parts.joined(separator: " ")
                        nextID += 1
                    }
                } else if let text = (value?.isEmpty == false ? value : label), !text.isEmpty, !seenText.contains(text) {
                    seenText.insert(text)
                    line = role == "AXHeading" ? "## \(text)" : text
                }
                if let line {
                    lines.append(line)
                    chars += line.count + 1
                }
            }

            if depth < 60, let children = Self.attribute(element, kAXChildrenAttribute) as [AXUIElement]? {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }

        if let selected = Self.selectedText(of: app), !selected.isEmpty {
            lines.insert("Selected text: \"\(selected.prefix(500))\"", at: 0)
        }
        if chars >= maxChars || nextID > maxNodes {
            lines.append("…(more on screen; scroll or look_at_screen for the rest)")
        }
        return Snapshot(app: app.localizedName ?? "App", windowTitle: title, text: lines.joined(separator: "\n"), elementCount: nextID - 1)
    }

    func element(_ id: Int) throws -> AXUIElement {
        guard let element = elements[id] else {
            throw ToolError("Element [\(id)] isn't in the latest read_screen result. Call read_screen again.")
        }
        return element
    }

    /// Presses a button/link/etc.; falls back to clicking its center.
    func press(_ id: Int) throws {
        let element = try element(id)
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
        guard let center = Self.center(of: element) else { throw ToolError("Couldn't press [\(id)].") }
        InputController.click(at: center)
    }

    /// Puts text into a field: focuses it, then sets its value (or types it).
    func setText(_ id: Int, _ text: String) throws {
        let element = try element(id)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success,
           Self.string(element, kAXValueAttribute) == text {
            return
        }
        if let center = Self.center(of: element) { InputController.click(at: center) }
        usleep(80_000)
        try InputController.press("cmd+a")
        InputController.type(text)
    }

    func center(_ id: Int) throws -> CGPoint {
        guard let point = Self.center(of: try element(id)) else { throw ToolError("Element [\(id)] has no position.") }
        return point
    }

    // MARK: - Static helpers

    static func frontWindowTitle(of app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = attribute(root, kAXFocusedWindowAttribute) as AXUIElement? else { return nil }
        return string(window, kAXTitleAttribute)
    }

    /// The app's focused (or main) window in global top-left coordinates, the same space CGEvents use.
    static func frontWindowFrame(of app: NSRunningApplication) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = attribute(root, kAXFocusedWindowAttribute) as AXUIElement?
                ?? attribute(root, kAXMainWindowAttribute) as AXUIElement? else { return nil }
        return frame(of: window)
    }

    /// Where the scrollable area under `point` is scrolled to (0 = top/left, 1 = bottom/right), if it says.
    /// Lets the scroll tool tell whether anything actually moved.
    static func scrollPosition(at point: CGPoint) -> (vertical: Double?, horizontal: Double?)? {
        guard AXIsProcessTrusted() else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        for _ in 0..<25 {
            if string(element, kAXRoleAttribute) == "AXScrollArea" {
                let area = element
                let bar = { (name: String) -> Double? in
                    (Self.attribute(area, name) as AXUIElement?).flatMap { (Self.attribute($0, kAXValueAttribute) as NSNumber?)?.doubleValue }
                }
                let position = (bar(kAXVerticalScrollBarAttribute), bar(kAXHorizontalScrollBarAttribute))
                if position.0 != nil || position.1 != nil { return position }
            }
            guard let parent = attribute(element, kAXParentAttribute) as AXUIElement? else { return nil }
            element = parent
        }
        return nil
    }

    static func selectedText(of app: NSRunningApplication) -> String? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = attribute(root, kAXFocusedUIElementAttribute) as AXUIElement? else { return nil }
        return string(focused, kAXSelectedTextAttribute)
    }

    private static func label(of element: AXUIElement, role: String) -> String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute] {
            if let text = string(element, key), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(text.prefix(120))
            }
        }
        if let titleElement = attribute(element, kAXTitleUIElementAttribute) as AXUIElement?,
           let text = string(titleElement, kAXValueAttribute) ?? string(titleElement, kAXTitleAttribute) {
            return String(text.prefix(120))
        }
        return nil
    }

    static func center(of element: AXUIElement) -> CGPoint? {
        frame(of: element).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute) as AXValue?,
              let sizeValue = attribute(element, kAXSizeAttribute) as AXValue? else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        let value: CFTypeRef? = attribute(element, name)
        if let s = value as? String { return s }
        if let n = value as? NSNumber, name == kAXValueAttribute { return n.stringValue }
        return nil
    }

    private static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        (attribute(element, name) as NSNumber?)?.boolValue
    }
}
