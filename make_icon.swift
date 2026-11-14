import AppKit

// ============================================================
//  MacPowerTemp 图标生成器
//  画一张 1024 主图 + 完整 iconset → AppIcon.icns
//  构图：深色 squircle + 暖光 + 温度计(左) + 闪电(右)
// ============================================================

let S: CGFloat = 1024   // 主画布

// ---------- 颜色 ----------
let bgTop     = NSColor(srgbRed: 0.180, green: 0.220, blue: 0.290, alpha: 1)
let bgBottom  = NSColor(srgbRed: 0.086, green: 0.110, blue: 0.155, alpha: 1)
let glowColor = NSColor(srgbRed: 1.000, green: 0.520, blue: 0.090, alpha: 1)
let bodyWhite = NSColor(srgbRed: 0.945, green: 0.965, blue: 0.980, alpha: 1)
let mercuryA  = NSColor(srgbRed: 1.000, green: 0.760, blue: 0.280, alpha: 1)
let mercuryB  = NSColor(srgbRed: 1.000, green: 0.430, blue: 0.120, alpha: 1)
let boltA     = NSColor(srgbRed: 1.000, green: 0.820, blue: 0.320, alpha: 1)
let boltB     = NSColor(srgbRed: 1.000, green: 0.540, blue: 0.100, alpha: 1)
let tickColor = NSColor(srgbRed: 0.520, green: 0.590, blue: 0.690, alpha: 1)

// ---------- 闪电多边形（单位盒坐标，y=0 在顶） ----------
let boltPts: [CGPoint] = [
    CGPoint(x: 0.60, y: 0.00),
    CGPoint(x: 0.10, y: 0.545),
    CGPoint(x: 0.40, y: 0.545),
    CGPoint(x: 0.26, y: 1.00),
    CGPoint(x: 0.93, y: 0.385),
    CGPoint(x: 0.53, y: 0.385),
]

func boltPath(in r: CGRect) -> CGPath {
    let p = CGMutablePath()
    for (i, pt) in boltPts.enumerated() {
        let x = r.minX + pt.x * r.width
        let y = r.minY + (1.0 - pt.y) * r.height   // 翻转到 CG 坐标
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
        else      { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

// ---------- 单尺寸绘制 ----------
func drawIcon(side: CGFloat) -> NSBitmapImageRep {
    let px = Int(side)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!

    // 按像素作画，1 pt = 1 px
    rep.size = NSSize(width: side, height: side)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let c = ctx.cgContext
    c.setShouldAntialias(true)
    c.setAllowsAntialiasing(true)

    let R = CGRect(x: 0, y: 0, width: side, height: side)

    // ---- squircle 裁切（macOS 系统圆角 22.37%）----
    let corner = side * 0.2237
    let squircle = CGPath(roundedRect: R, cornerWidth: corner, cornerHeight: corner, transform: nil)
    c.addPath(squircle)
    c.clip()

    // ---- 背景渐变（左上浅 → 右下深）----
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [bgTop.cgColor, bgBottom.cgColor] as CFArray,
                        locations: [0, 1])!
    c.drawLinearGradient(bg,
                         start: CGPoint(x: 0, y: side),      // 左上
                         end:   CGPoint(x: side, y: 0),      // 右下
                         options: [])

    // ---- 底部暖光 ----
    let glowCenter = CGPoint(x: side * 0.50, y: side * 0.32)   // CG 坐标：偏下
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [glowColor.withAlphaComponent(0.30).cgColor,
                                   glowColor.withAlphaComponent(0.0).cgColor] as CFArray,
                          locations: [0, 1])!
    c.drawRadialGradient(glow,
                         startCenter: glowCenter, startRadius: 0,
                         endCenter: glowCenter, endRadius: side * 0.55,
                         options: [])

    // ============ 主体符号 ============
    // 逻辑坐标：y=0 顶 → CG y = side*(1-y)
    func Y(_ t: CGFloat) -> CGFloat { side * (1.0 - t) }
    func X(_ t: CGFloat) -> CGFloat { side * t }

    // ---------- 温度计（左侧）----------
    // 管身：圆角胶囊
    let stemW = side * 0.086
    let stemX = X(0.252)                 // 管身左缘
    let stemTop = Y(0.232)
    let stemBot = Y(0.628)
    let stemRect = CGRect(x: stemX, y: stemBot, width: stemW, height: stemTop - stemBot)

    // 球泡
    let bulbC = CGPoint(x: stemX + stemW / 2, y: Y(0.712))
    let bulbR = side * 0.101

    // 白色管身 + 球泡（带与闪电一致的柔和投影）
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -side * 0.010),
                blur: side * 0.030,
                color: NSColor.black.withAlphaComponent(0.34).cgColor)
    c.setFillColor(bodyWhite.cgColor)
    let stemPath = CGPath(roundedRect: stemRect,
                          cornerWidth: stemW / 2, cornerHeight: stemW / 2,
                          transform: nil)
    c.addPath(stemPath)
    c.fillPath()
    c.fillEllipse(in: CGRect(x: bulbC.x - bulbR, y: bulbC.y - bulbR,
                             width: bulbR * 2, height: bulbR * 2))
    c.restoreGState()

    // 琥珀液柱（管内）
    let mercW = stemW * 0.56
    let mercX = stemX + (stemW - mercW) / 2
    let mercTop = Y(0.318)
    let mercBot = Y(0.622)
    let mercRect = CGRect(x: mercX, y: mercBot, width: mercW, height: mercTop - mercBot)
    let mercGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [mercuryA.cgColor, mercuryB.cgColor] as CFArray,
                              locations: [0, 1])!
    c.saveGState()
    c.addPath(CGPath(roundedRect: mercRect,
                     cornerWidth: mercW / 2, cornerHeight: mercW / 2, transform: nil))
    c.clip()
    c.drawLinearGradient(mercGrad,
                         start: CGPoint(x: mercX, y: mercTop),
                         end:   CGPoint(x: mercX, y: mercBot),
                         options: [])
    c.restoreGState()

    // 球泡内的液珠
    let dropR = bulbR * 0.58
    c.saveGState()
    c.fillEllipse(in: CGRect(x: bulbC.x - dropR, y: bulbC.y - dropR,
                             width: dropR * 2, height: dropR * 2))
    // 用渐变盖一层
    c.addEllipse(in: CGRect(x: bulbC.x - dropR, y: bulbC.y - dropR,
                            width: dropR * 2, height: dropR * 2))
    c.clip()
    c.drawLinearGradient(mercGrad,
                         start: CGPoint(x: bulbC.x, y: bulbC.y + dropR),
                         end:   CGPoint(x: bulbC.x, y: bulbC.y - dropR),
                         options: [])
    c.restoreGState()

    // 刻度（管身左侧三条短横，明确是量程刻度）
    let tickW = side * 0.034
    let tickH = max(side * 0.014, 1.4)
    let tickGap = side * 0.010
    c.setFillColor(tickColor.cgColor)
    for i in 0..<3 {
        let ty = Y(0.355 + CGFloat(i) * 0.092)
        let tickRect = CGRect(x: stemX - tickW - tickGap, y: ty - tickH / 2,
                              width: tickW, height: tickH)
        c.addPath(CGPath(roundedRect: tickRect,
                         cornerWidth: tickH / 2, cornerHeight: tickH / 2, transform: nil))
        c.fillPath()
    }

    // 管身高光
    let hlW = stemW * 0.18
    let hlRect = CGRect(x: stemX + stemW * 0.16, y: stemBot + stemW * 0.35,
                        width: hlW, height: (stemTop - stemBot) - stemW * 0.7)
    c.setFillColor(NSColor.white.withAlphaComponent(0.32).cgColor)
    c.addPath(CGPath(roundedRect: hlRect,
                     cornerWidth: hlW / 2, cornerHeight: hlW / 2, transform: nil))
    c.fillPath()

    // ---------- 闪电（右侧）----------
    let boltRect = CGRect(x: X(0.472), y: Y(0.802),
                          width: X(0.818) - X(0.472),
                          height: Y(0.222) - Y(0.802))
    let bp = boltPath(in: boltRect)

    // 柔和投影
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -side * 0.010),
                blur: side * 0.030,
                color: NSColor.black.withAlphaComponent(0.34).cgColor)
    c.addPath(bp)
    c.setFillColor(boltA.cgColor)
    c.fillPath()
    c.restoreGState()

    // 渐变填充
    c.saveGState()
    c.addPath(bp)
    c.clip()
    let boltGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [boltA.cgColor, boltB.cgColor] as CFArray,
                              locations: [0, 1])!
    c.drawLinearGradient(boltGrad,
                         start: CGPoint(x: boltRect.minX, y: boltRect.maxY),
                         end:   CGPoint(x: boltRect.maxX, y: boltRect.minY),
                         options: [])
    c.restoreGState()

    // 不描边：闪电的锐角就是它的性格，描边会露出亮边

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// ---------- 导出 ----------
func pngData(_ rep: NSBitmapImageRep) -> Data {
    rep.representation(using: .png, properties: [:])!
}

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// 主图
let master = drawIcon(side: S)
try! pngData(master).write(to: outDir.appendingPathComponent("icon_1024.png"))
print("✓ icon_1024.png")

// iconset
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16",     16),
    ("icon_16x16@2x",  32),
    ("icon_32x32",     32),
    ("icon_32x32@2x",  64),
    ("icon_128x128",   128),
    ("icon_128x128@2x",256),
    ("icon_256x256",   256),
    ("icon_256x256@2x",512),
    ("icon_512x512",   512),
    ("icon_512x512@2x",1024),
]
for (name, side) in sizes {
    let rep = drawIcon(side: side)
    try! pngData(rep).write(to: iconset.appendingPathComponent(name + ".png"))
    print("✓ \(name).png  (\(Int(side))px)")
}

print("DONE")

// ---------- 预览台：多尺寸 + 浅/深底 ----------
func buildPreview() {
    let W: CGFloat = 900, H: CGFloat = 420
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let c = ctx.cgContext

    NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
    c.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // 上排浅底，下排深底
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    c.fill(CGRect(x: 0, y: H / 2, width: W, height: H / 2))
    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    c.fill(CGRect(x: 0, y: 0, width: W, height: H / 2))

    let sizes: [CGFloat] = [256, 128, 64, 32, 16]
    var x: CGFloat = 28
    for s in sizes {
        let img = drawIcon(side: s * 2)   // @2x 保证清晰
        // 上排（浅底）
        img.draw(in: NSRect(x: x, y: H / 2 + (260 - s) / 2 + 20, width: s, height: s))
        // 下排（深底）
        img.draw(in: NSRect(x: x, y: (260 - s) / 2 + 20, width: s, height: s))
        x += s + 36
    }

    // 最右：1x 实际渲染大小对照
    let real = drawIcon(side: 256)
    real.draw(in: NSRect(x: 700, y: H / 2 - 130, width: 256, height: 256))

    NSGraphicsContext.restoreGraphicsState()
    if let tiff = rep.tiffRepresentation,
       let bmp = NSBitmapImageRep(data: tiff),
       let png = bmp.representation(using: .png, properties: [:]) {
        try? png.write(to: outDir.appendingPathComponent("icon_preview.png"))
        print("✓ icon_preview.png")
    }
}
buildPreview()
