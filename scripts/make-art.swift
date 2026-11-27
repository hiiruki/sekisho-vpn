// Renders the app icon (1024px PNG) and the DMG window background. Usage: swift make-art.swift <outdir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

/// Draws in `w`x`h` point coordinates into a PNG of `scale` times that many pixels.
func png(_ w: Int, _ h: Int, _ name: String, scale: Int = 1, _ draw: (CGRect) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    draw(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
}

func drawCentered(_ img: NSImage, at c: CGPoint) {
    img.draw(in: CGRect(x: c.x - img.size.width / 2, y: c.y - img.size.height / 2, width: img.size.width, height: img.size.height))
}

/// Apple's app-icon shape: straight sides with continuous-curvature corners. Each corner is a quarter superellipse
/// spanning 1.528·r (where the curvature starts easing, as in Apple's "continuous" corners), with the exponent
/// chosen so the corner's 45° point sits where a plain radius-r corner would.
func squircle(_ rect: CGRect, radius r: CGFloat) -> NSBezierPath {
    let c = 1.528 * r
    let n = log(2) / -log(1 - r * (1 - 1 / sqrt(2)) / c)
    let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [ // inner corner center, direction signs
        (rect.maxX - c, rect.maxY - c, 1, 1), (rect.minX + c, rect.maxY - c, -1, 1),
        (rect.minX + c, rect.minY + c, -1, -1), (rect.maxX - c, rect.minY + c, 1, -1),
    ]
    let p = NSBezierPath()
    for (k, (cx, cy, sx, sy)) in corners.enumerated() {
        for i in 0...90 {
            let t = CGFloat(k % 2 == 0 ? i : 90 - i) * .pi / 180 // walk each quarter counterclockwise
            let pt = CGPoint(x: cx + sx * c * pow(cos(t), 2 / n), y: cy + sy * c * pow(sin(t), 2 / n))
            k == 0 && i == 0 ? p.move(to: pt) : p.line(to: pt)
        }
    }
    p.close()
    return p
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: a) }

/// Vertical gradient fill (top color first).
func fill(_ path: NSBezierPath, _ top: NSColor, _ bottom: NSColor) {
    NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: -90)
}

/// Liquid Glass edge: a rim of `width` inside the shape, bright at the top and dark at the bottom.
func rim(_ path: NSBezierPath, width: CGFloat, top: NSColor, bottom: NSColor) {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.addPath(path.cgPath)
    ctx.clip() // keeps only the inner half of the stroke
    ctx.addPath(path.cgPath)
    ctx.setLineWidth(width * 2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let b = path.bounds
    NSGradient(colors: [top, top.withAlphaComponent(0), bottom.withAlphaComponent(0), bottom],
               atLocations: [0, 0.35, 0.65, 1], colorSpace: .deviceRGB)!
        .draw(from: CGPoint(x: b.midX, y: b.maxY), to: CGPoint(x: b.midX, y: b.minY), options: [])
    ctx.restoreGState()
}

/// Soft drop shadow under whatever `draw` paints.
func shadowed(color: NSColor, blur: CGFloat, dy: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = color
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: dy)
    s.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

// macOS 27 "Golden Gate" look: 824px squircle on the 1024 grid, bold color, sharp shapes, Liquid Glass with dark
// edges and bright specular highlights. Motif: a glass shield (VPN) holding a sekisho checkpoint gate with a
// vermilion roof beam and a keyhole.
png(1024, 1024, "icon_1024.png") { r in
    let tile = squircle(r.insetBy(dx: 100, dy: 100), radius: 185) // 824 px tile, Apple's 185 px corner on the 1024 grid
    shadowed(color: .black.withAlphaComponent(0.32), blur: 28, dy: -12) { NSColor.black.setFill(); tile.fill() }
    fill(tile, rgb(0.20, 0.50, 1.00), rgb(0.07, 0.17, 0.62))
    NSGraphicsContext.saveGraphicsState() // light falling from the top left
    tile.addClip()
    NSGradient(starting: .white.withAlphaComponent(0.28), ending: .white.withAlphaComponent(0))!
        .draw(fromCenter: CGPoint(x: 330, y: 860), radius: 0, toCenter: CGPoint(x: 330, y: 860), radius: 620, options: [])
    NSGraphicsContext.restoreGraphicsState()
    rim(tile, width: 7, top: .white.withAlphaComponent(0.55), bottom: .black.withAlphaComponent(0.30))

    let shield = NSBezierPath()
    shield.move(to: CGPoint(x: 512, y: 832))
    shield.curve(to: CGPoint(x: 730, y: 772), controlPoint1: CGPoint(x: 600, y: 832), controlPoint2: CGPoint(x: 680, y: 800))
    shield.line(to: CGPoint(x: 730, y: 540))
    // full, rounded lower half meeting at a blunt tip (tangents ~20° off horizontal), not a sharp point
    shield.curve(to: CGPoint(x: 512, y: 212), controlPoint1: CGPoint(x: 730, y: 340), controlPoint2: CGPoint(x: 590, y: 240))
    shield.curve(to: CGPoint(x: 294, y: 540), controlPoint1: CGPoint(x: 434, y: 240), controlPoint2: CGPoint(x: 294, y: 340))
    shield.line(to: CGPoint(x: 294, y: 772))
    shield.curve(to: CGPoint(x: 512, y: 832), controlPoint1: CGPoint(x: 344, y: 800), controlPoint2: CGPoint(x: 424, y: 832))
    shield.close()
    shadowed(color: rgb(0.02, 0.06, 0.25, 0.45), blur: 30, dy: -16) { NSColor.white.setFill(); shield.fill() }
    fill(shield, rgb(1, 1, 1), rgb(0.84, 0.89, 1.0)) // frosted glass, tinted by the blue behind it
    rim(shield, width: 9, top: .white, bottom: rgb(0.10, 0.22, 0.60, 0.45))
    NSGraphicsContext.saveGraphicsState() // specular highlight on the upper left of the glass
    shield.addClip()
    NSGradient(starting: .white.withAlphaComponent(0.9), ending: .white.withAlphaComponent(0))!
        .draw(fromCenter: CGPoint(x: 380, y: 790), radius: 0, toCenter: CGPoint(x: 380, y: 790), radius: 190, options: [])
    NSGraphicsContext.restoreGraphicsState()

    let ink = (rgb(0.14, 0.27, 0.64), rgb(0.05, 0.11, 0.34))
    let gate = NSBezierPath()
    gate.append(NSBezierPath(rect: CGRect(x: 400, y: 330, width: 46, height: 340))) // posts
    gate.append(NSBezierPath(rect: CGRect(x: 578, y: 330, width: 46, height: 340)))
    gate.append(NSBezierPath(rect: CGRect(x: 368, y: 586, width: 288, height: 34))) // crossbeam
    gate.windingRule = .nonZero // overlapping rects (same direction) stay filled
    shadowed(color: rgb(0.05, 0.11, 0.34, 0.30), blur: 6, dy: -4) { ink.1.setFill(); gate.fill() } // gradients are
    fill(gate, ink.0, ink.1) //                                                     clipped to the path, so shadow a solid fill

    let keyhole = NSBezierPath(ovalIn: CGRect(x: 480, y: 452, width: 64, height: 64))
    let slot = NSBezierPath() // separate paths: one combined path would cancel where they overlap
    slot.move(to: CGPoint(x: 496, y: 470))
    slot.line(to: CGPoint(x: 528, y: 470))
    slot.line(to: CGPoint(x: 540, y: 390))
    slot.line(to: CGPoint(x: 484, y: 390))
    slot.close()
    fill(keyhole, ink.0, ink.1)
    fill(slot, ink.0, ink.1)

    let roof = NSBezierPath() // upturned ends, like a gate's top beam
    roof.move(to: CGPoint(x: 322, y: 722))
    roof.curve(to: CGPoint(x: 702, y: 722), controlPoint1: CGPoint(x: 450, y: 684), controlPoint2: CGPoint(x: 574, y: 684))
    roof.line(to: CGPoint(x: 684, y: 672))
    roof.curve(to: CGPoint(x: 340, y: 672), controlPoint1: CGPoint(x: 574, y: 642), controlPoint2: CGPoint(x: 450, y: 642))
    roof.close()
    shadowed(color: rgb(0.45, 0.08, 0.04, 0.35), blur: 8, dy: -5) { rgb(0.84, 0.18, 0.10).setFill(); roof.fill() }
    fill(roof, rgb(1.0, 0.42, 0.27), rgb(0.84, 0.18, 0.10))
    rim(roof, width: 5, top: .white.withAlphaComponent(0.65), bottom: rgb(0.45, 0.06, 0.02, 0.5))
}

// DMG window content is 640x400 points; Finder icon positions (from top) are y=175, so y=225 from bottom.
for scale in [1, 2] {
    png(640, 400, scale == 1 ? "dmg_background.png" : "dmg_background@2x.png", scale: scale) { r in
        NSColor(white: 0.97, alpha: 1).setFill()
        r.fill()
        drawCentered(symbol("arrow.right", size: 56, color: NSColor(white: 0.55, alpha: 1)), at: CGPoint(x: r.midX, y: 225))
        let text = "Drag Sekisho to Applications" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                    .foregroundColor: NSColor(white: 0.35, alpha: 1)]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: r.midX - size.width / 2, y: 70), withAttributes: attrs)
    }
}
