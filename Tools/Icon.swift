import AppKit
let icon = NSImage(size: NSSize(width: 1024, height: 1024))
icon.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210)
NSColor(calibratedRed: 0.13, green: 0.23, blue: 0.42, alpha: 1).setFill()
background.fill()
if let box = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor.white])) {
    box.draw(in: NSRect(x: 230, y: 295, width: 564, height: 490))
}
NSColor(calibratedRed: 0.98, green: 0.73, blue: 0.22, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 560, y: 155, width: 250, height: 250)).fill()
if let key = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedRed: 0.13, green: 0.23, blue: 0.42, alpha: 1)])) {
    key.draw(in: NSRect(x: 600, y: 192, width: 165, height: 175))
}
icon.unlockFocus()
for size in [16,32,64,128,256,512,1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Assets/icon-\(size).png"))
}
