import AppKit
// Renders the 1024 px app icon: dark rounded square, teal→blue gradient, white location pin, "IP" label.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let inset: CGFloat = size * 0.10
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
NSGradient(colors: [NSColor(calibratedRed: 0.07, green: 0.42, blue: 0.56, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.28, alpha: 1)])!.draw(in: bg, angle: -70)
// faint latitude/longitude grid
NSColor.white.withAlphaComponent(0.08).setStroke()
for i in 1..<5 {
    let x = rect.minX + rect.width * CGFloat(i) / 5
    let y = rect.minY + rect.height * CGFloat(i) / 5
    let p = NSBezierPath(); p.lineWidth = 6
    p.move(to: NSPoint(x: x, y: rect.minY)); p.line(to: NSPoint(x: x, y: rect.maxY))
    p.move(to: NSPoint(x: rect.minX, y: y)); p.line(to: NSPoint(x: rect.maxX, y: y))
    bg.addClip(); p.stroke()
}
// pin
let cx = size / 2, cy = size * 0.60, r = size * 0.16
let pin = NSBezierPath()
pin.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r, startAngle: -40, endAngle: 220)
pin.line(to: NSPoint(x: cx, y: cy - r * 1.9))
pin.close()
NSColor.black.withAlphaComponent(0.25).setFill()
pin.transform(using: AffineTransform(translationByX: 0, byY: -18)); pin.fill()
pin.transform(using: AffineTransform(translationByX: 0, byY: 18))
NSColor.white.setFill(); pin.fill()
NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.28, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: cx - r * 0.42, y: cy - r * 0.42, width: r * 0.84, height: r * 0.84)).fill()
// label
let para = NSMutableParagraphStyle(); para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: size * 0.20, weight: .bold),
    .foregroundColor: NSColor.white, .paragraphStyle: para,
]
NSString(string: "IP").draw(in: NSRect(x: 0, y: size * 0.13, width: size, height: size * 0.26), withAttributes: attrs)
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
rep.size = NSSize(width: size, height: size)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
