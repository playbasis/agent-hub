import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Design canvas is 1024pt; every coordinate below is in that space and is
// scaled at draw time, so a 16pt render is the same geometry, not a resample.
let CANVAS: CGFloat = 1024

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let claudeCoral = rgb(217, 119, 87)
let codexTeal = rgb(16, 163, 127)

/// Apple's app-icon silhouette is a superellipse (continuous curvature), not a
/// circular-cornered rounded rect. |x/a|^n + |y/b|^n = 1 with n≈5 matches it
/// closely; sampling it as a dense polygon is exact enough at these sizes.
func superellipse(in rect: CGRect, n: CGFloat = 5.0, samples: Int = 1440) -> CGPath {
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let path = CGMutablePath()
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: stops.map { $0.0 } as CFArray,
        locations: stops.map { $0.1 }
    )!
}

/// Fill the current path with a vertical gradient, top-to-bottom.
func fillVertical(_ ctx: CGContext, _ path: CGPath, _ stops: [(CGColor, CGFloat)], in rect: CGRect) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(stops),
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )
    ctx.restoreGState()
}

/// Stroke a path with a horizontal gradient by converting the stroke to a fill
/// region and clipping the gradient to it.
func strokeHorizontalGradient(
    _ ctx: CGContext, _ path: CGPath, width: CGFloat,
    _ stops: [(CGColor, CGFloat)], from x0: CGFloat, to x1: CGFloat,
    cap: CGLineCap = .round
) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineCap(cap)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(stops),
        start: CGPoint(x: x0, y: CANVAS / 2),
        end: CGPoint(x: x1, y: CANVAS / 2),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

func drawBase(_ ctx: CGContext) -> CGPath {
    // Apple's grid insets the silhouette ~100/1024 per side.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = superellipse(in: plate)

    // Contact shadow. Measured against the neighbours this sits beside in
    // Launchpad — Docker and Tailscale spill 26px, DBngin 12px, zoom 30px — so
    // anything larger reads as a detached halo rather than a seated icon. An
    // earlier revision used offset -18/blur 44, which spilled 60px and looked
    // visibly wrong next to them. Keep the offset small: Launchpad and the Dock
    // composite their own shadow on top of this one.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 17,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.34))
    ctx.addPath(path)
    ctx.setFillColor(rgb(20, 19, 26))
    ctx.fillPath()
    ctx.restoreGState()

    fillVertical(ctx, path, [
        (rgb(74, 68, 88), 0.0),
        (rgb(45, 42, 56), 0.45),
        (rgb(20, 19, 26), 1.0),
    ], in: plate)

    // Specular top edge: a thin bright rim that fades, which is what reads as
    // "material" rather than a flat plate.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([
            (CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22), 0.0),
            (CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0), 0.18),
        ]),
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.minY),
        options: []
    )
    ctx.restoreGState()

    // Hairline inner rim for edge definition at small sizes.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(3)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.strokePath()
    ctx.restoreGState()

    return path
}

// MARK: - Variants

/// A: an arc spanning two nodes — the "bridge" read.
func drawArcBridge(_ ctx: CGContext) {
    // Sized so the glyph spans ~70% of the 824pt plate, matching the optical
    // weight of Docker and Tailscale beside it. The earlier version sat at ~61%
    // and read as small inside too much empty plate.
    let leftNode = CGPoint(x: 310, y: 430)
    let rightNode = CGPoint(x: 714, y: 430)
    let nodeRadius: CGFloat = 85
    let coreRadius: CGFloat = 32

    let span = CGMutablePath()
    span.move(to: leftNode)
    span.addQuadCurve(to: rightNode, control: CGPoint(x: 512, y: 880))
    strokeHorizontalGradient(ctx, span, width: 66,
                             [(claudeCoral, 0.0), (codexTeal, 1.0)],
                             from: leftNode.x, to: rightNode.x)

    for (pt, color) in [(leftNode, claudeCoral), (rightNode, codexTeal)] {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: pt.x - nodeRadius, y: pt.y - nodeRadius,
                                   width: nodeRadius * 2, height: nodeRadius * 2))
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.075, blue: 0.10, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: pt.x - coreRadius, y: pt.y - coreRadius,
                                   width: coreRadius * 2, height: coreRadius * 2))
    }
}

/// B: interlocking rings — a woven link, unmistakable at 16pt.
func drawInterlock(_ ctx: CGContext) {
    let r: CGFloat = 148
    let lw: CGFloat = 62
    let left = CGPoint(x: 430, y: 512)
    let right = CGPoint(x: 594, y: 512)

    func ring(_ c: CGPoint) -> CGPath {
        CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
    }

    ctx.saveGState()
    ctx.addPath(ring(left)); ctx.setLineWidth(lw); ctx.setStrokeColor(claudeCoral); ctx.strokePath()
    ctx.addPath(ring(right)); ctx.setLineWidth(lw); ctx.setStrokeColor(codexTeal); ctx.strokePath()
    ctx.restoreGState()

    // Re-draw the left ring's upper crossing so the two rings weave instead of
    // one simply sitting on top of the other.
    ctx.saveGState()
    ctx.addRect(CGRect(x: 430, y: 560, width: 240, height: 200))
    ctx.clip()
    ctx.addPath(ring(left)); ctx.setLineWidth(lw); ctx.setStrokeColor(claudeCoral); ctx.strokePath()
    ctx.restoreGState()
}

/// C: opposed chevrons — an explicit two-way handoff.
func drawHandoff(_ ctx: CGContext) {
    let lw: CGFloat = 66

    // Upper chevron pointing right (Claude -> Codex).
    let upper = CGMutablePath()
    upper.move(to: CGPoint(x: 372, y: 660))
    upper.addLine(to: CGPoint(x: 560, y: 660))
    let upperHead = CGMutablePath()
    upperHead.move(to: CGPoint(x: 500, y: 728))
    upperHead.addLine(to: CGPoint(x: 578, y: 660))
    upperHead.addLine(to: CGPoint(x: 500, y: 592))

    // Lower chevron pointing left (Codex -> Claude).
    let lower = CGMutablePath()
    lower.move(to: CGPoint(x: 652, y: 396))
    lower.addLine(to: CGPoint(x: 464, y: 396))
    let lowerHead = CGMutablePath()
    lowerHead.move(to: CGPoint(x: 524, y: 464))
    lowerHead.addLine(to: CGPoint(x: 446, y: 396))
    lowerHead.addLine(to: CGPoint(x: 524, y: 328))

    ctx.saveGState()
    ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(claudeCoral)
    ctx.addPath(upper); ctx.strokePath()
    ctx.addPath(upperHead); ctx.strokePath()
    ctx.setStrokeColor(codexTeal)
    ctx.addPath(lower); ctx.strokePath()
    ctx.addPath(lowerHead); ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Render

func render(variant: String, size: CGFloat) -> CGImage {
    let px = Int(size)
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    let k = size / CANVAS
    ctx.scaleBy(x: k, y: k)

    _ = drawBase(ctx)
    switch variant {
    case "A": drawArcBridge(ctx)
    case "B": drawInterlock(ctx)
    case "C": drawHandoff(ctx)
    default: fatalError("unknown variant \(variant)")
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("cannot create \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("cannot write \(path)\n".data(using: .utf8)!)
        exit(1)
    }
}

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: render_icon.swift <preview|iconset> <variant> <outdir>\n".data(using: .utf8)!)
    exit(2)
}
let mode = args[1], variant = args[2], outDir = args[3]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

if mode == "preview" {
    for v in ["A", "B", "C"] {
        writePNG(render(variant: v, size: 512), to: "\(outDir)/preview-\(v).png")
        // 32pt is the size Launchpad search and the Finder list view use; it is
        // where a too-detailed glyph falls apart.
        writePNG(render(variant: v, size: 32), to: "\(outDir)/preview-\(v)-32.png")
    }
    print("wrote previews to \(outDir)")
} else {
    // iconutil requires exactly these names.
    let spec: [(String, CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, size) in spec {
        writePNG(render(variant: variant, size: size), to: "\(outDir)/\(name).png")
    }
    print("wrote iconset \(variant) to \(outDir)")
}
