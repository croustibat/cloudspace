#!/usr/bin/env swift
// Draws Major Tom's app icon with CoreGraphics — no image tools, no downloads. Tweak the numbers and re-run.
//
//   swift scripts/make-icon.swift --previews design/icon-candidates   # 512 px PNG of each candidate + a size sheet
//   swift scripts/make-icon.swift --iconset build/AppIcon.iconset [--candidate a|b|c]   # input for `iconutil -c icns`
//
// Candidates (all on the macOS rounded-square grid: 824 px shape on a 1024 px canvas):
//   a  "Orbit"       — night-blue tile, a pale planet with a tilted orbit; the bright part of the orbit is a gauge.
//   b  "Gauge"       — light tile, a small ringed planet inside a thick round disk-usage gauge.
//   c  "Phase"       — dusk tile, a planet whose lit crescent is the gauge, one thin orbit with a satellite.
//   d  "Cloud"       — sky-blue tile, a white cloud with an upload arrow (the CloudSpace fork's icon).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The candidate wired into the app (scripts/bundle.sh).
let chosenCandidate = "d"

// MARK: - Helpers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// macOS app-icon shape: a superellipse ("squircle") close to Apple's continuous-corner rounded square.
func squircle(_ rect: CGRect, exponent n: CGFloat = 5.2) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Draws the tile (shadow + clipped background) and runs `content` clipped to it. Units are 1024-canvas units.
func tile(_ ctx: CGContext, background: (CGContext, CGRect) -> Void, content: (CGContext) -> Void) {
    let shape = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = squircle(shape)
    ctx.saveGState()
    // Shadow geometry is in device pixels (the CTM doesn't scale it), so scale it by hand.
    let k = ctx.ctm.a
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: rgb(0x000000, 0.30))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    background(ctx, shape)
    content(ctx)
    // A hairline inner edge so the tile holds its shape on any background.
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()
}

func sphere(_ ctx: CGContext, center: CGPoint, radius r: CGFloat, light: UInt32, mid: UInt32, dark: UInt32) {
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(light), rgb(mid), rgb(dark)], [0, 0.55, 1]),
                           startCenter: CGPoint(x: center.x - r * 0.35, y: center.y + r * 0.4), startRadius: 0,
                           endCenter: center, endRadius: r * 1.05, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

/// An arc along an ellipse (center, radii, rotation), from angle a0 to a1 (radians, counter-clockwise).
func ellipseArc(center: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, from a0: CGFloat, to a1: CGFloat) -> CGPath {
    let t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation).scaledBy(x: 1, y: ry / rx)
    let path = CGMutablePath()
    path.addArc(center: .zero, radius: rx, startAngle: a0, endAngle: a1, clockwise: false, transform: t)
    return path
}

func ellipsePoint(center: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, angle: CGFloat) -> CGPoint {
    let p = CGPoint(x: rx * cos(angle), y: ry * sin(angle))
    return CGPoint(x: center.x + p.x * cos(rotation) - p.y * sin(rotation),
                   y: center.y + p.x * sin(rotation) + p.y * cos(rotation))
}

func stroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat, color: CGColor, cap: CGLineCap = .round) {
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineCap(cap)
    ctx.setStrokeColor(color)
    ctx.strokePath()
}

func dot(_ ctx: CGContext, _ p: CGPoint, _ r: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
}

// MARK: - Candidates
// `small` is true at 16/32 px: strokes get heavier and faint details are dropped so the shape still reads.

/// a — Orbit: night tile, pale planet, tilted orbit whose bright arc is the gauge, a satellite at its tip.
func drawOrbit(_ ctx: CGContext, small: Bool) {
    tile(ctx, background: { ctx, r in
        ctx.drawLinearGradient(gradient([rgb(0x24386E), rgb(0x0E1836)]), start: CGPoint(x: 0, y: r.maxY),
                               end: CGPoint(x: 0, y: r.minY), options: [])
        ctx.drawRadialGradient(gradient([rgb(0x5B7BD6, 0.35), rgb(0x5B7BD6, 0)]), startCenter: CGPoint(x: 512, y: 560),
                               startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: [])
    }, content: { ctx in
        let c = CGPoint(x: 512, y: 500)
        let rx: CGFloat = 318, ry: CGFloat = 112, rot: CGFloat = 0.36
        let w: CGFloat = small ? 46 : 30
        let lit = rgb(0x7FE7D8), faint = rgb(0xFFFFFF, 0.16)
        // The orbit's upper half (0…π) is the far side, behind the planet; the lower half (π…2π) passes in front.
        // The gauge runs from the left, round the front, to the right-hand tip where the satellite sits (~60%).
        let gaugeStart: CGFloat = .pi * 0.88, gaugeEnd: CGFloat = 2 * .pi + 0.12
        func arc(_ a0: CGFloat, _ a1: CGFloat) -> CGPath { ellipseArc(center: c, rx: rx, ry: ry, rotation: rot, from: a0, to: a1) }
        if !small { stroke(ctx, arc(0, .pi), width: w, color: faint) }
        stroke(ctx, arc(gaugeStart, .pi), width: w, color: lit, cap: .round)
        stroke(ctx, arc(0, gaugeEnd - 2 * .pi), width: w, color: lit, cap: .butt)
        sphere(ctx, center: c, radius: small ? 186 : 172, light: 0xFFF8EC, mid: 0xD9D3E6, dark: 0x8C8FB8)
        stroke(ctx, arc(.pi, 2 * .pi), width: w, color: lit, cap: .butt)
        let tip = ellipsePoint(center: c, rx: rx, ry: ry, rotation: rot, angle: gaugeEnd)
        dot(ctx, tip, small ? 42 : 32, rgb(0xFFFFFF))
    })
}

/// b — Gauge: light tile, thick round gauge around a small ringed planet.
func drawGauge(_ ctx: CGContext, small: Bool) {
    tile(ctx, background: { ctx, r in
        ctx.drawLinearGradient(gradient([rgb(0xFBFCFE), rgb(0xDDE3EE)]), start: CGPoint(x: 0, y: r.maxY),
                               end: CGPoint(x: 0, y: r.minY), options: [])
    }, content: { ctx in
        let c = CGPoint(x: 512, y: 512)
        let radius: CGFloat = 292, w: CGFloat = small ? 92 : 70
        let track = CGMutablePath()
        track.addArc(center: c, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        stroke(ctx, track, width: w, color: rgb(0x1E2A4A, 0.10))
        // Progress: from 12 o'clock clockwise, 72%.
        let start: CGFloat = .pi / 2, end: CGFloat = .pi / 2 - 2 * .pi * 0.72
        let arc = CGMutablePath()
        arc.addArc(center: c, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        ctx.saveGState()
        ctx.addPath(arc)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0x3D7BF2), rgb(0x2EC5B6)]), start: CGPoint(x: 220, y: 820),
                               end: CGPoint(x: 820, y: 220), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
        // Planet with a thin ring.
        let pr: CGFloat = small ? 150 : 128
        let rot: CGFloat = 0.42
        if !small { stroke(ctx, ellipseArc(center: c, rx: 205, ry: 58, rotation: rot, from: 0, to: .pi), width: 16, color: rgb(0x1E2A4A, 0.55)) }
        sphere(ctx, center: c, radius: pr, light: 0x5D74B8, mid: 0x2B3A6E, dark: 0x141C3A)
        if !small { stroke(ctx, ellipseArc(center: c, rx: 205, ry: 58, rotation: rot, from: .pi, to: 2 * .pi), width: 16, color: rgb(0x1E2A4A, 0.85)) }
    })
}

/// c — Phase: dusk tile, a planet whose lit crescent is the gauge, one thin orbit and a satellite.
func drawPhase(_ ctx: CGContext, small: Bool) {
    tile(ctx, background: { ctx, r in
        ctx.drawLinearGradient(gradient([rgb(0x3A3170), rgb(0x141233)]), start: CGPoint(x: 0, y: r.maxY),
                               end: CGPoint(x: 0, y: r.minY), options: [])
        if !small {
            for (x, y, s) in [(250.0, 770.0, 7.0), (770.0, 300.0, 6.0), (690.0, 800.0, 5.0)] {
                dot(ctx, CGPoint(x: x, y: y), s, rgb(0xFFFFFF, 0.55))
            }
        }
    }, content: { ctx in
        let c = CGPoint(x: 500, y: 500), r: CGFloat = small ? 250 : 230
        // Dark side.
        sphere(ctx, center: c, radius: r, light: 0x3B3F78, mid: 0x262A58, dark: 0x171A3C)
        // Lit crescent: the planet minus an offset disc.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.clip()
        let lit = CGMutablePath()
        lit.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        lit.addEllipse(in: CGRect(x: c.x - r + r * 0.62, y: c.y - r - r * 0.18, width: 2 * r, height: 2 * r))
        ctx.addPath(lit)
        ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(gradient([rgb(0xFFF3D6), rgb(0xF2B880)]), start: CGPoint(x: c.x - r, y: c.y + r),
                               end: CGPoint(x: c.x, y: c.y - r), options: [])
        ctx.restoreGState()
        // Orbit + satellite.
        let orbit = CGMutablePath()
        orbit.addArc(center: c, radius: r + (small ? 90 : 78), startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        stroke(ctx, orbit, width: small ? 22 : 10, color: rgb(0xFFFFFF, small ? 0.5 : 0.35))
        let a: CGFloat = .pi * 0.25
        dot(ctx, CGPoint(x: c.x + (r + (small ? 90 : 78)) * cos(a), y: c.y + (r + (small ? 90 : 78)) * sin(a)), small ? 42 : 28, rgb(0xFFFFFF))
    })
}

/// d — Cloud: sky tile, a white cloud, an arrow going up into it (offload to iCloud Drive).
func drawCloud(_ ctx: CGContext, small: Bool) {
    tile(ctx, background: { ctx, r in
        ctx.drawLinearGradient(gradient([rgb(0x5CC4FF), rgb(0x2460E0)]), start: CGPoint(x: 0, y: r.maxY),
                               end: CGPoint(x: 0, y: r.minY), options: [])
        ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.30), rgb(0xFFFFFF, 0)]), startCenter: CGPoint(x: 380, y: 760),
                               startRadius: 0, endCenter: CGPoint(x: 380, y: 760), endRadius: 460, options: [])
    }, content: { ctx in
        let cloud = CGMutablePath()
        cloud.addRoundedRect(in: CGRect(x: 232, y: 330, width: 560, height: 210), cornerWidth: 105, cornerHeight: 105)
        cloud.addEllipse(in: CGRect(x: 290, y: 400, width: 250, height: 250))
        cloud.addEllipse(in: CGRect(x: 420, y: 410, width: 320, height: 320))
        // Soft shadow under the cloud, then the cloud itself with a faint top-to-bottom shade.
        ctx.saveGState()
        let k = ctx.ctm.a
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 30 * k, color: rgb(0x0B2A7A, 0.35))
        ctx.addPath(cloud)
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillPath(using: .winding)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(cloud)
        ctx.clip(using: .winding)
        ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0xDCEBFF)]), start: CGPoint(x: 0, y: 730),
                               end: CGPoint(x: 0, y: 330), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
        // Upload arrow.
        let w: CGFloat = small ? 64 : 46
        let ink = rgb(0x2460E0)
        let tip = CGPoint(x: 512, y: 590), head: CGFloat = small ? 96 : 84
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: 512, y: 388))
        arrow.addLine(to: tip)
        arrow.move(to: CGPoint(x: tip.x - head, y: tip.y - head))
        arrow.addLine(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x + head, y: tip.y - head))
        ctx.setLineJoin(.round)
        stroke(ctx, arrow, width: w, color: ink)
    })
}

let candidates: [String: (CGContext, Bool) -> Void] = ["a": drawOrbit, "b": drawGauge, "c": drawPhase, "d": drawCloud]

// MARK: - Rendering

func render(_ name: String, pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    candidates[name]!(ctx, pixels <= 32)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "can't write \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "can't write \(url.path)"])
    }
}

/// One strip per candidate at 16, 32, 64, 128 and 256 px on a light and a dark band — for judging small sizes.
func sizeSheet() -> CGImage {
    let sizes = [16, 32, 64, 128, 256]
    let rowHeight = 300, width = 40 + sizes.reduce(0) { $0 + $1 + 40 }
    let names = candidates.keys.sorted()
    let ctx = CGContext(data: nil, width: width, height: rowHeight * names.count * 2, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for (i, name) in names.enumerated() {
        for (j, bg) in [rgb(0xF2F2F5), rgb(0x1E1E22)].enumerated() {
            let y = (names.count * 2 - 1 - (i * 2 + j)) * rowHeight
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: rowHeight))
            var x = 40
            for s in sizes {
                ctx.draw(render(name, pixels: s), in: CGRect(x: x, y: y + (rowHeight - s) / 2, width: s, height: s))
                x += s + 40
            }
        }
    }
    return ctx.makeImage()!
}

// MARK: - Main

let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

do {
    if let dir = value("--previews") {
        let folder = URL(filePath: dir, directoryHint: .isDirectory)
        for name in candidates.keys.sorted() {
            try writePNG(render(name, pixels: 512), to: folder.appending(path: "\(name)-512.png"))
        }
        if let sheet = value("--sheet") { try writePNG(sizeSheet(), to: URL(filePath: sheet)) }
        print("Wrote previews to \(folder.path)")
    } else if let dir = value("--iconset") {
        let name = value("--candidate") ?? chosenCandidate
        guard candidates[name] != nil else { throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "unknown candidate \(name)"]) }
        let folder = URL(filePath: dir, directoryHint: .isDirectory)
        for base in [16, 32, 128, 256, 512] {
            try writePNG(render(name, pixels: base), to: folder.appending(path: "icon_\(base)x\(base).png"))
            try writePNG(render(name, pixels: base * 2), to: folder.appending(path: "icon_\(base)x\(base)@2x.png"))
        }
        print("Wrote \(folder.path) (candidate \(name))")
    } else {
        print("usage: swift scripts/make-icon.swift --previews <dir> [--sheet <png>] | --iconset <dir> [--candidate a|b|c|d]")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
