// 生成 App 图标（贴近 Apple Music 图标的风格，外圈一条进度环）：
//   swift tools/make-icon.swift Support/AppIcon-1024.png            深色版（黑底，打包进 .icns）
//   swift tools/make-icon.swift Support/AppIcon-light.png --light   浅色版（白底，App 选浅色时用作程序坞图标）
// 然后用 sips + iconutil 生成 Support/AppIcon.icns。
import AppKit
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let N = 1024
let light = CommandLine.arguments.contains("--light")
// 风格贴近 macOS 的 Apple Music 图标：柔和的渐变圆角方块 + 居中的大号粗音符，
// 外面留一圈进度环，颜色和音符一样作为 Groove 的标志。
//                 深色版     浅色版
let topColor    = light ? 0xFFFFFF : 0x2C2D32   // 底色渐变：上
let bottomColor = light ? 0xE4E4E8 : 0x050506   // 底色渐变：下
let edgeColor   = light ? 0xD9D9DE : 0x3A3C42
let trackColor  = light ? 0xE2E0DC : 0x2A2C31
let noteColor   = light ? 0x111114 : 0xF2E9D8
let ctx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// macOS 图标网格：824 的圆角方块居中，带一点投影
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: c(0x000000, 0.28))
ctx.addPath(squircle); ctx.setFillColor(c(UInt32(bottomColor))); ctx.fillPath()
ctx.restoreGState()
// 底色：从上到下的柔和渐变
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c(UInt32(topColor)), c(UInt32(bottomColor))] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
// 上半部分一层很淡的高光，显得有一点光泽
let gloss = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c(0xFFFFFF, light ? 0.6 : 0.10), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.midY), options: [])
ctx.restoreGState()
// 细边，让图标在同色的 Dock 上也有轮廓
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
ctx.setStrokeColor(c(UInt32(edgeColor), 0.8)); ctx.setLineWidth(4); ctx.strokePath()

let center = CGPoint(x: 512, y: 512)
// 外圈：淡淡的轨道 + 和音符同色的进度环
let ringR: CGFloat = 330, ringW: CGFloat = 30
ctx.setStrokeColor(c(UInt32(trackColor))); ctx.setLineWidth(ringW)
ctx.addEllipse(in: CGRect(x: center.x - ringR, y: center.y - ringR, width: 2 * ringR, height: 2 * ringR)); ctx.strokePath()
// 角度：0 = 正上方，顺时针
ctx.setStrokeColor(c(UInt32(noteColor))); ctx.setLineWidth(ringW); ctx.setLineCap(.round)
ctx.addArc(center: center, radius: ringR, startAngle: .pi / 2, endAngle: .pi / 2 - 250 * .pi / 180, clockwise: true)
ctx.strokePath()
// 进度环两头外面各一个小圆点，隔开一点，看起来是单独的点
let dotSize = ringW * 1.6
let dotOffset = (ringW / 2 + ringW * 0.6 + dotSize / 2) / ringR * 180 / .pi   // 圆点离进度环端点的角度
for deg in [-dotOffset, 250 + dotOffset] {
    let a = CGFloat.pi / 2 - deg * .pi / 180
    let p = CGPoint(x: center.x + ringR * cos(a), y: center.y + ringR * sin(a))
    ctx.setFillColor(c(UInt32(noteColor)))
    ctx.fillEllipse(in: CGRect(x: p.x - dotSize / 2, y: p.y - dotSize / 2, width: dotSize, height: dotSize))
}

// 中间：大号粗音符，带一点柔和的阴影
let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .black)
let sym = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
var rect = CGRect(origin: .zero, size: sym.size)
let cg = sym.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let w = CGFloat(cg.width), h = CGFloat(cg.height), scale = 470 / max(w, h)
let noteRect = CGRect(x: center.x - w * scale / 2 - 12, y: center.y - h * scale / 2, width: w * scale, height: h * scale)
let noteLayer = CGLayer(ctx, size: CGSize(width: N, height: N), auxiliaryInfo: nil)!
let nctx = noteLayer.context!
nctx.clip(to: noteRect, mask: cg)
nctx.setFillColor(c(UInt32(noteColor))); nctx.fill(noteRect)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: c(0x000000, light ? 0.22 : 0.5))
ctx.draw(noteLayer, at: .zero)
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
