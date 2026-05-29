import AppKit

// Renders a 1024x1024 app icon PNG: blue gradient rounded square + the
// keyboard.badge.ellipsis SF Symbol in white (falls back to "TF" text).
// Usage: render-icon <output.png>

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let full = NSRect(x: 0, y: 0, width: size, height: size)
let inset = full.insetBy(dx: size * 0.045, dy: size * 0.045)
let bg = NSBezierPath(roundedRect: inset, xRadius: size * 0.22, yRadius: size * 0.22)
bg.addClip()
let gradient = NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.53, blue: 1.0, alpha: 1),
                          ending:   NSColor(srgbRed: 0.08, green: 0.25, blue: 0.78, alpha: 1))!
gradient.draw(in: full, angle: -90)

func drawGlyph() {
    if let base = NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let sym = base.withSymbolConfiguration(cfg) {
            let s = sym.size
            let scale = (size * 0.60) / max(s.width, s.height)
            let w = s.width * scale, h = s.height * scale
            sym.draw(in: NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
            return
        }
    }
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.40, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let str = NSAttributedString(string: "TF", attributes: attrs)
    let sz = str.size()
    str.draw(at: NSPoint(x: (size - sz.width) / 2, y: (size - sz.height) / 2))
}
drawGlyph()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("render failed\n".utf8)); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
