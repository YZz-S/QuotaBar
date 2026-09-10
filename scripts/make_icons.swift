// 生成 macOS 应用图标候选：swift scripts/make_icons.swift <输出目录>
// 1024×1024，macOS 图标模板：824×824 圆角方（半径 185）居中 + 柔和投影。
import Foundation
import CoreGraphics
import ImageIO

let size: CGFloat = 1024
let squareSize: CGFloat = 824
let inset = (size - squareSize) / 2
let radius: CGFloat = 185

struct RGB {
    var r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    func cg(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    func mix(_ other: RGB, _ t: CGFloat) -> RGB {
        var out = self
        out.r = r + (other.r - r) * t
        out.g = g + (other.g - g) * t
        out.b = b + (other.b - b) * t
        return out
    }
}

let orange = RGB(0xF97316), blue = RGB(0x3B82F6), purple = RGB(0xA855F7)
let green = RGB(0x22C55E), amber = RGB(0xF59E0B), red = RGB(0xEF4444)

func makeContext() -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    return CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func squarePath() -> CGPath {
    CGPath(roundedRect: CGRect(x: inset, y: inset, width: squareSize, height: squareSize),
           cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// 背景：投影 + 圆角方 + 线性渐变（top → bottom）
func drawBase(_ ctx: CGContext, top: RGB, bottom: RGB, diagonal: Bool = false) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.setFillColor(bottom.cg())
    ctx.addPath(squarePath())
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squarePath())
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [top.cg(), bottom.cg()] as CFArray, locations: [0, 1])!
    let start = diagonal ? CGPoint(x: inset, y: size - inset) : CGPoint(x: size / 2, y: size - inset)
    let end = diagonal ? CGPoint(x: size - inset, y: inset) : CGPoint(x: size / 2, y: inset)
    ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
    ctx.restoreGState()
}

/// 弧线（角度为数学坐标，逆时针为正）
func strokeArc(_ ctx: CGContext, center: CGPoint, radius: CGFloat, from: CGFloat, to: CGFloat,
               width: CGFloat, color: CGColor, round: Bool = true) {
    ctx.saveGState()
    ctx.setLineWidth(width)
    ctx.setLineCap(round ? .round : .butt)
    ctx.setStrokeColor(color)
    ctx.addArc(center: center, radius: radius, startAngle: from * .pi / 180, endAngle: to * .pi / 180, clockwise: from > to)
    ctx.strokePath()
    ctx.restoreGState()
}

/// 分段渐变弧：从 fromDeg 顺时针扫过 sweep 度，颜色 green → amber → red
func gradientArc(_ ctx: CGContext, center: CGPoint, radius: CGFloat, fromDeg: CGFloat, sweep: CGFloat, width: CGFloat) {
    let steps = 90
    for i in 0..<steps {
        let t0 = CGFloat(i) / CGFloat(steps), t1 = CGFloat(i + 1) / CGFloat(steps)
        let t = (t0 + t1) / 2
        let color = t < 0.5 ? green.mix(amber, t * 2) : amber.mix(red, (t - 0.5) * 2)
        let a0 = fromDeg - sweep * t0, a1 = fromDeg - sweep * t1 - 0.6
        strokeArc(ctx, center: center, radius: radius, from: a0, to: a1, width: width, color: color.cg(), round: false)
    }
    // 两端圆头
    let endA = fromDeg - sweep
    for angle in [fromDeg, endA] {
        let p = CGPoint(x: center.x + radius * cos(angle * .pi / 180), y: center.y + radius * sin(angle * .pi / 180))
        let color = angle == fromDeg ? green : red
        ctx.setFillColor(color.cg())
        ctx.fillEllipse(in: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width))
    }
}

func dots(_ ctx: CGContext, y: CGFloat, spacing: CGFloat, diameter: CGFloat, alpha: CGFloat = 1) {
    let colors = [orange, blue, purple]
    let startX = size / 2 - spacing
    for (i, color) in colors.enumerated() {
        let x = startX + CGFloat(i) * spacing
        ctx.setFillColor(color.cg(alpha))
        ctx.fillEllipse(in: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
    }
}

func roundedBar(_ ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, color: CGColor) {
    let path = CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
                      cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
    ctx.setFillColor(color)
    ctx.addPath(path)
    ctx.fillPath()
}

func save(_ ctx: CGContext, to url: URL) {
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - 四个候选

/// A 深空仪表盘：深色渐变 + 270° 绿→红渐变仪表弧（83%）+ 三色品牌点
func variantA(_ ctx: CGContext) {
    drawBase(ctx, top: RGB(0x2C3A5C), bottom: RGB(0x0F1526))
    let center = CGPoint(x: size / 2, y: size / 2 + 30)
    strokeArc(ctx, center: center, radius: 250, from: 225, to: -45, width: 72,
              color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
    gradientArc(ctx, center: center, radius: 250, fromDeg: 225, sweep: 270 * 0.83, width: 72)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
    ctx.fillEllipse(in: CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52))
    dots(ctx, y: 235, spacing: 96, diameter: 54)
}

/// B 浅色极简：浅灰渐变 + 同款仪表弧 + 品牌点
func variantB(_ ctx: CGContext) {
    drawBase(ctx, top: RGB(0xFFFFFF), bottom: RGB(0xE6EAF2))
    let center = CGPoint(x: size / 2, y: size / 2 + 30)
    strokeArc(ctx, center: center, radius: 250, from: 225, to: -45, width: 72, color: RGB(0x1F2937).cg(0.10))
    gradientArc(ctx, center: center, radius: 250, fromDeg: 225, sweep: 270 * 0.83, width: 72)
    ctx.setFillColor(RGB(0x1F2937).cg(0.85))
    ctx.fillEllipse(in: CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52))
    dots(ctx, y: 235, spacing: 96, diameter: 54)
}

/// C 三色用量条：深色 + 三根品牌色进度条（火山 83% / 智谱 40% / DeepSeek 余额 60%）
func variantC(_ ctx: CGContext) {
    drawBase(ctx, top: RGB(0x1E293B), bottom: RGB(0x0B1120))
    let barX: CGFloat = 200, barW: CGFloat = 624, barH: CGFloat = 96
    let rows: [(RGB, CGFloat, CGFloat)] = [(orange, 0.83, 668), (blue, 0.40, 464), (purple, 0.60, 260)]
    for (color, fraction, y) in rows {
        roundedBar(ctx, x: barX, y: y, width: barW, height: barH, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
        roundedBar(ctx, x: barX, y: y, width: max(barH, barW * fraction), height: barH, color: color.cg())
    }
}

/// D 蓝紫渐变 + 白色环：对角渐变，细白环 83% + 中心点，最简
func variantD(_ ctx: CGContext) {
    drawBase(ctx, top: RGB(0x2563EB), bottom: RGB(0x9333EA), diagonal: true)
    let center = CGPoint(x: size / 2, y: size / 2)
    strokeArc(ctx, center: center, radius: 262, from: 90, to: 90 - 360, width: 64,
              color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
    strokeArc(ctx, center: center, radius: 262, from: 90, to: 90 - 360 * 0.83, width: 64,
              color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - 70, y: center.y - 70, width: 140, height: 140))
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "icons")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let variants: [(String, (CGContext) -> Void)] = [
    ("A-深空仪表盘", variantA), ("B-浅色极简", variantB), ("C-三色用量条", variantC), ("D-蓝紫白环", variantD),
]
for (name, draw) in variants {
    let ctx = makeContext()
    draw(ctx)
    let url = outDir.appendingPathComponent("\(name).png")
    save(ctx, to: url)
    print("wrote \(url.path)")
}
