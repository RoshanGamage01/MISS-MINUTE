import AppKit
import SwiftUI
import MinutesCore

/// Draws the app icon from the same renderer as the desktop character, so the icon always matches her.
/// `Minutes --export-icon <dir>` writes an .iconset; Scripts/make-icon.sh turns it into AppIcon.icns.
enum AppIconExporter {
    static let sizes: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024)
    ]

    @MainActor
    static func export(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, pixels) in sizes {
            let renderer = ImageRenderer(content: AppIconView(side: CGFloat(pixels)))
            renderer.scale = 1
            guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}

/// macOS icon layout: a rounded tile filling ~80% of the canvas, with Miss Minute glowing on a dark TVA dial.
struct AppIconView: View {
    let side: CGFloat

    var body: some View {
        Canvas { context, size in
            let s = size.width
            let tileInset = s * 0.098
            let tile = CGRect(x: tileInset, y: tileInset, width: s - 2 * tileInset, height: s - 2 * tileInset)
            let tilePath = Path(roundedRect: tile, cornerRadius: tile.width * 0.225, style: .continuous)

            // Drop shadow under the tile.
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.35), radius: s * 0.02, x: 0, y: s * 0.012))
                layer.fill(tilePath, with: .color(.black))
            }
            // Dark warm dial with an orange bloom behind her.
            context.fill(tilePath, with: .linearGradient(
                Gradient(colors: [Color(hex: 0x2A1A0C), Color(hex: 0x0B0806)]),
                startPoint: CGPoint(x: tile.midX, y: tile.minY), endPoint: CGPoint(x: tile.midX, y: tile.maxY)
            ))
            context.clip(to: tilePath)
            context.fill(Path(ellipseIn: tile.insetBy(dx: -tile.width * 0.1, dy: -tile.width * 0.1)), with: .radialGradient(
                Gradient(colors: [Color(hex: 0xFF8A1E).opacity(0.55), Color(hex: 0xFF8A1E).opacity(0)]),
                center: CGPoint(x: tile.midX, y: tile.midY - tile.height * 0.04), startRadius: 0, endRadius: tile.width * 0.55
            ))

            // TVA-style tick ring (skipped at tiny sizes where it turns to mush).
            if s >= 64 {
                let center = CGPoint(x: tile.midX, y: tile.midY)
                let outer = tile.width * 0.455
                for tick in 0..<60 {
                    let major = tick % 5 == 0
                    let angle = Double(tick) / 60 * 2 * .pi
                    let inner = outer - tile.width * (major ? 0.045 : 0.022)
                    var line = Path()
                    line.move(to: CGPoint(x: center.x + CGFloat(sin(angle)) * inner, y: center.y - CGFloat(cos(angle)) * inner))
                    line.addLine(to: CGPoint(x: center.x + CGFloat(sin(angle)) * outer, y: center.y - CGFloat(cos(angle)) * outer))
                    context.stroke(line, with: .color(Color(hex: 0xFFB45C).opacity(major ? 0.55 : 0.25)),
                                   lineWidth: tile.width * (major ? 0.012 : 0.006))
                }
            }

            // Miss Minute, centred, smiling, hands at 10:10.
            let characterSize = tile.width * 0.6
            let canvas = MissMinuteView.canvasSize(for: characterSize)
            let date = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 10, minute: 10, second: 30))!
            let t = date.timeIntervalSinceReferenceDate
            let body = BodyState()
            body.expression = .happy
            body.expressionUntil = t + 3_600
            let motion = MotionState()
            for step in 0..<90 {
                motion.step(t: t - Double(90 - step) / 30, mood: .announcing, mouth: 0.25, gaze: .zero, body: body)
            }
            context.translateBy(x: tile.midX - canvas.width / 2, y: tile.midY - canvas.height * 0.44)
            var renderer = MissMinuteRenderer(
                t: t, date: date, mood: .announcing, skin: .hologram, hover: false,
                motion: motion, body: body, canvas: canvas
            )
            renderer.draw(in: &context)
        }
        .frame(width: side, height: side)
    }
}
