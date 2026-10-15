// 生成 App 图标（Porthole 风格）：
//   swift tools/make-icon.swift Support/AppIcon-1024.png
// 然后用 sips + iconutil 生成 Support/AppIcon.icns。
import AppKit
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let N = 1024
let ctx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// macOS 图标网格：824 的圆角方块居中
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(squircle); ctx.setFillColor(c(0x000000)); ctx.fillPath()
// 细边，让黑色图标在深色 Dock 上也有轮廓
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
ctx.setStrokeColor(c(0x2E3036)); ctx.setLineWidth(6); ctx.strokePath()

let center = CGPoint(x: 512, y: 512)
func arc(_ r: CGFloat, _ w: CGFloat, _ color: CGColor, from: CGFloat, to: CGFloat) {
    // 角度：0 = 正上方，顺时针
    ctx.setStrokeColor(color); ctx.setLineWidth(w); ctx.setLineCap(.round)
    let a0 = CGFloat.pi / 2 - from * .pi / 180, a1 = CGFloat.pi / 2 - to * .pi / 180
    ctx.addArc(center: center, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
    ctx.strokePath()
}
func dot(_ r: CGFloat, at deg: CGFloat, size: CGFloat, _ color: CGColor) {
    let a = CGFloat.pi / 2 - deg * .pi / 180
    let p = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    ctx.setFillColor(color); ctx.fillEllipse(in: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
}
// 外圈：灰色轨道 + 赭橙进度（Porthole 表盘圆环）
ctx.setStrokeColor(c(0x2E3036)); ctx.setLineWidth(46)
ctx.addEllipse(in: CGRect(x: center.x - 300, y: center.y - 300, width: 600, height: 600)); ctx.strokePath()
arc(300, 46, c(0xE07A47), from: 0, to: 250)
// 进度条头上的光点（光带）
dot(300, at: 250, size: 18, c(0xFFF6E6, 0.9))
// 内圈：石板蓝
ctx.setStrokeColor(c(0x59718A)); ctx.setLineWidth(20)
ctx.addEllipse(in: CGRect(x: center.x - 222, y: center.y - 222, width: 444, height: 444)); ctx.strokePath()
// 内圈上的芥末黄小点（轨道表盘的指针点）
dot(222, at: 128, size: 44, c(0xD4A72C))

// 中间：奶油色音符
let config = NSImage.SymbolConfiguration(pointSize: 230, weight: .heavy)
let sym = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
var rect = CGRect(origin: .zero, size: sym.size)
let cg = sym.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let w = CGFloat(cg.width), h = CGFloat(cg.height), scale = 250 / max(w, h)
let noteRect = CGRect(x: center.x - w * scale / 2 - 6, y: center.y - h * scale / 2, width: w * scale, height: h * scale)
ctx.saveGState()
ctx.clip(to: noteRect, mask: cg)
ctx.setFillColor(c(0xF2E9D8)); ctx.fill(noteRect)
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
