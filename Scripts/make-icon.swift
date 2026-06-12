#!/usr/bin/swift
// 程序化生成 Hunk 应用图标：深色编辑器方块 + diff 行条（红删绿增）。
// 用法：swift Scripts/make-icon.swift <输出 1024px PNG 路径>
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let canvas: CGFloat = 1024

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// ── 大苏尔式留白方圆形（824×824 居中）─────────────────────────────
let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 186, yRadius: 186)

// 底部柔和投影
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).setFill()
tile.fill()
NSGraphicsContext.current?.restoreGraphicsState()

// 编辑器底：深色纵向渐变
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.165, green: 0.180, blue: 0.220, alpha: 1),
    NSColor(calibratedRed: 0.090, green: 0.098, blue: 0.125, alpha: 1),
])!
gradient.draw(in: tile, angle: -90)

// 顶部微高光
let highlight = NSBezierPath(roundedRect: tileRect.insetBy(dx: 3, dy: 3), xRadius: 183, yRadius: 183)
NSColor.white.withAlphaComponent(0.06).setStroke()
highlight.lineWidth = 6
highlight.stroke()

// ── 左侧强调条（选中行高亮的意象）────────────────────────────────
tile.setClip()
NSColor(calibratedRed: 0.35, green: 0.55, blue: 1.0, alpha: 0.9).setFill()
NSRect(x: tileRect.minX, y: tileRect.minY, width: 26, height: tileRect.height).fill()

// ── diff 行条 ────────────────────────────────────────────────────
struct Line {
    let widthRatio: CGFloat
    let color: NSColor
    let glyph: String?  // "+" / "-" / nil
}

let grey = NSColor(calibratedRed: 0.36, green: 0.40, blue: 0.48, alpha: 1)
let red = NSColor(calibratedRed: 0.92, green: 0.34, blue: 0.30, alpha: 1)
let green = NSColor(calibratedRed: 0.27, green: 0.74, blue: 0.35, alpha: 1)

let lines: [Line] = [
    Line(widthRatio: 0.62, color: grey, glyph: nil),
    Line(widthRatio: 0.44, color: grey, glyph: nil),
    Line(widthRatio: 0.55, color: red, glyph: "-"),
    Line(widthRatio: 0.74, color: green, glyph: "+"),
    Line(widthRatio: 0.50, color: green, glyph: "+"),
    Line(widthRatio: 0.40, color: grey, glyph: nil),
]

let barHeight: CGFloat = 64
let barGap: CGFloat = 36
let barLeft = tileRect.minX + 118
let maxBarWidth = tileRect.maxX - 90 - barLeft
let totalHeight = CGFloat(lines.count) * barHeight + CGFloat(lines.count - 1) * barGap
var y = tileRect.midY + totalHeight / 2 - barHeight

for line in lines {
    let rect = NSRect(x: barLeft, y: y, width: maxBarWidth * line.widthRatio, height: barHeight)
    line.color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

    // 行条左端的 +/− 记号
    if let glyph = line.glyph {
        NSColor.white.withAlphaComponent(0.92).setFill()
        let cx = rect.minX + barHeight / 2
        let cy = rect.midY
        let armLength: CGFloat = 17
        let armThickness: CGFloat = 9
        NSBezierPath(
            roundedRect: NSRect(x: cx - armLength, y: cy - armThickness / 2, width: armLength * 2, height: armThickness),
            xRadius: armThickness / 2, yRadius: armThickness / 2
        ).fill()
        if glyph == "+" {
            NSBezierPath(
                roundedRect: NSRect(x: cx - armThickness / 2, y: cy - armLength, width: armThickness, height: armLength * 2),
                xRadius: armThickness / 2, yRadius: armThickness / 2
            ).fill()
        }
    }
    y -= barHeight + barGap
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    fputs("生成 PNG 失败\n", stderr)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outputPath))
print("✅ \(outputPath)")
