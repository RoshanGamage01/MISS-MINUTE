import AppKit
import ScreenCaptureKit
import MinutesCore

/// Screenshots of the display, with Miss Minute's own windows left out.
enum ScreenCapture {
    struct Shot {
        var image: ImageAttachment
        /// The captured display in global Core Graphics coordinates (points, top-left origin).
        var displayFrame: CGRect

        /// Converts a pixel in the screenshot to a global screen point for mouse events.
        func screenPoint(x: Double, y: Double) -> CGPoint {
            CGPoint(
                x: displayFrame.minX + CGFloat(x) * displayFrame.width / CGFloat(image.width),
                y: displayFrame.minY + CGFloat(y) * displayFrame.height / CGFloat(image.height)
            )
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (first time) or does nothing if already decided.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures the display under the mouse (or the main display).
    static func capture(maxDimension: Int = 1280, quality: Double = 0.6) async throws -> Shot {
        guard hasPermission else {
            requestPermission()
            throw ToolError("I need Screen Recording permission to see your screen. Turn on Miss Minute in System Settings → Privacy & Security → Screen & System Audio Recording, then ask again. (read_screen works without it.)")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = await MainActor.run { cgMouseLocation() }
        guard let display = content.displays.first(where: { $0.frame.contains(mouse) }) ?? content.displays.first else {
            throw ToolError("No display to capture.")
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let frame = display.frame
        let scale = min(1, Double(maxDimension) / Double(max(frame.width, frame.height)))
        let config = SCStreamConfiguration()
        config.width = max(1, Int(Double(frame.width) * scale))
        config.height = max(1, Int(Double(frame.height) * scale))
        config.showsCursor = true

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw ToolError("Couldn't encode the screenshot.")
        }
        return Shot(image: ImageAttachment(jpeg: jpeg, width: cgImage.width, height: cgImage.height), displayFrame: frame)
    }

    /// Mouse location in global CG coordinates (top-left origin).
    @MainActor
    static func cgMouseLocation() -> CGPoint {
        let cocoa = NSEvent.mouseLocation
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: cocoa.x, y: mainHeight - cocoa.y)
    }
}
