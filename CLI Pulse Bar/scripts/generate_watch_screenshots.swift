#!/usr/bin/env swift
// Generate Apple Watch App Store screenshots for the redesigned watchOS app.
//
// Renders the four glance pages of the "vital-signs monitor" redesign —
// Pulse, Quota, Live, Alerts — as a standalone AppKit mock (this script
// runs locally with `swift`; the watch app target itself is CI-only). It
// mirrors the in-app design (true-black canvas, ECG pulse, concentric
// quota rings, provider-coloured cards) closely enough for the store.
//
// Canvas: 422×514 — the Apple Watch Ultra (49 mm) App Store size, matching
// the committed screenshots/watch/*.png. (The pre-redesign version of this
// script hardcoded 368×448, which no longer matched the assets.)

import AppKit

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let outputDir = scriptDir.deletingLastPathComponent().appendingPathComponent("screenshots/watch")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func savePNG(_ rep: NSBitmapImageRep, to name: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("Failed to encode \(name)"); return
    }
    let url = outputDir.appendingPathComponent(name)
    try! data.write(to: url)
    print("Created: \(url.lastPathComponent) (\(Int(rep.pixelsWide))x\(Int(rep.pixelsHigh)))")
}

// MARK: - Canvas + palette

let W: CGFloat = 422
let H: CGFloat = 514

let bg = NSColor.black
let accent = NSColor(red: 0.36, green: 0.51, blue: 1.0, alpha: 1)     // #5C82FF
let glow = NSColor(red: 0.48, green: 0.63, blue: 1.0, alpha: 1)       // #7BA0FF
let green = NSColor(red: 0.20, green: 0.82, blue: 0.35, alpha: 1)     // #34D058
let amber = NSColor(red: 0.94, green: 0.69, blue: 0.23, alpha: 1)     // #EFAF3B
let cyan = NSColor(red: 0.25, green: 0.78, blue: 0.83, alpha: 1)      // #3FC7D4
let red = NSColor(red: 0.89, green: 0.29, blue: 0.29, alpha: 1)       // #E24B4A
let claude = NSColor(red: 0.90, green: 0.55, blue: 0.20, alpha: 1)    // #E68C33
let codex = accent
let gemini = NSColor(red: 0.58, green: 0.39, blue: 0.98, alpha: 1)    // #9463FA
let cardFill = NSColor(white: 1.0, alpha: 0.06)
let cardFillStrong = NSColor(white: 1.0, alpha: 0.09)
let dim = NSColor(white: 1.0, alpha: 0.5)
let dim2 = NSColor(white: 1.0, alpha: 0.35)

// MARK: - Drawing helpers (AppKit y-up)

func newRep() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    bg.setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()
    return rep
}
func endRep() { NSGraphicsContext.restoreGraphicsState() }

enum TextW { case regular, semibold, bold }
func font(_ size: CGFloat, _ w: TextW, mono: Bool) -> NSFont {
    let wt: NSFont.Weight = w == .bold ? .bold : (w == .semibold ? .semibold : .regular)
    return mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: wt)
                : NSFont.systemFont(ofSize: size, weight: wt)
}
/// Draw left-aligned text with its baseline at `point`.
func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
          _ color: NSColor = .white, _ w: TextW = .regular, mono: Bool = false) {
    (s as NSString).draw(at: NSPoint(x: x, y: y),
        withAttributes: [.font: font(size, w, mono: mono), .foregroundColor: color])
}
/// Draw text right-aligned so it ends at `xRight`.
func textRight(_ s: String, _ xRight: CGFloat, _ y: CGFloat, _ size: CGFloat,
               _ color: NSColor = .white, _ w: TextW = .regular, mono: Bool = false) {
    let f = font(size, w, mono: mono)
    let width = (s as NSString).size(withAttributes: [.font: f]).width
    (s as NSString).draw(at: NSPoint(x: xRight - width, y: y),
        withAttributes: [.font: f, .foregroundColor: color])
}
func roundRect(_ r: NSRect, _ radius: CGFloat, _ fill: NSColor) {
    let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius); fill.setFill(); p.fill()
}
func circle(_ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat, _ fillColor: NSColor) {
    fillColor.setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2)).fill()
}

/// Consumption arc from 12 o'clock, clockwise, `pct` of the circle.
func ring(_ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat, _ lw: CGFloat, _ pct: Double, _ color: NSColor) {
    let track = NSBezierPath(); track.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: rad, startAngle: 0, endAngle: 360)
    track.lineWidth = lw; color.withAlphaComponent(0.18).setStroke(); track.stroke()
    guard pct > 0 else { return }
    let p = NSBezierPath()
    p.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: rad,
                startAngle: 90, endAngle: 90 - 360 * CGFloat(pct), clockwise: true)
    p.lineWidth = lw; p.lineCapStyle = .round; color.setStroke(); p.stroke()
}

/// ECG polyline across [x0,x1] centred on baseline y, amplitude `amp` px.
func ecgPath(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat, _ amp: CGFloat) -> NSBezierPath {
    let w = x1 - x0
    let v: [(CGFloat, CGFloat)] = [(0,0),(0.2174,0),(0.2446,0),(0.2663,0.7),(0.2989,-0.7),(0.3261,0.26),(0.3478,0),(1,0)]
    let p = NSBezierPath()
    for (i, pt) in v.enumerated() {
        let point = NSPoint(x: x0 + pt.0 * w, y: y + pt.1 * amp)
        if i == 0 { p.move(to: point) } else { p.line(to: point) }
    }
    return p
}

func chip(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ icon: NSColor, _ value: String, _ valueColor: NSColor) {
    roundRect(NSRect(x: x, y: y, width: w, height: 34), 11, cardFill)
    circle(x + 16, y + 17, 4, icon)
    text(value, x + 26, y + 9, 16, valueColor, .semibold, mono: true)
}

func spark(_ x: CGFloat, _ y: CGFloat, _ color: NSColor, _ heights: [CGFloat]) {
    for (i, h) in heights.enumerated() {
        roundRect(NSRect(x: x + CGFloat(i) * 5, y: y, width: 3, height: h), 1.5, color)
    }
}

// MARK: - Page header (wordmark variant)
func topBar(_ title: String, _ titleColor: NSColor, right: String, rightColor: NSColor, mark: Bool, dotColor: NSColor?) {
    let y = H - 40
    if mark {
        // ECG glyph drawn as a tiny pulse + wordmark
        let g = ecgPath(16, 40, y + 6, 7); g.lineWidth = 2; accent.setStroke(); g.stroke()
        text(title, 44, y, 15, .white, .semibold)
    } else {
        text(title, 16, y, 15, titleColor, .semibold)
    }
    if let dotColor { circle(W - 18, y + 6, 4, dotColor) }
    textRight(right, mark ? (W - 28) : (W - 16), y, 12, rightColor)
}

// MARK: - 1. Pulse
func drawPulse() -> NSBitmapImageRep {
    let rep = newRep()
    topBar("CLI Pulse", .white, right: "9:41", rightColor: dim, mark: true, dotColor: green)

    // ECG waveform band
    let baseY = H - 110
    let dimPath = ecgPath(16, W - 16, baseY, 26); dimPath.lineWidth = 2
    accent.withAlphaComponent(0.3).setStroke(); dimPath.stroke()
    // bright flowing segment over the QRS region
    let brightPath = ecgPath(16, W - 16, baseY, 26)
    brightPath.lineWidth = 3.2; glow.setStroke()
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: 16 + (W - 32) * 0.18, y: baseY - 40, width: (W - 32) * 0.30, height: 80)).addClip()
    brightPath.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Hero
    text("$146.03", 16, H - 195, 42, green, .semibold, mono: true)
    text("Today · 1.5M tokens", 16, H - 215, 13, dim)

    // Stat chips
    let chipY: CGFloat = 70
    let cw = (W - 32 - 16) / 3
    chip(16, chipY, cw, accent, "6", .white)
    chip(16 + cw + 8, chipY, cw, cyan, "5", .white)
    chip(16 + (cw + 8) * 2, chipY, cw, red, "23", red)

    endRep(); return rep
}

// MARK: - 2. Quota
func drawQuota() -> NSBitmapImageRep {
    let rep = newRep()
    topBar("Quota", .white, right: "3 active", rightColor: dim2, mark: false, dotColor: nil)

    let cx = W / 2, cy = H - 175
    let lw: CGFloat = 13, step: CGFloat = 19
    ring(cx, cy, 84, lw, 0.62, claude)   // Claude 62% consumed → 38% left (most constrained)
    ring(cx, cy, 84 - step, lw, 0.42, codex)   // Codex 42% → 58%
    ring(cx, cy, 84 - step * 2, lw, 0.10, gemini) // Gemini 10% → 90%
    // centre
    let cs = "38%"; let f = font(28, .semibold, mono: true)
    let cwid = (cs as NSString).size(withAttributes: [.font: f]).width
    (cs as NSString).draw(at: NSPoint(x: cx - cwid / 2, y: cy - 4), withAttributes: [.font: f, .foregroundColor: NSColor.white])
    let sub = "Claude left"; let sf = font(11, .regular, mono: false)
    let swid = (sub as NSString).size(withAttributes: [.font: sf]).width
    (sub as NSString).draw(at: NSPoint(x: cx - swid / 2, y: cy - 24), withAttributes: [.font: sf, .foregroundColor: dim])

    // Legend
    let legend: [(String, NSColor, String)] = [("Claude", claude, "38%"), ("Codex", codex, "58%"), ("Gemini", gemini, "90%")]
    var ly: CGFloat = 92
    for (name, color, pct) in legend {
        roundRect(NSRect(x: 12, y: ly, width: W - 24, height: 30), 10, cardFill)
        circle(30, ly + 15, 5, color)
        text(name, 44, ly + 8, 13, .white)
        textRight(pct, W - 24, ly + 7, 14, .white, .semibold, mono: true)
        ly -= 36
    }
    endRep(); return rep
}

// MARK: - 3. Live
func drawLive() -> NSBitmapImageRep {
    let rep = newRep()
    let y = H - 40
    circle(20, y + 6, 4, green)
    text("Live", 32, y, 15, .white, .semibold)
    textRight("3 running", W - 16, y, 12, dim2)

    func card(_ top: CGFloat, _ color: NSColor, _ title: String, _ meta: String, _ usage: String, _ heights: [CGFloat]?, strong: Bool, alpha: CGFloat) {
        let h: CGFloat = 64
        NSGraphicsContext.current?.saveGraphicsState()
        roundRect(NSRect(x: 12, y: top - h, width: W - 24, height: h), 12, strong ? cardFillStrong : cardFill)
        roundRect(NSRect(x: 20, y: top - h + 10, width: 3, height: h - 20), 1.5, color)
        text(title, 34, top - 26, 14, NSColor.white.withAlphaComponent(alpha), .semibold)
        text(meta, 34, top - 44, 10, dim)
        if let heights { spark(34 + 130, top - 44, color, heights) }
        textRight(usage, W - 24, top - 44, 11, NSColor.white.withAlphaComponent(alpha * 0.9), .semibold, mono: true)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    card(H - 70, claude, "cli-pulse refactor", "Claude · 12m", "84.2K", [6,10,7,13,8], strong: true, alpha: 1)
    card(H - 142, codex, "api-server debug", "Codex · 8m", "41.0K", [9,6,12,7,5], strong: true, alpha: 1)
    card(H - 214, gemini, "docs generation", "Gemini · ended 5m", "12.3K", nil, strong: false, alpha: 0.6)
    endRep(); return rep
}

// MARK: - 4. Alerts
func drawAlerts() -> NSBitmapImageRep {
    let rep = newRep()
    let y = H - 40
    text("Alerts", 16, y, 15, .white, .semibold)
    roundRect(NSRect(x: W - 44, y: y - 2, width: 28, height: 20), 9, red)
    textRight("3", W - 23, y, 12, .white, .bold, mono: true)

    func card(_ top: CGFloat, _ color: NSColor, _ title: String, _ meta: String, _ time: String, critical: Bool) {
        let h: CGFloat = 60
        roundRect(NSRect(x: 12, y: top - h, width: W - 24, height: h), 12, critical ? color.withAlphaComponent(0.12) : cardFill)
        roundRect(NSRect(x: 20, y: top - h + 10, width: 3, height: h - 20), 1.5, color)
        if critical { circle(36, top - 18, 4, color) }
        text(title, critical ? 46 : 34, top - 24, 13, .white, .semibold)
        text(meta, 34, top - 42, 10, dim)
        textRight(time, W - 22, top - 24, 10, dim2)
    }
    card(H - 70, red, "Quota low: Claude", "exceeded 90% · 2m ago", "2m", critical: true)
    card(H - 142, amber, "Usage spike detected", "Codex 3× · 15m ago", "15m", critical: false)
    card(H - 214, cyan, "Helper reconnected", "all services · 1m ago", "1m", critical: false)
    endRep(); return rep
}

// MARK: - Run
print("Generating watchOS redesign screenshots → \(outputDir.path)")
savePNG(drawPulse(), to: "01_pulse.png")
savePNG(drawQuota(), to: "02_quota.png")
savePNG(drawLive(), to: "03_live.png")
savePNG(drawAlerts(), to: "04_alerts.png")
print("Done.")
