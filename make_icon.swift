import AppKit

// 代码绘制 FreedomPlayer 图标（1024x1024 PNG，再由 iconutil 转 icns）：
// 按 macOS 图标规范绘制：824x824 圆角背板居中 + 柔和投影 + 上橙下红垂直渐变
// 图形为开放式播放三角（左上断开、速度线中部相连、左下开放）
let size: CGFloat = 1024

// 图片坐标（y 向下）转 CG 坐标（y 向上）
func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: size - y) }

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no graphics context") }

// 背板：按 Apple macOS 图标网格，824x824 居中，圆角 185
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let plate = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

// 投影层：柔和向下投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40,
              color: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30).cgColor)
NSColor.white.setFill()
plate.fill()
ctx.restoreGState()

// 渐变层：对角三段日落渐变（左上金橙 → 中火橙 → 右下绯红）
// 借鉴主流视频 app 图标的斜向大渐变，比垂直渐变更有动感和高级感
ctx.saveGState()
plate.addClip()
let gradient = NSGradient(colors: [NSColor(srgbRed: 255 / 255, green: 158 / 255, blue: 61 / 255, alpha: 1),
                                   NSColor(srgbRed: 244 / 255, green: 68 / 255, blue: 78 / 255, alpha: 1),
                                   NSColor(srgbRed: 222 / 255, green: 32 / 255, blue: 84 / 255, alpha: 1)],
                          atLocations: [0.0, 0.55, 1.0],
                          colorSpace: NSColorSpace.sRGB)!
gradient.draw(in: rect, angle: -45)

// 顶部微弱高光，增加通透感
let sheen = NSGradient(starting: NSColor(white: 1, alpha: 0),
                       ending: NSColor(white: 1, alpha: 0.15))!
sheen.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: 90)
ctx.restoreGState()

// 内侧 1px 细高光描边，贴合系统图_icon质感
ctx.saveGState()
plate.addClip()
let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 184, yRadius: 184)
border.lineWidth = 2
NSColor(white: 1, alpha: 0.25).setStroke()
border.stroke()
ctx.restoreGState()

// 图形整体缩放为二分之一，并居中到背板中心
ctx.saveGState()
ctx.translateBy(x: 512, y: 512)
ctx.scaleBy(x: 0.625, y: 0.625)
ctx.translateBy(x: -545, y: -526.5)

// 暖象牙白描边，圆角端点/拐角
// 色彩心理学：暖白比纯白柔和、温暖，降低大面积高对比的刺眼感
let lineColor = NSColor(srgbRed: 1, green: 0.972, blue: 0.941, alpha: 1)
// 速度线用亮金色作焦点色：金黄=愉悦/品质感，同属暖色系但一眼跳出
let accent = NSColor(srgbRed: 1, green: 0.79, blue: 0.28, alpha: 1)
let lineWidth: CGFloat = 78

// 线条带柔和暖色投影，悬浮立体感
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10,
              color: NSColor(srgbRed: 0.5, green: 0.05, blue: 0.12, alpha: 0.26).cgColor)

// 折线一：上斜边 + 下斜边（右侧顶点相连；左上、左下端点开放不连接）
let outer = NSBezierPath()
outer.move(to: p(415, 250))
outer.line(to: p(790, 500))
outer.line(to: p(300, 825))
outer.lineWidth = lineWidth
outer.lineCapStyle = .round
outer.lineJoinStyle = .round
lineColor.setStroke()
outer.stroke()

// 速度线：金色焦点，先画，让竖线压住连接处，视觉上从竖线里"长出来"
let echo = NSBezierPath()
echo.move(to: p(300, 672))
echo.line(to: p(580, 486))
echo.lineWidth = lineWidth
echo.lineCapStyle = .round
accent.setStroke()
echo.stroke()

// 左侧竖线（顶端开放），后画以盖住金色线的连接端
let bar = NSBezierPath()
bar.move(to: p(300, 170))
bar.line(to: p(300, 672))
bar.lineWidth = lineWidth
bar.lineCapStyle = .round
lineColor.setStroke()
bar.stroke()

ctx.restoreGState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("icon render failed\n", stderr)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("icon ok")
